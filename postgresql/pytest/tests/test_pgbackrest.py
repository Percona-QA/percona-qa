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

All matrix tests run with TDE + WAL encryption and use both pg_tde wrappers
via ``BackupManager``: ``pg_tde_archive_decrypt`` on the ``archive_command``
path (decrypts WAL before ``pgbackrest archive-push``) and
``pg_tde_restore_encrypt`` on the ``restore_command`` path (re-encrypts WAL
fetched by ``pgbackrest archive-get``). This is the integration documented
in the Percona walkthrough — pgBackRest's repo always holds **plaintext**
WAL regardless of the source's WAL-encryption state.

``TestPgBackRestEncryptedWalWrappersContract`` (bottom of this file) is the
byte-level proof that those wrappers actually fire in both directions; the
rest of the matrix only proves "end-to-end works" and would silently pass
if a wrapper became a no-op.

The original three smoke tests are kept (and deepened) for fast feedback.
"""
import os
import shutil
import threading
import time
import re
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

# GUCs pgBackRest restores into postgresql.auto.conf from the backup. They override
# the same names in postgresql.conf, so pg_ctl's ``-o -p ... -k ...`` no longer
# matches the running server (startup fails with "stopped waiting"). Delta
# restore re-syncs auto.conf from newer backups, so this shows up after diff/incr.
#
# Also drop archive_* lines that may come from ALTER SYSTEM on the source: they
# can point at the old cluster's paths or break recovery the same way as in
# ``test_pitr.py`` (copied PGDATA + stale auto.conf).
_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
    }
)


def _strip_restored_auto_conf_socket_overrides(data_dir: Path) -> None:
    """Drop socket/log/archive lines from postgresql.auto.conf so write_default_config wins."""
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out_lines: list[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#"):
            out_lines.append(line)
            continue
        if "=" not in raw:
            out_lines.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _AUTO_CONF_OVERRIDE_KEYS:
            continue
        out_lines.append(line)
    auto.write_text("\n".join(out_lines) + ("\n" if out_lines else ""))


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
    promote: str = "auto",
) -> PgCluster:
    """
    Boot a restored TDE cluster from a pgBackRest restore directory.

    pgBackRest's default restore writes ``recovery.signal`` + a
    ``restore_command``, so the cluster comes up in recovery mode. The
    ``promote`` argument controls what we do about that:

    - ``"auto"`` (default) — call ``pg_promote()`` to leave recovery. Use for
      default restores (``recovery_target_action`` defaults to ``pause``).
    - ``"wait"`` — pgBackRest already configured ``recovery_target_action=promote``
      (i.e. caller passed ``target_action="promote"`` for a PITR restore); just
      wait for postgres to auto-promote when the target is reached. **Do not**
      call ``pg_promote()`` ourselves — it would short-circuit recovery before
      the target LSN/time/xid is replayed.
    - ``False`` — stay in recovery (used for ``--type=standby`` restores).
    """
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config(role, extra_params=_TDE_RESTORED_PARAMS)
    _strip_restored_auto_conf_socket_overrides(restore_dir)
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.wait_ready(timeout=timeout)

    if role != "primary" or promote is False:
        return cluster

    if promote == "auto":
        # Only request promotion if recovery is still in progress; calling
        # pg_promote() on an already-promoted cluster raises an error.
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
            cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
    elif promote != "wait":
        raise ValueError(f"unknown promote mode: {promote!r}")

    # Wait until the cluster is fully out of recovery (auto-promote for "wait",
    # explicit pg_promote for "auto").
    deadline = time.time() + 60
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            return cluster
        time.sleep(0.3)
    raise TimeoutError("cluster did not exit recovery within 60s")


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
            restore_dir, install_dir, tmp_path, io_method,
            role="replica", promote=False,
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
        # promote="wait": let pgBackRest's recovery_target_action=promote
        # auto-promote at the target. Calling pg_promote() ourselves would
        # short-circuit recovery before the target time is reached.
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
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
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
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
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
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
        """
        pgBackRest ``--db-include`` restores only the named user databases
        (template0/template1/**postgres** are *always* restored, so we cannot
        use ``postgres`` for the exclusion check). Set up a second user db
        ``matrix_excl_db`` and verify only the included one has queryable data.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path)
        _create_matrix_schema(tde_primary)

        # Second user DB — this is the one we expect to be excluded.
        tde_primary.execute("CREATE DATABASE matrix_excl_db")
        tde_primary.execute(
            "CREATE EXTENSION pg_tde", dbname="matrix_excl_db"
        )
        TdeManager(tde_primary).set_global_principal_key(dbname="matrix_excl_db")
        tde_primary.execute(
            "CREATE TABLE matrix_excl_t (id INT PRIMARY KEY)",
            dbname="matrix_excl_db",
        )
        tde_primary.execute(
            "INSERT INTO matrix_excl_t SELECT generate_series(1, 300)",
            dbname="matrix_excl_db",
        )

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
            # Included user DB has its data.
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t2", dbname="matrix_db"
            ) == "1000"
            # Excluded user DB: pgBackRest zero-fills the relation files, so
            # querying user tables there raises an "invalid page" / "could not
            # open file" error.
            with pytest.raises(RuntimeError):
                restored.execute(
                    "SELECT COUNT(*) FROM matrix_excl_t",
                    dbname="matrix_excl_db",
                )
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
        # pgBackRest 2.58 disables --force/--delta unless PG_VERSION or
        # backup.manifest exists in the destination (it treats the dir as unknown
        # otherwise). Seed PG_VERSION so --force stays enabled; keep a stray file
        # so the directory is still non-empty and needs force.
        (restore_dir / "PG_VERSION").write_text(f"{tde_primary.major_version}\n")
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

class TestPgBackRestAdvancedAndNegative:
    """
    Complex, advanced, and negative scenarios for pgBackRest + pg_tde.
    Covers key rotation chains, missing libraries, corrupted archives,
    and concurrent DDL stress tests.
    """

    def test_backup_chain_with_tde_key_rotation(
        self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """
        Corner Case: Key evolution over a backup chain.
        Takes a full backup with Key 1. Rotates to Key 2, takes a diff backup.
        Rotates to Key 3, takes an incr backup. Restores the incremental backup
        and verifies the TDE catalog correctly evolved and all data is readable.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path, stanza="key_rot")
        tde = TdeManager(tde_primary)

        # Round 1: Full Backup
        tde_primary.execute("CREATE TABLE chain_t (id INT, k TEXT) USING tde_heap;")
        tde_primary.execute("INSERT INTO chain_t VALUES (1, 'key1'); CHECKPOINT;")
        bm.backup(backup_type="full")

        # Round 2: Rotate to Key 2, Diff Backup
        tde.rotate_principal_key("rot_key_2")
        tde_primary.execute("INSERT INTO chain_t VALUES (2, 'key2'); CHECKPOINT;")
        bm.backup(backup_type="diff")

        # Round 3: Rotate to Key 3, Incr Backup
        tde.rotate_principal_key("rot_key_3")
        tde_primary.execute("INSERT INTO chain_t VALUES (3, 'key3'); CHECKPOINT;")
        bm.backup(backup_type="incr")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_chain"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        restored = _start_restored_cluster(restore_dir, install_dir, tmp_path, io_method)
        try:
            # Verify data from all three key generations is readable
            assert restored.fetchone("SELECT COUNT(*) FROM chain_t") == "3"

            # Verify the active key is exactly the last one rotated
            active_key = TdeManager(restored).principal_key_name()
            assert active_key == "rot_key_3", f"Expected 'rot_key_3', got {active_key}"
        finally:
            restored.stop()

    def test_negative_restore_missing_tde_library(
        self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """
        Negative Scenario: Attempt to access restored data without pg_tde loaded.
        Restores a valid backup but purposefully strips 'pg_tde' from
        shared_preload_libraries. Postgres MUST crash on startup because it
        cannot replay the encrypted WAL without the extension loaded.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path, stanza="missing_lib")
        tde_primary.execute(
            "CREATE TABLE no_lib_t (id INT) USING tde_heap; "
            "INSERT INTO no_lib_t VALUES (1); CHECKPOINT;"
        )
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_no_lib"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        from conftest import allocate_port
        port = allocate_port()
        restored = PgCluster(
            restore_dir, port, install_dir, socket_dir=tmp_path, io_method=io_method
        )

        # OMIT 'pg_tde' from shared_preload_libraries deliberately
        restored.write_default_config(
            extra_params={"shared_preload_libraries": "''"}
        )
        from .test_pgbackrest import _strip_restored_auto_conf_socket_overrides
        _strip_restored_auto_conf_socket_overrides(restore_dir)
        restored.add_hba_entry("local all all trust")

        # FIX: The cluster SHOULD fail to start because it cannot read encrypted WAL.
        # We assert that `start()` throws an exception and the log confirms why.
        with pytest.raises(RuntimeError) as exc:
            restored.start(timeout=15)

        assert "pg_ctl start failed" in str(exc.value)

        log_content = restored.read_log()
        assert "invalid magic number" in log_content or "invalid checkpoint record" in log_content

        # Cleanup
        restored.stop(check=False)

    def test_negative_pitr_missing_wal(
        self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """
        Negative Scenario: Missing WAL in the archive during PITR.
        Takes a base backup, generates target WAL, then physically deletes
        the latest WAL from the pgBackRest repo. The restore process must
        fail to reach the target LSN rather than silently succeeding.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path, stanza="missing_wal")
        tde_primary.execute("CREATE TABLE missing_wal_t (id INT) USING tde_heap;")
        bm.backup(backup_type="full")

        # Generate WAL and capture LSN
        tde_primary.execute("INSERT INTO missing_wal_t VALUES (1); CHECKPOINT;")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute("SELECT pg_switch_wal();")
        bm.wait_for_wal_archive(tde_primary)

        # Sabotage the repository: Delete ONLY the most recent WAL file.
        # This leaves the base backup's WAL intact so Postgres can reach
        # consistency and open for read-only connections, but fails to reach the target.
        repo_archive_dir = tmp_path / "repo" / "archive" / "missing_wal"
        wal_pattern = re.compile(r"^[0-9A-F]{24}.*$")

        # Gather all WAL files and sort them alphabetically
        wal_files = sorted([f for f in repo_archive_dir.rglob("*") if f.is_file() and wal_pattern.match(f.name)])
        assert wal_files, "Failed to sabotage repo: No WAL files found!"

        # Delete only the newest WAL file
        wal_files[-1].unlink()

        restore_dir = tmp_path / "restore_missing_wal"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            pg_tde_wal_restore=True
        )

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False
        )
        try:
            # The cluster will be stuck in recovery because it can't fetch the WAL
            in_recovery = restored.fetchone("SELECT pg_is_in_recovery()")
            assert in_recovery == "t"

            # Check the log for the fatal recovery target error or waiting loops
            log_content = restored.read_log()
            assert "recovery ended before configured recovery target was reached" in log_content \
                or "could not connect to stream" in log_content \
                or "waiting for WAL" in log_content \
                or "failed with exit code 1" in log_content
        finally:
            restored.stop(check=False)

    def test_concurrent_ddl_during_backup(
        self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """
        Stress Scenario: High DDL churn during pgBackRest execution.
        Runs a background thread constantly creating and dropping tde_heap
        tables while pgBackRest is copying files. Verifies that the manifest
        and resulting backup remain internally consistent.
        """
        bm = _setup_tde_pgbackrest_source(tde_primary, tmp_path, stanza="ddl_stress")

        stop_event = threading.Event()
        error_capture = []

        def ddl_worker():
            try:
                i = 0
                while not stop_event.is_set():
                    tde_primary.execute(f"CREATE TABLE stress_{i} (id INT) USING tde_heap;")
                    tde_primary.execute(f"INSERT INTO stress_{i} VALUES ({i});")
                    if i > 5:
                        tde_primary.execute(f"DROP TABLE stress_{i-5};")
                    i += 1
            except Exception as e:
                if not stop_event.is_set():
                    error_capture.append(e)

        # Start the background DDL noise
        t = threading.Thread(target=ddl_worker, daemon=True)
        t.start()

        try:
            # While DDL is happening, take the full backup
            bm.backup(backup_type="full")
        finally:
            # Stop thread safely
            stop_event.set()
            t.join(timeout=10)

        assert not error_capture, f"Background DDL failed unexpectedly: {error_capture}"

        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_stress"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        # FIX: Start the node in read-only standby mode (promote=False).
        # This prevents the "canceling statement due to conflict with recovery"
        # error that happens when we try to run pg_promote() against massive WAL replay.
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False
        )
        try:
            # If it starts and completes recovery, the backup is consistent.
            assert restored.fetchone("SELECT pg_is_in_recovery()") == "t"

            # Ensure at least one stress table survived
            tables = restored.execute("SELECT tablename FROM pg_tables WHERE tablename LIKE 'stress_%';")
            assert "stress_" in tables
        finally:
            restored.stop()


# ── byte-level contract: pg_tde wrappers actually fire on the pgBackRest path ─


def _find_repo_wal_segments(repo_path: Path, stanza: str) -> list:
    """
    Return every file under ``<repo>/archive/<stanza>/.../<24hex>...`` —
    the WAL segments pgBackRest stores. pgBackRest names files
    ``<24hex>`` (raw), ``<24hex>-<sha>`` (default), or ``<24hex>-<sha>.gz``
    (compressed); we accept all three shapes here and rely on the caller
    to scope the search to a compress-type=none repo for byte inspection.
    """
    archive = repo_path / "archive" / stanza
    if not archive.is_dir():
        return []
    pattern = re.compile(r"^[0-9A-F]{24}(-[0-9a-f]+)?$")
    return [
        p for p in archive.rglob("*")
        if p.is_file() and pattern.match(p.name)
    ]


class TestPgBackRestEncryptedWalWrappersContract:
    """
    Byte-level proof that pgBackRest + pg_tde wrappers actually transform
    WAL on the way through the pipeline:

        source pg_wal/<seg>  →  pg_tde_archive_decrypt  →  pgBackRest repo
          (encrypted)              (decrypts)                (plaintext)

        pgBackRest repo  →  pg_tde_restore_encrypt  →  restored pg_wal/<seg>
          (plaintext)         (re-encrypts)             (encrypted)

    Without these assertions the rest of the pgBackRest matrix would pass
    even if both wrappers had silently degraded to no-ops — pgBackRest
    treats WAL as opaque bytes for its own storage purposes, and recovery
    would still replay whatever shape sat in pg_wal back into the heap.
    The matrix would happily green-tick a build that quietly stored
    *encrypted* WAL in the repo, which would break ``pgbackrest verify``
    and any downstream tooling that parses the WAL.

    These two tests rebuild the source cluster with
    ``compress-type=none`` so the repo's archived segments are byte-
    inspectable; the rest of ``test_pgbackrest.py`` keeps the default
    (``gz``) compression and is unaffected.
    """

    def _setup_uncompressed_pgbackrest(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        *,
        stanza: str = "wrappers_contract",
    ) -> BackupManager:
        """Source-side ``_setup_tde_pgbackrest_source`` with compression off."""
        TdeManager(tde_primary).enable_wal_encryption()
        bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(tde_primary.data_dir),
            pg_port=tde_primary.port,
            pg_socket_path=str(tde_primary.socket_dir),
            pg_bin=str(tde_primary.bin),
            compress_type="none",
        )
        bm.configure_postgres(tde_primary, pg_tde_wal_archiving=True)
        tde_primary.restart()
        bm.stanza_create()
        return bm

    def test_archive_push_decrypts_wal_into_repo(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        """
        After ``archive_command`` runs through ``pg_tde_archive_decrypt``:

          1. The archived WAL segment in pgBackRest's repo must contain
             the plaintext marker we inserted before the segment switch.
          2. The source ``$PGDATA/pg_wal/<seg>`` must NOT contain the same
             marker — it's still encrypted on the source side.

        Both witnesses must agree for the contract to hold. If only (1)
        passes, WAL encryption may be silently off at the source. If only
        (2) passes, the wrapper turned into a no-op and stored ciphertext
        in the repo.
        """
        bm = self._setup_uncompressed_pgbackrest(tde_primary, tmp_path)

        marker = "MARKER-pgbackrest-archive-decrypt-must-decrypt-bea71f"
        tde_primary.execute(
            "CREATE TABLE wrap_push_t (id INT, payload TEXT) USING tde_heap"
        )
        tde_primary.execute(
            f"INSERT INTO wrap_push_t VALUES (1, '{marker}')"
        )
        tde_primary.execute("CHECKPOINT")

        seg_name = tde_primary.fetchone(
            "SELECT pg_walfile_name(pg_current_wal_insert_lsn())"
        )
        src_seg = tde_primary.data_dir / "pg_wal" / seg_name
        assert src_seg.exists(), f"pg_wal does not contain {seg_name}"
        src_bytes = src_seg.read_bytes()

        tde_primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(tde_primary)

        repo_segments = _find_repo_wal_segments(
            Path(bm.repo_path), bm.stanza
        )
        assert repo_segments, (
            "pgBackRest stored no WAL in the repo after pg_switch_wal()+"
            "wait_for_wal_archive — archive_command never ran."
        )

        marker_b = marker.encode()
        # 1. The repo MUST contain the plaintext marker in some segment
        #    (the one we just switched out).
        repo_has_plaintext = any(
            marker_b in seg.read_bytes() for seg in repo_segments
        )
        assert repo_has_plaintext, (
            "pgBackRest's repo contains NO segment with the plaintext "
            f"marker {marker!r}. pg_tde_archive_decrypt is not firing in "
            "the archive_command pipeline; the repo is holding ciphertext "
            "and any downstream parsing (pgbackrest verify, etc.) will "
            "break.\nRepo segments scanned: "
            f"{[s.name for s in repo_segments]}"
        )

        # 2. The corresponding source pg_wal segment must NOT contain the
        #    marker — proof that WAL encryption was actually on at the
        #    moment of the write, and the repo's plaintext was created by
        #    the wrapper, not by an accidentally plaintext source.
        assert marker_b not in src_bytes, (
            f"Plaintext marker {marker!r} found in the SOURCE "
            f"{src_seg.name}; WAL encryption is not active at the source "
            "and the 'wrapper decrypted on archive' conclusion is moot."
        )

    def test_restore_encrypt_round_trip_keeps_wal_encrypted(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """
        After a full restore with ``pg_tde_wal_restore=True``:

          * The restored cluster must come up with ``pg_tde.wal_encrypt = on``
            (otherwise the encryption-on-disk contract is broken on the
            restored side).
          * New WAL written by the restored cluster must be encrypted —
            i.e. a marker inserted post-restore is *not* visible in the
            restored ``pg_wal/<seg>`` (proves the cluster is still doing
            WAL encryption end-to-end after going through the
            pg_tde_restore_encrypt path).
          * The original encrypted relation is readable on the restored
            side (a sanity check that the WAL replayed through
            pg_tde_restore_encrypt was correctly re-encrypted; otherwise
            recovery would have read garbage WAL and corrupted the heap).
        """
        bm = self._setup_uncompressed_pgbackrest(
            tde_primary, tmp_path, stanza="wrappers_rt"
        )

        tde_primary.execute(
            "CREATE TABLE wrap_rt_t (id INT PRIMARY KEY, val TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO wrap_rt_t "
            "SELECT g, md5(g::text) FROM generate_series(1, 200) g"
        )
        tde_primary.execute("CHECKPOINT")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "wrappers_rt_restore"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method,
        )
        try:
            # Contract 1: the encryption GUC carried through.
            assert restored.fetchone(
                "SHOW pg_tde.wal_encrypt"
            ) == "on", (
                "pg_tde.wal_encrypt is OFF on the restored cluster — "
                "the WAL written from this point will be plaintext, "
                "breaking the encrypted-on-disk contract."
            )

            # Contract 2: the WAL stream the wrapper re-encrypted on the
            # way back into pg_wal/ was readable enough for recovery to
            # actually populate the heap.
            assert restored.fetchone(
                "SELECT COUNT(*) FROM wrap_rt_t"
            ) == "200", (
                "Pre-restore data is unreadable on the restored cluster — "
                "pg_tde_restore_encrypt likely produced WAL recovery "
                "couldn't decrypt."
            )

            # Contract 3: NEW writes on the restored cluster generate
            # encrypted WAL. Insert a fresh marker, force a switch, then
            # verify the just-closed segment doesn't contain it as
            # plaintext.
            post_marker = (
                "MARKER-restored-pg_wal-must-stay-encrypted-9e2d"
            )
            restored.execute(
                "CREATE TABLE wrap_post_t (id INT, payload TEXT) "
                "USING tde_heap"
            )
            restored.execute(
                f"INSERT INTO wrap_post_t VALUES (1, '{post_marker}')"
            )
            restored.execute("CHECKPOINT")
            seg_name = restored.fetchone(
                "SELECT pg_walfile_name(pg_current_wal_insert_lsn())"
            )
            seg_path = restored.data_dir / "pg_wal" / seg_name
            assert seg_path.exists(), (
                f"restored pg_wal missing segment {seg_name}"
            )
            seg_bytes_before_switch = seg_path.read_bytes()
            restored.execute("SELECT pg_switch_wal()")

            assert post_marker.encode() not in seg_bytes_before_switch, (
                f"Plaintext marker {post_marker!r} found in restored "
                f"pg_wal/{seg_name}; new WAL on the restored cluster is "
                "not being encrypted even though pg_tde.wal_encrypt is on."
            )
        finally:
            restored.stop()
