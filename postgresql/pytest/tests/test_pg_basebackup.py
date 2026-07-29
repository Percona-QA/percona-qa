"""
pg_basebackup / pg_tde_basebackup tests.

Covers scenarios from:
  - pg_tde_basebackup.sh
  - pg_tde_pgbackrest_ha_failover_rebuild_test.sh (HA rebuild via basebackup only)

Also: PITR whose base image is ``pg_basebackup`` / ``pg_tde_basebackup -E``
(``TestPitrWithPgBasebackup`` + corner/negative classes) — distinct from cold
``copytree`` PITR in ``test_pitr.py`` and from pgBackRest PITR in
``test_pg_tde_pgbackrest.py``.
"""
from __future__ import annotations

import shutil
import time
from pathlib import Path
from typing import List, Optional

import pytest

from conftest import allocate_port
from lib import PgCluster, TdeManager
from lib.backup import PgBaseBackup
from lib.cluster import libpq_superuser
from lib.tde import (
    archive_restore_conf_values,
    restore_conf_line_raw,
    wrappers_available,
)


pytestmark = pytest.mark.backup


class TestPgBaseBackup:
    def test_basebackup_plain_cluster(self, primary_cluster: PgCluster, tmp_path: Path):
        primary_cluster.execute("CREATE TABLE bb_test (id INT)")
        primary_cluster.execute("INSERT INTO bb_test SELECT generate_series(1,100)")

        backup_dir = str(tmp_path / "basebackup")
        backup = PgBaseBackup(primary_cluster)
        backup.take(backup_dir)
        assert Path(backup_dir, "PG_VERSION").exists()

    def test_basebackup_with_tde(self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path):
        tde_primary.execute("CREATE TABLE tde_bb_test (id INT)")
        tde_primary.execute("INSERT INTO tde_bb_test SELECT generate_series(1,100)")

        backup_dir = str(tmp_path / "tde_basebackup")
        tde = TdeManager(tde_primary)
        tde.tde_basebackup(backup_dir)
        assert Path(backup_dir, "PG_VERSION").exists()

    def test_restore_from_basebackup(self, primary_cluster: PgCluster, tmp_path: Path, install_dir: Path, io_method: str):
        primary_cluster.execute("CREATE TABLE restore_test (id INT, data TEXT)")
        primary_cluster.execute(
            "INSERT INTO restore_test SELECT i, md5(i::text) FROM generate_series(1,1000) i"
        )

        backup_dir = str(tmp_path / "backup")
        restore_dir = tmp_path / "restored"

        PgBaseBackup(primary_cluster).take(backup_dir)

        restore_port = allocate_port()
        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        shutil.copytree(backup_dir, str(restore_dir))
        restored.write_default_config()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready()

        count = restored.fetchone("SELECT COUNT(*) FROM restore_test")
        assert count == "1000"
        restored.stop()


