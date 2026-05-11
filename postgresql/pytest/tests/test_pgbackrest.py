"""
pgBackRest integration tests for Percona PostgreSQL + pg_tde.

Covers the 10-scenario matrix ported from
``automation/tests/pg_tde_pgbackrest_backup_restore_matrix_test.sh``:

  1. full restore (default — latest backup, replay all WAL)
  2. delta restore into a non-empty directory
  3. standby restore (cluster comes up in recovery mode)
  4. PITR by time
  5. PITR by LSN
  6. PITR by XID
  7. selective per-database restore (``--db-include``)
  8. force restore (``--force`` overrides "destination not empty")
  9. backup chain (full + diff + incr) visible in ``info``
 10. ``check`` succeeds after stanza setup

All matrix tests run with TDE + WAL encryption to mirror the bash scenario.
The original three smoke tests are kept (and deepened) for fast feedback.
"""
import time
from pathlib import Path

import pytest

from conftest import allocate_port
from lib import BackupManager, PgCluster, TdeManager
from lib.backup import PgBaseBackup


pytestmark = [pytest.mark.backup, pytest.mark.pgbackrest, pytest.mark.slow]


# ── helpers ───────────────────────────────────────────────────────────────────


_TDE_RESTORED_PARAMS = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}


def _setup_tde_pgbackrest_source(
    tde_primary: PgCluster,
    tmp_path: Path,
    *,
    stanza: str = "matrix",
    wal_encryption: bool = True,
) -> BackupManager:
    """
    Configure a TDE source cluster for pgBackRest.

    - Optionally enables WAL encryption.
    - Writes pgBackRest config (with ``pg_tde_archive_decrypt`` wrapper).
    - Restarts the cluster so ``archive_mode``/``archive_command`` take effect.
    - Creates the stanza.

    Returns the configured BackupManager. The caller adds data and runs backups.
    """
    if wal_encryption:
        TdeManager(tde_primary).enable_wal_encryption()

    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(tde_primary.data_dir),
        pg_port=tde_primary.port,
        pg_socket_path=str(tde_primary.socket_dir),
        pg_bin=str(tde_primary.bin),
    )
    bm.configure_postgres(tde_primary, pg_tde_wal_archiving=True)
    tde_primary.restart()
    bm.stanza_create()
    return bm


def _create_matrix_schema(cluster: PgCluster) -> None:
    """
    Seed the source cluster with the matrix test schema:
      - ``matrix_t1`` in ``postgres`` (5 000 rows, encrypted)
      - ``matrix_db`` with its own pg_tde extension + key + ``matrix_t2`` (1 000 rows)
    """
    cluster.execute(
        "CREATE TABLE matrix_t1 (id INT PRIMARY KEY, marker TEXT, payload TEXT)"
    )
    cluster.execute(
        "INSERT INTO matrix_t1 "
        "SELECT i, 'seed', md5(i::text) FROM generate_series(1, 5000) i"
    )

    cluster.execute("CREATE DATABASE matrix_db")
    cluster.execute("CREATE EXTENSION pg_tde", dbname="matrix_db")
    # Database-level key must be set in every DB that hosts encrypted tables.
    TdeManager(cluster).set_global_principal_key(dbname="matrix_db")
    cluster.execute(
        "CREATE TABLE matrix_t2 (id INT PRIMARY KEY, data TEXT)",
        dbname="matrix_db",
    )
    cluster.execute(
        "INSERT INTO matrix_t2 "
        "SELECT i, md5(i::text) FROM generate_series(1, 1000) i",
        dbname="matrix_db",
    )


def _start_restored_cluster(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    role: str = "primary",
    timeout: int = 120,
) -> PgCluster:
    """Boot a restored TDE cluster from a pgBackRest restore directory."""
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    # pgBackRest preserves a postgresql.conf from the backup; overwrite so we
    # land on a known port/socket and our TDE preload is in place.
    cluster.write_default_config(role, extra_params=_TDE_RESTORED_PARAMS)
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.wait_ready(timeout=timeout)
    return cluster


# ── original smoke tests (deepened) ───────────────────────────────────────────


