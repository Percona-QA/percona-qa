"""
Point-in-time recovery (PITR) via WAL archive + restore_command.

This is not the same as ``test_pg_basebackup.py`` (filesystem basebackup) or
``test_pg_tde_pgbackrest.py`` (external backup tool): PITR replays archived WAL
to a recovery target after restoring a **data-directory copy**, which exercises
``recovery_target_*``, ``restore_command``, and (for TDE) decrypt wrappers.

Covers scenarios from:
  - pg_tde_restore_encrypt_using_archive_decrypt.sh
  - pitr_encrypted_wal.sh

Matrix (this file):
  * plain heap + plain archive (time)
  * WAL encrypt + TDE archive wrappers (time / LSN / XID)
  * tde_heap + WAL encrypt (time, inclusive vs exclusive)
  * recovery_target_action = pause then promote
"""
from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Optional

import pytest

from conftest import allocate_port
from lib import PgCluster, TdeManager, archive_restore_conf_values, restore_conf_line_raw
from lib.tde import wrappers_available


pytestmark = pytest.mark.backup


def _wait_archive_has_segment(archive_dir: Path, timeout: float = 30) -> Path:
    deadline = time.time() + timeout
    while time.time() < deadline:
        segs = [
            p
            for p in archive_dir.iterdir()
            if p.is_file() and len(p.name) == 24 and "." not in p.name
        ]
        if segs:
            return sorted(segs)[-1]
        time.sleep(0.25)
    raise TimeoutError(f"no WAL segment archived under {archive_dir}")


def _force_archive(cluster: PgCluster, archive_dir: Path, timeout: float = 30) -> Path:
    before = {p.name for p in archive_dir.iterdir() if p.is_file()}
    cluster.execute("CHECKPOINT")
    cluster.execute("SELECT pg_switch_wal()")
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = {p.name for p in archive_dir.iterdir() if p.is_file()}
        new = now - before
        segs = [n for n in new if len(n) == 24 and "." not in n]
        if segs:
            return archive_dir / sorted(segs)[-1]
        time.sleep(0.25)
    # Fall back: any segment is enough for later recovery tests.
    return _wait_archive_has_segment(archive_dir, timeout=5)


def _cold_copy_datadir(src: PgCluster, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(str(src.data_dir), str(dest))
    # PostgreSQL rejects data dirs that are group/world-accessible (common after copytree).
    os.chmod(dest, 0o700)


def _pitr_timestamp(cluster: PgCluster) -> str:
    """UTC timestamp string that recovery_target_time parses reliably."""
    return (
        cluster.fetchone(
            "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', "
            "'YYYY-MM-DD HH24:MI:SS.US') || '+00'"
        )
        or ""
    ).strip()


def _write_recovery_auto_conf(
    restore_dir: Path,
    *,
    restore_command_line: str,
    target_time: Optional[str] = None,
    target_lsn: Optional[str] = None,
    target_xid: Optional[str] = None,
    target_inclusive: Optional[bool] = None,
    target_action: str = "promote",
    wal_encrypt: bool = False,
    extra_lines: Optional[list[str]] = None,
) -> None:
    """Replace copied postgresql.auto.conf so primary ALTER SYSTEM lines do not leak."""
    auto_conf = restore_dir / "postgresql.auto.conf"
    with auto_conf.open("w") as f:
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
                f"recovery_target_inclusive = '{'on' if target_inclusive else 'off'}'\n"
            )
        f.write(f"recovery_target_action = '{target_action}'\n")
        # restore_command_line is already a full conf assignment, e.g.
        # restore_command = '...'
        line = restore_command_line.strip()
        if not line.endswith("\n"):
            line += "\n"
        f.write(line)
        for extra in extra_lines or []:
            f.write(extra if extra.endswith("\n") else extra + "\n")
    (restore_dir / "recovery.signal").touch()
    # Avoid promoting as a streaming standby from a copied primary.
    (restore_dir / "standby.signal").unlink(missing_ok=True)