class TestTdeHaFailoverRebuild:
    """Rebuild former primary as standby using pg_tde_basebackup (not pgBackRest)."""

    def test_ha_failover_and_rebuild(
        self, tde_replica_pair, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """Simulate HA failover: promote standby, rebuild old primary from backup."""
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE ha_test (id INT)")
        primary.execute("INSERT INTO ha_test SELECT generate_series(1,1000)")

        from lib import ReplicationManager
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Simulate primary failure; promote standby
        primary.stop()
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO ha_test SELECT generate_series(1001,2000)")

        # Rebuild old primary as new standby via basebackup from new primary
        shutil.rmtree(primary.data_dir)
        tde_new_primary = TdeManager(standby)
        tde_new_primary.tde_basebackup(str(primary.data_dir))
        primary.write_default_config("replica", extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        # Update primary_conninfo to point to new primary
        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        primary.start()
        primary.wait_ready(timeout=60)

        repl2 = ReplicationManager(standby, primary)
        repl2.assert_catchup(timeout=60)
        count = primary.fetchone("SELECT COUNT(*) FROM ha_test")
        assert count == "2000"


# ── pg_tde_basebackup -E (encrypted WAL on target) ───────────────────────────


class TestPgTdeBaseBackupWalEncryption:
    """
    Coverage for the ``-E`` flag of ``pg_tde_basebackup`` (alias:
    ``TdeManager.tde_basebackup(..., encrypt_wal=True)``).

    Without these tests, the only thing exercising ``-E`` was indirect
    plumbing in `_make_tde_ha_pair`, and no test verified that:

      - ``-E`` actually produces encrypted WAL in the destination's
        ``pg_wal/`` (i.e. plaintext markers do not leak through)
      - pg_tde_basebackup emits the conservative "source has WAL keys, but
        no WAL encryption configured for the target backups" warning when
        ``-E`` is missing — and suppresses it when ``-E`` is supplied

    Both tests are tied to the new ``encrypt_wal`` kwarg added to
    ``TdeManager.tde_basebackup`` (auto-detects ``pg_tde.wal_encrypt`` on
    the source when ``None``, defaulted overrides via ``True`` / ``False``).
    """

    def test_pg_tde_basebackup_E_creates_encrypted_target(
        self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path
    ):
        """
        With ``encrypt_wal=True`` the target's ``pg_wal/`` must contain
        WAL segments that are *not* readable plaintext: a unique marker
        committed before the backup must not appear on disk in the target,
        and the ``pg_tde/`` keyring must be pre-seeded by the helper so
        pg_tde_basebackup can decrypt+re-encrypt as it streams.
        """
        # Enable WAL encryption on the source so the WAL stream itself is
        # encrypted with the source key; -E re-keys for the destination.
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        assert tde.is_wal_encrypted()

        marker = "MARKER-tde-basebackup-E-must-not-leak-on-disk-a7c1"
        tde_primary.execute("CREATE TABLE wal_E_marker (id INT, payload TEXT)")
        tde_primary.execute(f"INSERT INTO wal_E_marker VALUES (1, '{marker}')")
        tde_primary.execute("CHECKPOINT")

        backup_dir = tmp_path / "tde_basebackup_E"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        # Pre-seed of pg_tde/ on the target is required for -E to work.
        assert (backup_dir / "pg_tde").is_dir(), (
            "pg_tde/ keyring was not pre-seeded on the target — "
            "-E backup would not be decryptable on restore."
        )

        # Inspect every WAL segment in the target's pg_wal/ — none of them
        # may contain the plaintext marker we just inserted.
        pg_wal = backup_dir / "pg_wal"
        assert pg_wal.is_dir(), "Target has no pg_wal/ directory"
        wal_segments = sorted(
            p for p in pg_wal.iterdir()
            if p.is_file() and len(p.name) == 24 and "." not in p.name
        )
        assert wal_segments, "No WAL segments found in target's pg_wal/"
        marker_bytes = marker.encode()
        for seg in wal_segments:
            content = seg.read_bytes()
            assert marker_bytes not in content, (
                f"Plaintext marker {marker!r} found inside {seg.name}; "
                "target WAL was streamed without encryption despite -E."
            )

    def test_pg_tde_basebackup_warning_when_E_missing(
        self, tde_primary: PgCluster, tmp_path: Path
    ):
        """
        pg_tde_basebackup must warn when the source has TDE keys configured
        but the backup is run without ``-E`` (the WAL on the target won't be
        encrypted with the target's own key). Conversely, passing ``-E``
        must suppress that specific warning.

        We bypass ``TdeManager.tde_basebackup`` to capture stderr directly —
        the helper uses ``subprocess.run(..., check=True)`` without capture.
        """
        import os
        import shutil as _shutil
        import subprocess

        bin_path = tde_primary.bin / "pg_tde_basebackup"
        if not bin_path.exists():
            pytest.skip("pg_tde_basebackup binary not present in this build")

        env = os.environ.copy()
        lib_dir = str(tde_primary.install_dir / "lib")
        env["LD_LIBRARY_PATH"] = (
            f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
        )

        def _run_basebackup(target: Path, *extra) -> subprocess.CompletedProcess:
            """Run pg_tde_basebackup. Caller owns ``target`` lifecycle —
            we never wipe it here because the -E path needs a pre-seeded
            ``pg_tde/`` subdir to exist when pg_tde_basebackup starts."""
            cmd = [
                str(bin_path),
                "-h", str(tde_primary.socket_dir),
                "-p", str(tde_primary.port),
                "-U", libpq_superuser(),
                "-D", str(target),
                "-R", "--checkpoint=fast",
                *extra,
            ]
            return subprocess.run(cmd, capture_output=True, text=True, env=env)

        warning_phrase = "WAL keys"

        # 1. No -E: warning MUST appear (source has TDE keys, target backup
        #    won't be re-keyed → the message is correct). Target dir must not
        #    exist (pg_tde_basebackup creates it).
        target_no_E = tmp_path / "bb_no_E"
        if target_no_E.exists():
            _shutil.rmtree(target_no_E)
        r1 = _run_basebackup(target_no_E)
        assert r1.returncode == 0, (
            f"pg_tde_basebackup (no -E) failed: stderr={r1.stderr}"
        )
        assert warning_phrase in r1.stderr, (
            "Expected the 'source has WAL keys, but no WAL encryption "
            "configured for the target backups' warning when -E was missing.\n"
            f"stderr was:\n{r1.stderr}"
        )

        # 2. With -E: the same warning must NOT appear.
        # Pre-seed the keyring (the same step TdeManager.tde_basebackup does
        # for us when encrypt_wal=True). The target dir must exist with
        # pg_tde/ inside BEFORE pg_tde_basebackup -E starts.
        target_E = tmp_path / "bb_with_E"
        if target_E.exists():
            _shutil.rmtree(target_E)
        target_E.mkdir(parents=True)
        src_pg_tde = tde_primary.data_dir / "pg_tde"
        assert src_pg_tde.is_dir(), (
            f"Source has no pg_tde/ directory at {src_pg_tde} — "
            "test setup is broken."
        )
        _shutil.copytree(src_pg_tde, target_E / "pg_tde")

        r2 = _run_basebackup(target_E, "-E")
        assert r2.returncode == 0, (
            f"pg_tde_basebackup -E failed: stderr={r2.stderr}"
        )
        assert warning_phrase not in r2.stderr, (
            "The 'source has WAL keys' warning should NOT appear when -E "
            f"is supplied.\nstderr was:\n{r2.stderr}"
        )


# ── PITR from pg_basebackup / pg_tde_basebackup ───────────────────────────────


_TDE_RESTORED_PARAMS = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}


def _force_archive_segment(
    cluster: PgCluster, archive_dir: Path, timeout: float = 30
) -> None:
    before = {p.name for p in archive_dir.iterdir() if p.is_file()}
    cluster.execute("CHECKPOINT")
    cluster.execute("SELECT pg_switch_wal()")
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = {p.name for p in archive_dir.iterdir() if p.is_file()}
        if any(len(n) == 24 and "." not in n for n in (now - before)):
            return
        time.sleep(0.25)
    raise TimeoutError(f"WAL not archived under {archive_dir}")


def _require_tde_basebackup(install_dir: Path) -> None:
    if not wrappers_available(install_dir):
        pytest.skip("pg_tde archive wrappers not in this build")
    if not (install_dir / "bin" / "pg_tde_basebackup").is_file():
        pytest.skip("pg_tde_basebackup not in this build")


def _enable_file_archive(cluster: PgCluster, archive_dir: Path) -> None:
    archive_dir.mkdir(parents=True, exist_ok=True)
    cluster.configure(
        {
            "wal_level": "replica",
            "archive_mode": "on",
            "archive_command": f"'cp %p {archive_dir}/%f'",
        }
    )
    cluster.restart()


def _enable_tde_wal_archive(
    cluster: PgCluster, install_dir: Path, archive_dir: Path
) -> TdeManager:
    tde = TdeManager(cluster)
    tde.enable_wal_encryption()
    archive_dir.mkdir(parents=True, exist_ok=True)
    arch_cmd, _ = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=True
    )
    cluster.configure(
        {
            "wal_level": "replica",
            "archive_mode": "on",
            "archive_command": arch_cmd,
        }
    )
    cluster.restart()
    return tde