class TestPgBackRest:
    """Smoke tests — fast feedback. Deeper matrix lives in TestPgBackRestMatrix."""

    def test_full_backup_and_restore(
        self, primary_cluster: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        primary_cluster.execute(
            "CREATE TABLE pgbr_test (id INT PRIMARY KEY, data TEXT)"
        )
        primary_cluster.execute(
            "INSERT INTO pgbr_test "
            "SELECT i, md5(i::text) FROM generate_series(1, 5000) i"
        )
        # Capture a checksum so silent corruption is detected post-restore.
        checksum_src = primary_cluster.fetchone(
            "SELECT md5(string_agg(data, '' ORDER BY id)) FROM pgbr_test"
        )

        bm = BackupManager(stanza="full_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary_cluster.data_dir),
            pg_port=primary_cluster.port,
            pg_socket_path=str(primary_cluster.socket_dir),
        )
        bm.configure_postgres(primary_cluster)
        primary_cluster.restart()
        bm.stanza_create()
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary_cluster)

        restore_dir = tmp_path / "pgbr_restore"
        bm.restore(str(restore_dir))

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM pgbr_test") == "5000"
            assert restored.fetchone(
                "SELECT md5(string_agg(data, '' ORDER BY id)) FROM pgbr_test"
            ) == checksum_src, "Restored data does not match source checksum"
            # Schema preserved (primary key still enforced).
            with pytest.raises(RuntimeError):
                restored.execute("INSERT INTO pgbr_test VALUES (1, 'dup')")
            # And the restored cluster is writable.
            restored.execute("INSERT INTO pgbr_test VALUES (99999, 'post')")
        finally:
            restored.stop()

    def test_incremental_backup(
        self, primary_cluster: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = BackupManager(stanza="incr_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary_cluster.data_dir),
            pg_port=primary_cluster.port,
            pg_socket_path=str(primary_cluster.socket_dir),
        )
        bm.configure_postgres(primary_cluster)
        primary_cluster.restart()
        bm.stanza_create()
        bm.backup(backup_type="full")

        primary_cluster.execute("CREATE TABLE incr_data (id INT, payload TEXT)")
        primary_cluster.execute(
            "INSERT INTO incr_data "
            "SELECT i, md5(i::text) FROM generate_series(1, 1000) i"
        )
        bm.backup(backup_type="incr")
        bm.wait_for_wal_archive(primary_cluster)

        info = bm.info()
        # Both backups must show up in the chain.
        assert "full backup" in info.lower()
        assert "incr backup" in info.lower()

        # Restore from the incr (pgBackRest auto-chains it back to its full).
        restore_dir = tmp_path / "incr_restore"
        bm.restore(str(restore_dir))
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            # Rows from BOTH backups must be present.
            assert restored.fetchone("SELECT COUNT(*) FROM incr_data") == "1000"
        finally:
            restored.stop()

    def test_backup_with_tde(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """pgBackRest + pg_tde WAL encryption end-to-end (Percona walkthrough)."""
        tde_primary.execute(
            "CREATE TABLE tde_pgbr_test (id INT PRIMARY KEY, secret TEXT)"
        )
        tde_primary.execute(
            "INSERT INTO tde_pgbr_test "
            "SELECT i, md5(i::text) FROM generate_series(1, 1000) i"
        )
        checksum_src = tde_primary.fetchone(
            "SELECT md5(string_agg(secret, '' ORDER BY id)) FROM tde_pgbr_test"
        )

        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="tde_test",
        )
        bm.backup()
        bm.wait_for_wal_archive(tde_primary)
        assert "full backup" in bm.info().lower()

        restore_dir = tmp_path / "tde_pgbr_restore"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM tde_pgbr_test"
            ) == "1000"
            assert restored.fetchone(
                "SELECT md5(string_agg(secret, '' ORDER BY id)) FROM tde_pgbr_test"
            ) == checksum_src
            # Encryption survived backup/restore.
            restored_tde = TdeManager(restored)
            assert restored_tde.is_table_encrypted("tde_pgbr_test")
            assert restored_tde.is_wal_encrypted()
        finally:
            restored.stop()


# ── 10-scenario matrix ────────────────────────────────────────────────────────


