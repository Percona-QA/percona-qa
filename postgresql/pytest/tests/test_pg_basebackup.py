"""
pg_basebackup / pg_tde_basebackup tests.

Covers scenarios from:
  - pg_tde_basebackup.sh
  - pg_tde_pgbackrest_ha_failover_rebuild_test.sh (HA rebuild via basebackup only)
"""
import shutil
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import libpq_superuser
from lib.backup import PgBaseBackup


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

        from conftest import allocate_port
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
            if target.exists():
                _shutil.rmtree(target)
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
        #    won't be re-keyed → the message is correct).
        target_no_E = tmp_path / "bb_no_E"
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
        # for us when encrypt_wal=True).
        target_E = tmp_path / "bb_with_E"
        target_E.mkdir(parents=True, exist_ok=True)
        src_pg_tde = tde_primary.data_dir / "pg_tde"
        if src_pg_tde.is_dir():
            dst = target_E / "pg_tde"
            if dst.exists():
                _shutil.rmtree(dst)
            _shutil.copytree(src_pg_tde, dst)

        r2 = _run_basebackup(target_E, "-E")
        assert r2.returncode == 0, (
            f"pg_tde_basebackup -E failed: stderr={r2.stderr}"
        )
        assert warning_phrase not in r2.stderr, (
            "The 'source has WAL keys' warning should NOT appear when -E "
            f"is supplied.\nstderr was:\n{r2.stderr}"
        )