def _write_bb_recovery(
    restore_dir: Path,
    archive_dir: Path,
    *,
    install_dir: Optional[Path] = None,
    use_tde_wrappers: bool = False,
    target_time: Optional[str] = None,
    target_lsn: Optional[str] = None,
    target_xid: Optional[str] = None,
    target_inclusive: Optional[bool] = None,
    target_action: str = "promote",
    wal_encrypt: bool = False,
) -> None:
    (restore_dir / "standby.signal").unlink(missing_ok=True)
    (restore_dir / "recovery.signal").touch()
    with (restore_dir / "postgresql.auto.conf").open("w") as f:
        if wal_encrypt:
            f.write("pg_tde.wal_encrypt = 'on'\n")
        if target_time is not None:
            f.write(f"recovery_target_time = '{target_time}'\n")
        if target_lsn is not None:
            f.write(f"recovery_target_lsn = '{target_lsn}'\n")
        if target_xid is not None:
            f.write(f"recovery_target_xid = '{target_xid}'\n")
        if target_inclusive is not None:
            f.write(
                f"recovery_target_inclusive = "
                f"{'on' if target_inclusive else 'off'}\n"
            )
        f.write(f"recovery_target_action = '{target_action}'\n")
        if use_tde_wrappers:
            assert install_dir is not None
            f.write(
                restore_conf_line_raw(
                    archive_dir, install_dir, use_tde_wrappers=True
                )
            )
        else:
            f.write(f"restore_command = 'cp {archive_dir}/%f %p'\n")