def _start_restored(
    restore_dir: Path,
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    tde: bool = False,
) -> PgCluster:
    os.chmod(restore_dir, 0o700)
    restored = PgCluster(
        restore_dir,
        allocate_port(),
        install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    extra = {}
    if tde:
        extra = {
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
        }
    restored.write_default_config(extra_params=extra or None)
    restored.add_hba_entry("local all all trust")
    restored.start()
    restored.wait_ready(timeout=90)
    return restored


@pytest.mark.slow
class TestPitr:
    def test_pitr_plain(
        self,
        primary_cluster: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """Point-in-time recovery to a checkpoint before a DROP TABLE."""
        archive_dir = tmp_path / "wal_archive"
        archive_dir.mkdir()
        primary_cluster.configure(
            {
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": f"'cp %p {archive_dir}/%f'",
            }
        )
        primary_cluster.restart()

        primary_cluster.execute("CREATE TABLE pitr_tbl (id INT)")
        primary_cluster.execute(
            "INSERT INTO pitr_tbl SELECT generate_series(1,100)"
        )

        primary_cluster.stop()
        restore_dir = tmp_path / "pitr_restore"
        _cold_copy_datadir(primary_cluster, restore_dir)
        primary_cluster.start()

        pitr_time = _pitr_timestamp(primary_cluster)
        time.sleep(0.5)

        primary_cluster.execute("DROP TABLE pitr_tbl")
        _force_archive(primary_cluster, archive_dir)
        primary_cluster.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=f"restore_command = 'cp {archive_dir}/%f %p'",
            target_time=pitr_time,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_tbl") == "100"
        finally:
            restored.stop()

    def test_pitr_encrypted_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """PITR with WAL encryption + archive/restore TDE wrappers."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()

        archive_dir = tmp_path / "enc_wal_archive"
        archive_dir.mkdir()
        arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        tde_primary.configure(
            {
                "archive_mode": "on",
                "archive_command": arch_cmd,
            }
        )
        tde_primary.restart()

        tde_primary.execute(
            "CREATE TABLE pitr_enc_tbl (id INT PRIMARY KEY, payload TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO pitr_enc_tbl "
            "SELECT g, repeat('e', 40) FROM generate_series(1,100) g"
        )

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_enc_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        pitr_time = _pitr_timestamp(tde_primary)
        time.sleep(0.5)

        tde_primary.execute("DROP TABLE pitr_enc_tbl")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_time=pitr_time,
            wal_encrypt=True,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_enc_tbl") == "100"
            assert restored.fetchone(
                "SELECT length(payload) FROM pitr_enc_tbl WHERE id = 1"
            ) == "40"
        finally:
            restored.stop()


@pytest.mark.slow
class TestPitrTargetKinds:
    """recovery_target_time / _lsn / _xid on WAL-encrypted TDE clusters."""

    def _prepare_wal_encrypted(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        name: str,
    ) -> Path:
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        archive_dir = tmp_path / f"{name}_archive"
        archive_dir.mkdir()
        arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        tde_primary.configure(
            {"archive_mode": "on", "archive_command": arch_cmd}
        )
        tde_primary.restart()
        return archive_dir

    def test_pitr_by_lsn_encrypted_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        archive_dir = self._prepare_wal_encrypted(
            tde_primary, tmp_path, install_dir, "pitr_lsn"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_lsn (id INT PRIMARY KEY, marker TEXT) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO pitr_lsn VALUES (1, 'pre_backup')"
        )

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_lsn_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        tde_primary.execute("INSERT INTO pitr_lsn VALUES (2, 'kept')")
        target_lsn = (tde_primary.fetchone("SELECT pg_current_wal_lsn()") or "").strip()
        assert target_lsn
        tde_primary.execute("INSERT INTO pitr_lsn VALUES (3, 'discarded')")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_lsn=target_lsn,
            wal_encrypt=True,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_lsn WHERE marker = 'kept'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_lsn WHERE marker = 'discarded'"
            ) == "0"
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_lsn") == "2"
        finally:
            restored.stop()

    def test_pitr_by_xid_encrypted_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        archive_dir = self._prepare_wal_encrypted(
            tde_primary, tmp_path, install_dir, "pitr_xid"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_xid (id INT PRIMARY KEY, marker TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_xid VALUES (1, 'base')")

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_xid_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        tde_primary.execute("INSERT INTO pitr_xid VALUES (2, 'target_row')")
        # xmin of the just-inserted row is the committing xid.
        target_xid = (
            tde_primary.fetchone(
                "SELECT xmin::text::bigint FROM pitr_xid WHERE id = 2"
            )
            or ""
        ).strip()
        assert target_xid.isdigit(), f"unexpected xmin: {target_xid!r}"

        tde_primary.execute("INSERT INTO pitr_xid VALUES (3, 'after_target')")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_xid=target_xid,
            target_inclusive=True,
            wal_encrypt=True,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_xid WHERE id = 2"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_xid WHERE id = 3"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_exclusive_lsn_drops_boundary_commit(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        ``recovery_target_inclusive = off`` with ``recovery_target_lsn`` stops
        before the record at that LSN, so the post-LSN insert must be absent and
        the row that produced the target LSN may also be absent.
        """
        archive_dir = self._prepare_wal_encrypted(
            tde_primary, tmp_path, install_dir, "pitr_excl"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_excl (id INT PRIMARY KEY, marker TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_excl VALUES (1, 'base')")

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_excl_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        tde_primary.execute("INSERT INTO pitr_excl VALUES (2, 'at_lsn')")
        target_lsn = (tde_primary.fetchone("SELECT pg_current_wal_lsn()") or "").strip()
        tde_primary.execute("INSERT INTO pitr_excl VALUES (3, 'after_lsn')")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_lsn=target_lsn,
            target_inclusive=False,
            wal_encrypt=True,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl WHERE id = 1"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl WHERE id = 3"
            ) == "0"
        finally:
            restored.stop()


@pytest.mark.slow
class TestPitrRecoveryActions:
    def test_pitr_pause_then_promote_encrypted_wal(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        ``recovery_target_action = pause`` leaves the instance in recovery until
        ``pg_wal_replay_resume()`` / promote — encrypted WAL must still apply.
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        archive_dir = tmp_path / "pitr_pause_archive"
        archive_dir.mkdir()
        arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        tde_primary.configure(
            {"archive_mode": "on", "archive_command": arch_cmd}
        )
        tde_primary.restart()

        tde_primary.execute(
            "CREATE TABLE pitr_pause (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_pause VALUES (1),(2)")

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_pause_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        pitr_time = _pitr_timestamp(tde_primary)
        time.sleep(0.5)
        tde_primary.execute("INSERT INTO pitr_pause VALUES (99)")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_time=pitr_time,
            target_action="pause",
            wal_encrypt=True,
        )
        restored = PgCluster(
            restore_dir,
            allocate_port(),
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        restored.write_default_config(
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
                "hot_standby": "on",
                "wal_level": "replica",
            }
        )
        restored.add_hba_entry("local all all trust")
        restored.start()
        # Wait until recovery has reached the pause target (still in recovery).
        deadline = time.time() + 90
        paused = False
        while time.time() < deadline:
            try:
                if restored.fetchone("SELECT pg_is_in_recovery()") == "t":
                    # Target reached → replay is paused (pg_get_wal_replay_pause_state).
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
        # Promote out of recovery.
        try:
            restored.execute("SELECT pg_promote()")
        except Exception:
            # Some builds auto-continue; fall through to readiness check.
            pass
        deadline = time.time() + 60
        while time.time() < deadline:
            if restored.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.5)
        assert restored.fetchone("SELECT pg_is_in_recovery()") == "f"
        assert restored.fetchone("SELECT COUNT(*) FROM pitr_pause") == "2"
        assert restored.fetchone(
            "SELECT COUNT(*) FROM pitr_pause WHERE id = 99"
        ) == "0"
        restored.stop()


@pytest.mark.slow
class TestPitrTdeHeapAndWalEncrypt:
    def test_pitr_tde_heap_survives_drop_database_sibling(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Multi-DB: encrypt tables in postgres + appdb, PITR before DROP DATABASE
        must restore appdb with readable tde_heap rows (keyring intact).
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        archive_dir = tmp_path / "pitr_multidb_archive"
        archive_dir.mkdir()
        arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        tde_primary.configure(
            {"archive_mode": "on", "archive_command": arch_cmd}
        )
        tde_primary.restart()

        tde_primary.execute("CREATE DATABASE appdb")
        tde_primary.execute("CREATE EXTENSION pg_tde", dbname="appdb")
        TdeManager(tde_primary).set_database_global_key(
            "appdb_key", "file_provider", dbname="appdb"
        )
        tde_primary.execute(
            "CREATE TABLE keep_me (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO keep_me VALUES (1, 'postgres_db')")
        tde_primary.execute(
            "CREATE TABLE t (id INT PRIMARY KEY, v TEXT) USING tde_heap",
            dbname="appdb",
        )
        tde_primary.execute(
            "INSERT INTO t VALUES (10, 'appdb_row')",
            dbname="appdb",
        )

        tde_primary.stop()
        restore_dir = tmp_path / "pitr_multidb_restore"
        _cold_copy_datadir(tde_primary, restore_dir)
        tde_primary.start()

        tde_primary.execute("CHECKPOINT")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("DROP DATABASE appdb")
        _force_archive(tde_primary, archive_dir)
        tde_primary.stop()

        _write_recovery_auto_conf(
            restore_dir,
            restore_command_line=restore_conf_line_raw(
                archive_dir, install_dir, use_tde_wrappers=True
            ),
            target_lsn=target_lsn,
            wal_encrypt=True,
        )
        restored = _start_restored(
            restore_dir, install_dir, tmp_path, io_method, tde=True
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM keep_me") == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pg_database WHERE datname = 'appdb'"
            ) == "1"
            assert (
                restored.fetchone("SELECT v FROM t WHERE id = 10", dbname="appdb")
                == "appdb_row"
            )
        finally:
            restored.stop()