class TestPgBackRestMatrix:
    """
    Ten-scenario pgBackRest matrix with pg_tde + WAL encryption.

    Each test is self-contained: it builds its own source cluster + backup,
    runs the specific restore variant, and verifies the restored state.
    """

    # 1. full restore -------------------------------------------------------

    def test_full_restore_recovers_to_latest(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_full"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1"
            ) == "5000"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t2", dbname="matrix_db"
            ) == "1000"
            tde = TdeManager(restored)
            assert tde.is_table_encrypted("matrix_t1")
            assert tde.is_table_encrypted("matrix_t2", dbname="matrix_db")
        finally:
            restored.stop()

    # 2. delta restore ------------------------------------------------------

    def test_delta_restore_into_existing_directory(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """
        Delta restore must succeed even when the target directory already
        contains a (possibly stale) cluster — it overwrites only changed files.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_delta"

        # First, do a default restore so the directory is populated.
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        # Add more data on the source and take another backup.
        tde_primary.execute(
            "INSERT INTO matrix_t1 "
            "SELECT i, 'post_full', md5(i::text) FROM generate_series(5001, 6000) i"
        )
        bm.backup(backup_type="diff")
        bm.wait_for_wal_archive(tde_primary)

        # Delta restore into the non-empty directory.
        bm.restore(str(restore_dir), delta=True, pg_tde_wal_restore=True)

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1"
            ) == "6000", "Delta restore must include the post-full rows"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'post_full'"
            ) == "1000"
        finally:
            restored.stop()

    # 3. standby restore ----------------------------------------------------

    def test_standby_restore_starts_in_recovery(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_standby"
        bm.restore(
            str(restore_dir),
            restore_type="standby",
            pg_tde_wal_restore=True,
        )
        # ``standby.signal`` must be present so PG comes up as a standby.
        assert (restore_dir / "standby.signal").exists()

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, role="replica",
        )
        try:
            assert restored.fetchone("SELECT pg_is_in_recovery()") == "t"
            # Hot standby — reads must succeed even in recovery mode.
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1"
            ) == "5000"
            # Writes must be refused.
            with pytest.raises(RuntimeError):
                restored.execute("INSERT INTO matrix_t1 VALUES (99999, 'x', 'y')")
        finally:
            restored.stop()

    # 4. PITR (time) --------------------------------------------------------

    def test_pitr_by_time(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        # Insert the "kept" row, snapshot the time, then sleep so the
        # post-target insert is comfortably after it.
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (10001, 'pre_target', 'kept')"
        )
        bm.wait_for_wal_archive(tde_primary)
        target_time = tde_primary.fetchone(
            "SELECT clock_timestamp()::text"
        )
        time.sleep(2)
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (10002, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_time"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'pre_target'"
            ) == "1", "Pre-target row must be replayed"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'post_target'"
            ) == "0", "Post-target row must NOT be replayed"
        finally:
            restored.stop()

    # 5. PITR (LSN) ---------------------------------------------------------

    def test_pitr_by_lsn(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (20001, 'pre_target', 'kept')"
        )
        tde_primary.execute("CHECKPOINT")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (20002, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_lsn"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'pre_target'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'post_target'"
            ) == "0"
        finally:
            restored.stop()

    # 6. PITR (XID) ---------------------------------------------------------

    def test_pitr_by_xid(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (30001, 'pre_target', 'kept')"
        )
        # xmin of the just-inserted row = the xid that wrote it. PITR with
        # type=xid target=N replays *up to and including* that xid.
        pre_xid = tde_primary.fetchone(
            "SELECT xmin::text::bigint FROM matrix_t1 WHERE id = 30001"
        )
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (30002, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_xid"
        bm.restore(
            str(restore_dir),
            restore_type="xid",
            target=pre_xid,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'pre_target'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'post_target'"
            ) == "0"
        finally:
            restored.stop()

    # 7. selective DB restore ----------------------------------------------

    def test_selective_db_restore_includes_named_db_only(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_selective"
        bm.restore(
            str(restore_dir),
            db_include=["matrix_db"],
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            # Included DB has its data.
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t2", dbname="matrix_db"
            ) == "1000"
            # Excluded DB's user tables: pgBackRest zero-fills the data files,
            # so any read raises an error.
            with pytest.raises(RuntimeError):
                restored.execute("SELECT COUNT(*) FROM matrix_t1")
        finally:
            restored.stop()

    # 8. force restore ------------------------------------------------------

    def test_force_restore_overwrites_dirty_target(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_force"
        restore_dir.mkdir()
        # Leave a stray file behind so pgBackRest sees a non-empty directory.
        (restore_dir / "stray_file.txt").write_text("would block restore")

        bm.restore(
            str(restore_dir),
            force=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1"
            ) == "5000"
        finally:
            restored.stop()

    # 9. backup chain info --------------------------------------------------

    def test_backup_chain_full_diff_incr_visible_in_info(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)

        bm.backup(backup_type="full")
        tde_primary.execute(
            "INSERT INTO matrix_t1 "
            "SELECT i, 'after_full', md5(i::text) FROM generate_series(5001, 5500) i"
        )
        bm.backup(backup_type="diff")
        tde_primary.execute(
            "INSERT INTO matrix_t1 "
            "SELECT i, 'after_diff', md5(i::text) FROM generate_series(5501, 6000) i"
        )
        bm.backup(backup_type="incr")
        bm.wait_for_wal_archive(tde_primary)

        info_text = bm.info().lower()
        assert "full backup" in info_text
        assert "diff backup" in info_text
        assert "incr backup" in info_text

    # 10. check command -----------------------------------------------------

    def test_check_command_succeeds_after_stanza_setup(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)
        # ``check`` raises subprocess.CalledProcessError on failure; reaching
        # this assertion means the configuration is healthy.
        bm.check()