def _start_bb_restored(
    restore_dir: Path,
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    tde: bool = False,
    timeout: int = 120,
    promote: bool = True,
) -> PgCluster:
    restored = PgCluster(
        restore_dir,
        allocate_port(),
        install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    restored.write_default_config(
        extra_params=_TDE_RESTORED_PARAMS if tde else None
    )
    restored.add_hba_entry("local all all trust")
    restored.start()
    restored.wait_ready(timeout=timeout)
    if promote:
        deadline = time.time() + 90
        while time.time() < deadline:
            if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.3)
        else:
            # recovery_target_action=promote should have finished; nudge if needed.
            if restored.fetchone("SELECT pg_is_in_recovery()") == "t":
                try:
                    restored.execute(
                        "SELECT pg_promote(wait := true, wait_seconds := 60)"
                    )
                except RuntimeError:
                    pass
            deadline = time.time() + 60
            while time.time() < deadline:
                if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.3)
            if restored.fetchone("SELECT pg_is_in_recovery()") != "f":
                raise TimeoutError("restored cluster did not leave recovery")
    return restored


def _archive_wal_files(archive_dir: Path) -> List[Path]:
    return sorted(
        p
        for p in archive_dir.iterdir()
        if p.is_file() and len(p.name) == 24 and "." not in p.name
    )


def _assert_pitr_failed_or_stuck(cluster: PgCluster) -> None:
    in_recovery = cluster.fetchone("SELECT pg_is_in_recovery()")
    log_l = cluster.read_log().lower()
    markers = (
        "recovery ended before configured recovery target was reached",
        "could not find recovery target",
        "waiting for wal",
        "invalid resource manager id",
        "invalid magic number",
        "could not read from file",
        "fatal",
        "panic",
        "corrupt",
        "decrypt",
    )
    hit = any(m in log_l for m in markers)
    assert in_recovery == "t" or hit, (
        "Negative PITR must stay in recovery or log a recovery/WAL failure.\n"
        f"Log:\n{cluster.read_log(100)}"
    )


@pytest.mark.slow
class TestPitrWithPgBasebackup:
    """
    Point-in-time recovery whose base image comes from ``pg_basebackup`` /
    ``pg_tde_basebackup`` (not a cold ``copytree`` of PGDATA, and not pgBackRest).

    Flow: archive_mode → basebackup → post-backup writes → recovery_target_* →
    restore_command replay.
    """

    def test_pitr_from_pg_basebackup_by_time(
        self,
        primary_cluster: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        archive_dir = tmp_path / "bb_pitr_archive"
        _enable_file_archive(primary_cluster, archive_dir)

        primary_cluster.execute(
            "CREATE TABLE bb_pitr (id INT PRIMARY KEY, marker TEXT)"
        )
        primary_cluster.execute(
            "INSERT INTO bb_pitr SELECT g, 'seed' FROM generate_series(1, 50) g"
        )

        backup_dir = tmp_path / "bb_pitr_backup"
        PgBaseBackup(primary_cluster).take(str(backup_dir), wal_method="stream")
        assert (backup_dir / "PG_VERSION").is_file()

        primary_cluster.execute("INSERT INTO bb_pitr VALUES (100, 'kept')")
        pitr_time = (primary_cluster.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        primary_cluster.execute("INSERT INTO bb_pitr VALUES (200, 'discarded')")
        _force_archive_segment(primary_cluster, archive_dir)
        primary_cluster.stop()

        restore_dir = tmp_path / "bb_pitr_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir, archive_dir, target_time=pitr_time
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_pitr WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_pitr WHERE marker = 'discarded'"
            ) == "0"
            assert restored.fetchone("SELECT COUNT(*) FROM bb_pitr") == "51"
        finally:
            restored.stop()

    def test_pitr_from_pg_basebackup_by_lsn(
        self,
        primary_cluster: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        archive_dir = tmp_path / "bb_lsn_archive"
        _enable_file_archive(primary_cluster, archive_dir)
        primary_cluster.execute(
            "CREATE TABLE bb_lsn (id INT PRIMARY KEY, marker TEXT)"
        )
        primary_cluster.execute("INSERT INTO bb_lsn VALUES (1, 'seed')")

        backup_dir = tmp_path / "bb_lsn_backup"
        PgBaseBackup(primary_cluster).take(str(backup_dir), wal_method="stream")

        primary_cluster.execute("INSERT INTO bb_lsn VALUES (2, 'kept')")
        target_lsn = (
            primary_cluster.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        primary_cluster.execute("INSERT INTO bb_lsn VALUES (3, 'discarded')")
        _force_archive_segment(primary_cluster, archive_dir)
        primary_cluster.stop()

        restore_dir = tmp_path / "bb_lsn_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir, archive_dir, target_lsn=target_lsn
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_lsn WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_lsn WHERE marker = 'discarded'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_from_pg_tde_basebackup_encrypted_wal_by_time(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "tde_bb_pitr_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE tde_bb_pitr (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO tde_bb_pitr "
            "SELECT g, 'seed' FROM generate_series(1, 40) g"
        )

        backup_dir = tmp_path / "tde_bb_pitr_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)
        assert (backup_dir / "PG_VERSION").is_file()
        assert (backup_dir / "pg_tde").is_dir()

        tde_primary.execute("INSERT INTO tde_bb_pitr VALUES (100, 'kept')")
        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("INSERT INTO tde_bb_pitr VALUES (200, 'discarded')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "tde_bb_pitr_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_pitr WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_pitr WHERE marker = 'discarded'"
            ) == "0"
            assert restored.fetchone(
                "SELECT marker FROM tde_bb_pitr WHERE id = 100"
            ) == "kept"
        finally:
            restored.stop()

    def test_pitr_from_pg_tde_basebackup_by_lsn(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "tde_bb_lsn_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE tde_bb_lsn (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO tde_bb_lsn VALUES (1, 'seed')")

        backup_dir = tmp_path / "tde_bb_lsn_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO tde_bb_lsn VALUES (2, 'kept')")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("INSERT INTO tde_bb_lsn VALUES (3, 'discarded')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "tde_bb_lsn_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_lsn=target_lsn,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_lsn WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_lsn WHERE marker = 'discarded'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_from_pg_tde_basebackup_by_xid(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "tde_bb_xid_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE tde_bb_xid (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO tde_bb_xid VALUES (1, 'seed')")
        backup_dir = tmp_path / "tde_bb_xid_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO tde_bb_xid VALUES (2, 'kept')")
        pre_xid = tde_primary.fetchone(
            "SELECT xmin::text::bigint FROM tde_bb_xid WHERE id = 2"
        )
        tde_primary.execute("INSERT INTO tde_bb_xid VALUES (3, 'discarded')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "tde_bb_xid_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_xid=pre_xid,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_xid WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_bb_xid WHERE marker = 'discarded'"
            ) == "0"
        finally:
            restored.stop()


@pytest.mark.slow
class TestPitrWithPgBasebackupCornerCases:
    """Corner-case PITR on a ``pg_tde_basebackup -E`` base image."""

    def test_pitr_exclusive_lsn(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_excl_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_excl (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_excl VALUES (1, 'base')")
        backup_dir = tmp_path / "bb_excl_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO bb_excl VALUES (2, 'at_lsn')")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("INSERT INTO bb_excl VALUES (3, 'after_lsn')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_excl_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_lsn=target_lsn,
            target_inclusive=False,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_excl WHERE id = 1"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_excl WHERE id = 3"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_pause_then_promote(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_pause_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_pause (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_pause VALUES (1), (2)")
        backup_dir = tmp_path / "bb_pause_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("INSERT INTO bb_pause VALUES (99)")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_pause_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            target_action="pause",
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True, promote=False
        )
        try:
            deadline = time.time() + 90
            paused = False
            while time.time() < deadline:
                try:
                    if restored.fetchone("SELECT pg_is_in_recovery()") == "t":
                        state = restored.fetchone(
                            "SELECT pg_get_wal_replay_pause_state()"
                        )
                        if state in ("paused", "pause requested"):
                            paused = True
                            break
                except Exception:
                    pass
                time.sleep(0.5)
            assert paused, "PITR did not reach recovery pause state"

            restored.execute("SELECT pg_wal_replay_resume()")
            try:
                restored.execute(
                    "SELECT pg_promote(wait := true, wait_seconds := 60)"
                )
            except RuntimeError:
                pass
            deadline = time.time() + 60
            while time.time() < deadline:
                if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            assert restored.fetchone("SELECT pg_is_in_recovery()") == "f"
            assert restored.fetchone("SELECT COUNT(*) FROM bb_pause") == "2"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_pause WHERE id = 99"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_pitr_before_drop_table(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_drop_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_drop_t (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_drop_t VALUES (1, 'keep'), (2, 'keep')")
        backup_dir = tmp_path / "bb_drop_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("DROP TABLE bb_drop_t")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_drop_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM bb_drop_t") == "2"
            assert TdeManager(restored).is_table_encrypted("bb_drop_t")
        finally:
            restored.stop()

    def test_pitr_before_drop_database_sibling(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_dropdb_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE keep_pg (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO keep_pg VALUES (1, 'postgres_db')")
        tde_primary.execute("CREATE DATABASE appdb")
        tde_primary.execute("CREATE EXTENSION pg_tde", dbname="appdb")
        TdeManager(tde_primary).set_global_principal_key(dbname="appdb")
        tde_primary.execute(
            "CREATE TABLE t (id INT PRIMARY KEY, v TEXT) USING tde_heap",
            dbname="appdb",
        )
        tde_primary.execute(
            "INSERT INTO t VALUES (10, 'appdb_row')", dbname="appdb"
        )

        backup_dir = tmp_path / "bb_dropdb_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("DROP DATABASE appdb")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_dropdb_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM keep_pg") == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pg_database WHERE datname = 'appdb'"
            ) == "1"
            assert restored.fetchone(
                "SELECT v FROM t WHERE id = 10", dbname="appdb"
            ) == "appdb_row"
        finally:
            restored.stop()

    def test_pitr_before_truncate(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_trunc_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_trunc (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO bb_trunc "
            "SELECT i, 'seed' FROM generate_series(1, 100) i"
        )
        backup_dir = tmp_path / "bb_trunc_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("TRUNCATE bb_trunc")
        tde_primary.execute("INSERT INTO bb_trunc VALUES (999, 'post')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_trunc_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM bb_trunc") == "100"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_trunc WHERE id = 999"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_across_principal_key_rotation(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_rot_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_rot (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_rot VALUES (1, 'key1')")
        backup_dir = tmp_path / "bb_rot_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde.rotate_principal_key("bb_pitr_rot_key2")
        tde_primary.execute("INSERT INTO bb_rot VALUES (2, 'key2')")
        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("INSERT INTO bb_rot VALUES (3, 'after')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_rot_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_rot WHERE marker = 'key1'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_rot WHERE marker = 'key2'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_rot WHERE marker = 'after'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_undoes_update_and_delete(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_dml_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_dml (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO bb_dml VALUES (1, 'orig'), (2, 'orig'), (3, 'orig')"
        )
        backup_dir = tmp_path / "bb_dml_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("UPDATE bb_dml SET marker = 'changed' WHERE id = 1")
        tde_primary.execute("DELETE FROM bb_dml WHERE id = 2")
        tde_primary.execute("INSERT INTO bb_dml VALUES (4, 'new')")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_dml_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT marker FROM bb_dml WHERE id = 1"
            ) == "orig"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_dml WHERE id = 2"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_dml WHERE id = 4"
            ) == "0"
            assert restored.fetchone("SELECT COUNT(*) FROM bb_dml") == "3"
        finally:
            restored.stop()

    def test_pitr_multi_db_by_time(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_multi_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_m1 (id INT PRIMARY KEY, marker TEXT) USING tde_heap"
        )
        tde_primary.execute("CREATE DATABASE bb_app")
        tde_primary.execute("CREATE EXTENSION pg_tde", dbname="bb_app")
        TdeManager(tde_primary).set_global_principal_key(dbname="bb_app")
        tde_primary.execute(
            "CREATE TABLE bb_m2 (id INT PRIMARY KEY, marker TEXT) USING tde_heap",
            dbname="bb_app",
        )
        tde_primary.execute("INSERT INTO bb_m1 VALUES (1, 'seed')")
        tde_primary.execute(
            "INSERT INTO bb_m2 VALUES (1, 'seed')", dbname="bb_app"
        )

        backup_dir = tmp_path / "bb_multi_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO bb_m1 VALUES (2, 'kept')")
        tde_primary.execute(
            "INSERT INTO bb_m2 VALUES (2, 'kept')", dbname="bb_app"
        )
        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        time.sleep(0.5)
        tde_primary.execute("INSERT INTO bb_m1 VALUES (3, 'discarded')")
        tde_primary.execute(
            "INSERT INTO bb_m2 VALUES (3, 'discarded')", dbname="bb_app"
        )
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_multi_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_m1 WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_m1 WHERE marker = 'discarded'"
            ) == "0"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_m2 WHERE marker = 'kept'",
                dbname="bb_app",
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM bb_m2 WHERE marker = 'discarded'",
                dbname="bb_app",
            ) == "0"
        finally:
            restored.stop()


@pytest.mark.slow
class TestPitrWithPgBasebackupNegative:
    """Failure paths for PITR when the base image is pg_basebackup / -E."""

    def test_negative_pitr_missing_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_neg_miss_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_miss (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_miss VALUES (1)")
        backup_dir = tmp_path / "bb_miss_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO bb_miss VALUES (2); CHECKPOINT;")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        wal_files = _archive_wal_files(archive_dir)
        assert wal_files, "expected archived WAL"
        wal_files[-1].unlink()

        restore_dir = tmp_path / "bb_miss_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_lsn=target_lsn,
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True, promote=False
        )
        try:
            _assert_pitr_failed_or_stuck(restored)
        finally:
            restored.stop(check=False)

    def test_negative_pitr_corrupt_archived_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_neg_corrupt_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_cor (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_cor VALUES (1)")
        backup_dir = tmp_path / "bb_cor_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)

        tde_primary.execute("INSERT INTO bb_cor VALUES (2); CHECKPOINT;")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        wal_files = _archive_wal_files(archive_dir)
        assert wal_files
        victim = wal_files[-1]
        size = victim.stat().st_size
        victim.write_bytes(b"\x00" * size)

        restore_dir = tmp_path / "bb_cor_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_lsn=target_lsn,
            wal_encrypt=True,
        )
        restored = PgCluster(
            restore_dir,
            allocate_port(),
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        restored.write_default_config(extra_params=_TDE_RESTORED_PARAMS)
        restored.add_hba_entry("local all all trust")
        start_failed = False
        try:
            try:
                restored.start(timeout=60)
                restored.wait_ready(timeout=30)
            except (RuntimeError, TimeoutError):
                start_failed = True
            if not start_failed:
                _assert_pitr_failed_or_stuck(restored)
        finally:
            restored.stop(check=False)
        if start_failed:
            log_l = restored.read_log().lower()
            assert any(
                m in log_l
                for m in ("invalid", "corrupt", "fatal", "wal", "could not")
            ), f"Expected corrupt-WAL failure:\n{restored.read_log(80)}"

    def test_negative_pitr_target_before_backup(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_neg_early_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_early (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_early VALUES (1)")
        backup_dir = tmp_path / "bb_early_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)
        tde_primary.execute("INSERT INTO bb_early VALUES (2)")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_early_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time="1999-01-01 00:00:00+00",
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True, promote=False
        )
        try:
            _assert_pitr_failed_or_stuck(restored)
            if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                assert restored.fetchone(
                    "SELECT COUNT(*) FROM bb_early WHERE id = 2"
                ) != "1"
        finally:
            restored.stop(check=False)

    def test_negative_pitr_unreachable_xid(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_neg_xid_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_xid_neg (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_xid_neg VALUES (1)")
        backup_dir = tmp_path / "bb_xid_neg_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)
        tde_primary.execute("INSERT INTO bb_xid_neg VALUES (2)")
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_xid_neg_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_xid="2000000000",
            wal_encrypt=True,
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True, promote=False
        )
        try:
            _assert_pitr_failed_or_stuck(restored)
            if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                pytest.fail("Unreachable XID unexpectedly left recovery")
        finally:
            restored.stop(check=False)

    def test_negative_pitr_without_pg_tde_keyring(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        _require_tde_basebackup(install_dir)
        archive_dir = tmp_path / "bb_neg_nokey_archive"
        tde = _enable_tde_wal_archive(tde_primary, install_dir, archive_dir)

        tde_primary.execute(
            "CREATE TABLE bb_nk (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO bb_nk VALUES (1, 'secret')")
        backup_dir = tmp_path / "bb_nk_backup"
        tde.tde_basebackup(str(backup_dir), encrypt_wal=True)
        tde_primary.execute("INSERT INTO bb_nk VALUES (2, 'post')")
        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
        _force_archive_segment(tde_primary, archive_dir)
        tde_primary.stop()

        restore_dir = tmp_path / "bb_nk_restore"
        shutil.copytree(backup_dir, restore_dir)
        shutil.rmtree(restore_dir / "pg_tde")
        _write_bb_recovery(
            restore_dir,
            archive_dir,
            install_dir=install_dir,
            use_tde_wrappers=True,
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = PgCluster(
            restore_dir,
            allocate_port(),
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        restored.write_default_config(extra_params=_TDE_RESTORED_PARAMS)
        restored.add_hba_entry("local all all trust")
        start_failed = False
        try:
            try:
                restored.start(timeout=45)
                restored.wait_ready(timeout=30)
            except (RuntimeError, TimeoutError):
                start_failed = True
            log_l = restored.read_log().lower()
            key_err = any(
                m in log_l
                for m in ("pg_tde", "encrypt", "decrypt", "key", "fatal", "could not")
            )
            assert start_failed or key_err, (
                "Expected keyring failure after removing pg_tde/.\n"
                f"Log:\n{restored.read_log(80)}"
            )
        finally:
            restored.stop(check=False)

    def test_negative_pitr_archive_removed(
        self,
        primary_cluster: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """Plain basebackup PITR cannot reach target if the archive is gone."""
        archive_dir = tmp_path / "bb_neg_noarch"
        _enable_file_archive(primary_cluster, archive_dir)
        primary_cluster.execute(
            "CREATE TABLE bb_noarch (id INT PRIMARY KEY)"
        )
        primary_cluster.execute("INSERT INTO bb_noarch VALUES (1)")
        backup_dir = tmp_path / "bb_noarch_backup"
        PgBaseBackup(primary_cluster).take(str(backup_dir), wal_method="stream")

        primary_cluster.execute("INSERT INTO bb_noarch VALUES (2); CHECKPOINT;")
        target_lsn = (
            primary_cluster.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        _force_archive_segment(primary_cluster, archive_dir)
        primary_cluster.stop()

        for p in _archive_wal_files(archive_dir):
            p.unlink()

        restore_dir = tmp_path / "bb_noarch_restore"
        shutil.copytree(backup_dir, restore_dir)
        _write_bb_recovery(
            restore_dir, archive_dir, target_lsn=target_lsn
        )
        restored = _start_bb_restored(
            restore_dir, install_dir, tmp_path, io_method, promote=False
        )
        try:
            _assert_pitr_failed_or_stuck(restored)
        finally:
            restored.stop(check=False)
