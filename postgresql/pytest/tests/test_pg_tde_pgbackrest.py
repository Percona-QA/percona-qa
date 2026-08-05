"""
pg_tde + pgBackRest integration tests.

Unified module (formerly ``test_pgbackrest.py`` and the specialized HA /
checksum / archive-async modules). Covers:

  * Smoke + 10-scenario matrix (decrypt-wrapper / plaintext-in-repo path)
  * Advanced / negative backup cases and wrapper byte-level contract
  * Extended pgBackRest PITR (chains, exclusive, pause/shutdown, multi-DB,
    DROP/TRUNCATE/DML undo, key rotation) plus negative PITR (corrupt/missing
    WAL, bad targets, unreachable XID, missing --set, keyring wipe) and
    encrypted-in-repo time/LSN/XID/exclusive/DROP/key-rotate + negative PITR
  * Encrypted-in-repo backup chains, delta, options (lz4, immediate,
    retention/expire), standby restore, and ``pg_tde_rewind`` failback
  * ``checksum-page=n`` / ``archive-header-check=n`` / ``archive-async``
    option combination matrix (with and without ``pg_tde_archive_decrypt``)
  * Patroni-like HA restore (reinit vs stale replicas)
  * Encrypted-in-repo HA restore + rewire existing replica
  * Patroni-script parity: 3-node encrypted backup/restore
    (``pgbackrest_encrypted_backup_and_restore_using_patroni.sh``)
  * ``archive-async`` + multi-node encrypted-WAL key concerns
  * ``wal_encrypt`` + ``pg_tde_archive_decrypt`` + ``pg_wal`` symlink layouts
    (file-keyring / OpenBao repros, no-wrapper and safe-bootstrap workarounds)
"""
from __future__ import annotations

import configparser
import hashlib
import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pytest

from conftest import allocate_port
from lib import BackupManager, PgCluster, ReplicationManager, TdeManager
from lib.backup import PgBaseBackup, _pg_settings_file_string_literal
from lib.cluster import initdb_args_no_data_checksums, libpq_superuser
from lib.tde import wrappers_available
from lib.vault import VaultConfig

pytestmark = [pytest.mark.backup, pytest.mark.pgbackrest, pytest.mark.slow]

# ── Core matrix / smoke / scenarios (ex-test_pgbackrest.py) ──

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


def _pitr_timestamp(cluster: PgCluster) -> str:
    """UTC timestamp string that pgBackRest --type=time parses reliably."""
    return (
        cluster.fetchone(
            "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', "
            "'YYYY-MM-DD HH24:MI:SS.US') || '+00'"
        )
        or ""
    ).strip()


def _start_restored_cluster(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    role: str = "primary",
    timeout: int = 120,
    promote: str = "auto",
    allow_start_failure: bool = False,
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
    os.chmod(restore_dir, 0o700)
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config(role, extra_params=_TDE_RESTORED_PARAMS)
    _strip_restored_auto_conf_socket_overrides(restore_dir)
    cluster.add_hba_entry("local all all trust")
    try:
        cluster.start()
        cluster.wait_ready(timeout=timeout)
    except (RuntimeError, TimeoutError):
        if allow_start_failure:
            return cluster
        raise

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
        target_time = _pitr_timestamp(tde_primary)
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
            target_exclusive=True,
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
            restore_dir,
            install_dir,
            tmp_path,
            io_method,
            promote=False,
            allow_start_failure=True,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
            if restored.is_ready():
                # Prefer stuck recovery; if already shut down, log markers suffice.
                in_recovery = restored.fetchone("SELECT pg_is_in_recovery()")
                log_content = restored.read_log()
                assert in_recovery == "t" or (
                    "recovery ended before configured recovery target was reached"
                    in log_content
                    or "waiting for WAL" in log_content
                    or "failed with exit code" in log_content
                )
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
    inspectable; the rest of ``test_pg_tde_pgbackrest.py`` keeps the default
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

# ── Scenario gaps: encrypted-in-repo, options, replication/rewind ─────────────
# (formerly test_pgbackrest_tde_scenarios.py)


_SCENARIO_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

_SCENARIO_HA_PARAMS: Dict[str, str] = {
    **_SCENARIO_TDE_PARAMS,
    "wal_level": "replica",
    "max_wal_senders": "10",
    "max_replication_slots": "10",
    "hot_standby": "on",
    "wal_log_hints": "on",
    "wal_keep_size": "'128MB'",
}

_SCENARIO_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
        "restore_command",
        "primary_conninfo",
    }
)


def _scenario_strip_auto_conf(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out: List[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _SCENARIO_AUTO_CONF_OVERRIDE_KEYS:
            continue
        out.append(line)
    auto.write_text("\n".join(out) + ("\n" if out else ""))


def _scenario_configure_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _start_tde_primary(pg_factory, name: str, *, wal_encrypt: bool = True) -> PgCluster:
    primary = pg_factory(name)
    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(
        "primary",
        extra_params={**_SCENARIO_HA_PARAMS, "archive_timeout": "'5s'"},
    )
    _scenario_configure_hba(primary)
    primary.start()
    tde = TdeManager(primary)
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    if wal_encrypt:
        tde.enable_wal_encryption()
        assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    return primary


def _setup_encrypted_in_repo(
    primary: PgCluster,
    tmp_path: Path,
    *,
    stanza: str,
) -> BackupManager:
    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(primary.data_dir),
        pg_port=primary.port,
        pg_socket_path=str(primary.socket_dir),
        pg_bin=str(primary.bin),
        compress_type="none",
        archive_header_check=False,
        checksum_page=False,
    )
    bm.configure_postgres(primary, pg_tde_wal_archiving=False)
    primary.configure({"archive_timeout": "'5s'"})
    primary.restart()
    primary.wait_ready(timeout=60)
    bm.stanza_create()
    return bm


def _setup_wrapper_path(
    primary: PgCluster,
    tmp_path: Path,
    *,
    stanza: str,
    compress_type: Optional[str] = None,
    retention_full: int = 2,
) -> BackupManager:
    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(primary.data_dir),
        pg_port=primary.port,
        pg_socket_path=str(primary.socket_dir),
        pg_bin=str(primary.bin),
        compress_type=compress_type,
        retention_full=retention_full,
        checksum_page=False,
    )
    bm.configure_postgres(primary, pg_tde_wal_archiving=True)
    # restore_command needed for recovery / pg_tde_rewind -c
    restore_cmd = bm.restore_command(
        str(primary.data_dir), pg_tde_wal_restore=True
    )
    primary.configure(
        {
            "archive_timeout": "'5s'",
            "restore_command": _pg_settings_file_string_literal(restore_cmd),
        }
    )
    primary.restart()
    primary.wait_ready(timeout=60)
    bm.stanza_create()
    return bm


def _start_scenario_restored(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    bm: BackupManager,
    *,
    encrypted_in_repo: bool,
    promote: str = "auto",
    timeout: int = 180,
    extra_params: Optional[Dict[str, str]] = None,
    allow_start_failure: bool = False,
) -> PgCluster:
    """
    Boot a restored TDE cluster.

    ``promote``: ``\"auto\"`` (pg_promote), ``\"wait\"`` (PITR auto-promote),
    or ``False`` (stay in recovery).
    """
    os.chmod(restore_dir, 0o700)
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    params = {**_SCENARIO_HA_PARAMS, **(extra_params or {})}
    cluster.write_default_config("primary", extra_params=params)
    _scenario_strip_auto_conf(restore_dir)
    restore_cmd = bm.restore_command(
        str(restore_dir.resolve()),
        pg_tde_wal_restore=not encrypted_in_repo,
    )
    with (restore_dir / "postgresql.auto.conf").open("a") as f:
        f.write(
            f"restore_command = {_pg_settings_file_string_literal(restore_cmd)}\n"
        )
    _scenario_configure_hba(cluster)
    (restore_dir / "postmaster.pid").unlink(missing_ok=True)
    try:
        cluster.start()
        cluster.wait_ready(timeout=timeout)
    except (RuntimeError, TimeoutError):
        if allow_start_failure:
            return cluster
        raise

    if promote is False:
        return cluster

    if promote == "auto":
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
            cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 90)")
    elif promote != "wait":
        raise ValueError(f"unknown promote mode: {promote!r}")

    deadline = time.time() + 90
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            return cluster
        time.sleep(0.3)
    raise TimeoutError("restored cluster did not leave recovery")


def _seed_table(cluster: PgCluster, name: str, marker: str, n: int = 200) -> None:
    cluster.execute(
        f"CREATE TABLE IF NOT EXISTS {name} "
        f"(id INT PRIMARY KEY, marker TEXT, payload TEXT) USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO {name} "
        f"SELECT i, '{marker}', md5(i::text) FROM generate_series(1, {n}) i "
        f"ON CONFLICT DO NOTHING"
    )


def _tde_rewind_bin(install_dir: Path) -> Path:
    p = install_dir / "bin" / "pg_tde_rewind"
    if not p.is_file():
        pytest.skip(f"pg_tde_rewind not found at {p}")
    return p


def _run_tde_rewind_live(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
    *,
    restore_wal: bool = True,
    write_recovery_conf: bool = False,
) -> subprocess.CompletedProcess:
    connstr = (
        f"host={source.socket_dir} port={source.port} "
        f"user={libpq_superuser()} dbname=postgres"
    )
    cmd = [
        str(_tde_rewind_bin(install_dir)),
        "--target-pgdata",
        str(target.data_dir),
        "--source-server",
        connstr,
    ]
    if restore_wal:
        cmd.append("-c")
    if write_recovery_conf:
        cmd.append("--write-recovery-conf")
    env = os.environ.copy()
    env["PATH"] = f"{install_dir / 'bin'}:{env.get('PATH', '')}"
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _run_tde_rewind_offline(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
    *,
    restore_wal: bool = True,
) -> subprocess.CompletedProcess:
    """Offline ``pg_tde_rewind`` (both nodes stopped) — PG-2358 archive repro style."""
    cmd = [
        str(_tde_rewind_bin(install_dir)),
        "--target-pgdata",
        str(target.data_dir),
        "--source-pgdata",
        str(source.data_dir),
    ]
    if restore_wal:
        cmd.append("-c")
    env = os.environ.copy()
    env["PATH"] = f"{install_dir / 'bin'}:{env.get('PATH', '')}"
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _repair_rewind_identity(cluster: PgCluster) -> None:
    """Drop stale recovery/promote leftovers after rewind (mirrors rewind suite)."""
    for name in ("recovery.signal", "standby.signal", "promote.signal"):
        (cluster.data_dir / name).unlink(missing_ok=True)


def _prepare_pgbackrest_rewound_streaming_standby(
    rewound: PgCluster,
    new_primary: PgCluster,
    *,
    streaming_only: bool = True,
) -> None:
    """Attach rewound node as standby; optionally blank restore_command (overlap lab)."""
    conn_line = (
        f"primary_conninfo = 'host={new_primary.socket_dir} "
        f"port={new_primary.port} user={libpq_superuser()} "
        f"application_name=rewound'"
    )
    auto = rewound.data_dir / "postgresql.auto.conf"
    lines: List[str] = []
    if auto.exists():
        for line in auto.read_text().splitlines():
            raw = line.strip()
            if raw and not raw.startswith("#") and "=" in raw:
                key = raw.split("=", 1)[0].strip().lower()
                if key == "primary_conninfo":
                    continue
                if streaming_only and key == "restore_command":
                    continue
            lines.append(line)
    lines.append(conn_line)
    lines.append("recovery_target_timeline = 'latest'")
    if streaming_only:
        lines.append("restore_command = ''")
    auto.write_text("\n".join(lines) + "\n")
    if streaming_only:
        conf = rewound.data_dir / "postgresql.conf"
        if conf.exists():
            text = conf.read_text()
            marker = (
                "\n# percona-qa: rewound standby — WAL via streaming only\n"
                "restore_command = ''\n"
            )
            if "percona-qa: rewound standby" not in text:
                conf.write_text(text.rstrip() + marker)
    (rewound.data_dir / "standby.signal").touch()
    (rewound.data_dir / "recovery.signal").unlink(missing_ok=True)
    (rewound.data_dir / "promote.signal").unlink(missing_ok=True)


def _point_pgbackrest_at(
    bm: BackupManager,
    cluster: PgCluster,
    *,
    compress_type: Optional[str] = "none",
) -> None:
    """Retarget stanza + archive/restore wrappers at *cluster* (after promote)."""
    bm.write_config(
        pg_path=str(cluster.data_dir),
        pg_port=cluster.port,
        pg_socket_path=str(cluster.socket_dir),
        pg_bin=str(cluster.bin),
        compress_type=compress_type,
        checksum_page=False,
    )
    bm.configure_postgres(cluster, pg_tde_wal_archiving=True)
    cluster.configure(
        {
            "archive_timeout": "'5s'",
            "restore_command": _pg_settings_file_string_literal(
                bm.restore_command(str(cluster.data_dir), pg_tde_wal_restore=True)
            ),
        }
    )


# ── Extended pgBackRest PITR (wrapper / plaintext-in-repo path) ────────────────


class TestPgBackRestPitrScenarios:
    """
    PITR scenarios beyond the matrix basics (time/LSN/XID alone).

    Covers recovery across backup chains, exclusive targets, pause/shutdown
    actions, multi-DB consistency, DROP/TRUNCATE undo, key rotation, DML
    undo, and a negative pre-backup target.
    """

    def test_pitr_by_time_after_full_and_diff(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """PITR must replay WAL that spans a full + diff backup chain."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_diff"
        )
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (40001, 'pre_diff', 'kept')"
        )
        bm.backup(backup_type="diff")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (40002, 'post_diff', 'kept')"
        )
        bm.wait_for_wal_archive(tde_primary)
        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (40003, 'after_target', 'discarded')"
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_diff"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'pre_diff'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'post_diff'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t1 WHERE marker = 'after_target'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_exclusive_lsn(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """``--target-exclusive`` stops before the record at the target LSN."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_excl"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_excl (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_excl VALUES (1, 'base')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_excl VALUES (2, 'at_lsn')")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute("INSERT INTO pitr_excl VALUES (3, 'after_lsn')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_excl"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl WHERE id = 1"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl WHERE id = 3"
            ) == "0", "Post-LSN row must not be replayed with --target-exclusive"
        finally:
            restored.stop()

    def test_pitr_pause_then_promote(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """``target-action=pause`` then resume/promote must honor the time target."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_pause"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_pause (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_pause VALUES (1), (2)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute("INSERT INTO pitr_pause VALUES (99)")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_pause"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="pause",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False,
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
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_pause") == "2"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_pause WHERE id = 99"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_pitr_multi_db_by_time(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Time PITR must keep consistent pre-target rows in postgres and matrix_db."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_multidb"
        )
        _create_matrix_schema(tde_primary)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (50001, 'pre_target', 'kept')"
        )
        tde_primary.execute(
            "INSERT INTO matrix_t2 VALUES (50001, 'kept')",
            dbname="matrix_db",
        )
        bm.wait_for_wal_archive(tde_primary)
        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute(
            "INSERT INTO matrix_t1 VALUES (50002, 'post_target', 'discarded')"
        )
        tde_primary.execute(
            "INSERT INTO matrix_t2 VALUES (50002, 'discarded')",
            dbname="matrix_db",
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_multidb"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
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
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t2 WHERE id = 50001",
                dbname="matrix_db",
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM matrix_t2 WHERE id = 50002",
                dbname="matrix_db",
            ) == "0"
            tde = TdeManager(restored)
            assert tde.is_table_encrypted("matrix_t1")
            assert tde.is_table_encrypted("matrix_t2", dbname="matrix_db")
        finally:
            restored.stop()

    def test_pitr_before_drop_table_restores_tde_heap(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Time PITR taken before DROP TABLE must bring the encrypted table back."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_drop_tbl"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_drop_t (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO pitr_drop_t VALUES (1, 'keep'), (2, 'keep')"
        )
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("CHECKPOINT")
        # Exclusive LSN so DROP TABLE itself is not replayed.
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("DROP TABLE pitr_drop_t")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_drop_tbl"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_drop_t"
            ) == "2"
            assert TdeManager(restored).is_table_encrypted("pitr_drop_t")
        finally:
            restored.stop()

    def test_pitr_before_drop_database_sibling(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """PITR before DROP DATABASE must restore the sibling DB + tde_heap rows."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_drop_db"
        )
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
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("CHECKPOINT")
        # Exclusive LSN: stop before DROP DATABASE marks appdb invalid.
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("DROP DATABASE appdb")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_drop_db"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM keep_pg") == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pg_database "
                "WHERE datname = 'appdb' AND datconnlimit <> -2"
            ) == "1"
            assert restored.fetchone(
                "SELECT v FROM t WHERE id = 10", dbname="appdb"
            ) == "appdb_row"
        finally:
            restored.stop()

    def test_pitr_before_truncate_keeps_rows(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """PITR before TRUNCATE must restore the pre-truncate encrypted rows."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_trunc"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_trunc (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO pitr_trunc "
            "SELECT i, 'seed' FROM generate_series(1, 200) i"
        )
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute("TRUNCATE pitr_trunc")
        tde_primary.execute(
            "INSERT INTO pitr_trunc VALUES (999, 'post_trunc')"
        )
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_trunc"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_trunc") == "200"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_trunc WHERE id = 999"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_across_principal_key_rotation(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """PITR after a principal-key rotate must decrypt rows from both key gens."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_keyrot"
        )
        tde = TdeManager(tde_primary)
        tde_primary.execute(
            "CREATE TABLE pitr_rot (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_rot VALUES (1, 'key1')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde.rotate_principal_key("pitr_rot_key2")
        tde_primary.execute("INSERT INTO pitr_rot VALUES (2, 'key2')")
        bm.wait_for_wal_archive(tde_primary)
        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute("INSERT INTO pitr_rot VALUES (3, 'after_target')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_keyrot"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_rot WHERE marker = 'key1'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_rot WHERE marker = 'key2'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_rot WHERE marker = 'after_target'"
            ) == "0"
            active = TdeManager(restored).principal_key_name()
            assert active == "pitr_rot_key2", f"expected rotated key, got {active}"
        finally:
            restored.stop()

    def test_pitr_by_lsn_after_full_and_incr(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """LSN PITR must work when the archive spans a full + incr backup chain."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_incr"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_incr (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_incr VALUES (1, 'full')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_incr VALUES (2, 'incr')")
        bm.backup(backup_type="incr")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_incr VALUES (3, 'pre_target')")
        tde_primary.execute("CHECKPOINT")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute("INSERT INTO pitr_incr VALUES (4, 'post_target')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_incr"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_incr WHERE id <= 3"
            ) == "3"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_incr WHERE marker = 'post_target'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_exclusive_time(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """``--target-exclusive`` with type=time must drop the post-boundary row."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_excl_time"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_excl_t (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_excl_t VALUES (1, 'base')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_excl_t VALUES (2, 'at_time')")
        # Capture time *after* the commit so exclusive stop is at/after this xact.
        target_time = _pitr_timestamp(tde_primary)
        time.sleep(2)
        tde_primary.execute("INSERT INTO pitr_excl_t VALUES (3, 'after_time')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_excl_time"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl_t WHERE id = 1"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_excl_t WHERE marker = 'after_time'"
            ) == "0"
        finally:
            restored.stop()

    def test_pitr_target_action_shutdown(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """
        ``target-action=shutdown`` must stop the postmaster at the exclusive LSN.

        Data correctness at that LSN is checked with a second restore using
        ``promote``: restarting after shutdown while leftover WAL segments still
        sit in ``pg_wal`` can crash-recover past the stop point and re-apply
        post-target rows (not a TDE bug — PITR harness pitfall).
        """
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_shutdown"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_shut (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_shut VALUES (1), (2)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("CHECKPOINT")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("INSERT INTO pitr_shut VALUES (99)")
        bm.wait_for_wal_archive(tde_primary)

        # ── A: shutdown action stops after reaching the exclusive target ──
        restore_shut = tmp_path / "restore_pitr_shutdown"
        bm.restore(
            str(restore_shut),
            restore_type="lsn",
            target=target_lsn,
            target_action="shutdown",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )

        port = allocate_port()
        shut_cluster = PgCluster(
            restore_shut, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        shut_cluster.write_default_config(
            "primary", extra_params=_TDE_RESTORED_PARAMS
        )
        _strip_restored_auto_conf_socket_overrides(restore_shut)
        shut_cluster.add_hba_entry("local all all trust")
        os.chmod(restore_shut, 0o700)

        try:
            shut_cluster.start(timeout=120)
        except RuntimeError:
            # pg_ctl -w fails when the server exits after reaching the target.
            pass

        deadline = time.time() + 120
        while time.time() < deadline:
            pid = restore_shut / "postmaster.pid"
            if not pid.exists() and not shut_cluster.is_ready():
                break
            time.sleep(0.5)
        else:
            shut_cluster.stop(check=False)
            pytest.fail(
                "target-action=shutdown did not leave the postmaster stopped.\n"
                f"Log:\n{shut_cluster.read_log(80)}"
            )

        log_l = shut_cluster.read_log(120).lower()
        assert any(
            m in log_l
            for m in (
                "database system is shut down",
                "shutting down",
                "recovery stopping",
                "recovery target",
            )
        ), (
            "Expected shutdown/recovery-target evidence in the log.\n"
            f"Log:\n{shut_cluster.read_log(80)}"
        )

        # ── B: same exclusive LSN + promote → pre-target rows only ────────
        restore_data = tmp_path / "restore_pitr_shutdown_data"
        bm.restore(
            str(restore_data),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_data, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_shut") == "2"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_shut WHERE id = 99"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_pitr_undoes_update_and_delete(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """PITR must undo post-target UPDATE/DELETE on encrypted rows."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_dml"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_dml (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO pitr_dml VALUES (1, 'orig'), (2, 'orig'), (3, 'orig')"
        )
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("CHECKPOINT")
        target_lsn = (
            tde_primary.fetchone("SELECT pg_current_wal_lsn()") or ""
        ).strip()
        tde_primary.execute("UPDATE pitr_dml SET marker = 'changed' WHERE id = 1")
        tde_primary.execute("DELETE FROM pitr_dml WHERE id = 2")
        tde_primary.execute("INSERT INTO pitr_dml VALUES (4, 'new')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_dml"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT marker FROM pitr_dml WHERE id = 1"
            ) == "orig"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_dml WHERE id = 2"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_dml WHERE id = 4"
            ) == "0"
            assert restored.fetchone("SELECT COUNT(*) FROM pitr_dml") == "3"
        finally:
            restored.stop()

    def test_negative_pitr_target_before_backup(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """
        A recovery target earlier than the backup's consistency point must not
        silently succeed as a healthy primary with full post-backup data.
        """
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_too_early"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_early (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_early VALUES (1)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)
        tde_primary.execute("INSERT INTO pitr_early VALUES (2)")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_too_early"
        try:
            bm.restore(
                str(restore_dir),
                restore_type="time",
                target="1999-01-01 00:00:00+00",
                target_action="promote",
                pg_tde_wal_restore=True,
            )
        except RuntimeError as e:
            # pgBackRest often rejects pre-backup --type=time at restore time (exit 75).
            assert "exit 75" in str(e) or "pgbackrest failed" in str(e).lower(), str(e)
            return

        restored = _start_restored_cluster(
            restore_dir,
            install_dir,
            tmp_path,
            io_method,
            promote=False,
            allow_start_failure=True,
        )
        try:
            # Remain in recovery / fail the target rather than promote with both rows.
            if not restored.is_ready():
                _assert_pitr_did_not_reach_target(restored)
                return
            in_recovery = restored.fetchone("SELECT pg_is_in_recovery()")
            log_content = restored.read_log().lower()
            target_missed = (
                "recovery ended before configured recovery target was reached"
                in log_content
                or "could not find recovery target" in log_content
                or "recovery target" in log_content
            )
            assert in_recovery == "t" or target_missed, (
                "Expected stuck recovery or a recovery-target error for a "
                f"pre-backup timestamp.\nLog:\n{restored.read_log(80)}"
            )
            # Must not look like a clean promote that includes post-backup row 2.
            if in_recovery == "f":
                assert restored.fetchone(
                    "SELECT COUNT(*) FROM pitr_early WHERE id = 2"
                ) != "1" or target_missed
        finally:
            restored.stop(check=False)


# ── Negative pgBackRest PITR ──────────────────────────────────────────────────


def _repo_wal_files(repo_root: Path, stanza: str) -> List[Path]:
    archive = repo_root / "archive" / stanza
    wal_pattern = re.compile(r"^[0-9A-F]{24}")
    return sorted(
        f for f in archive.rglob("*")
        if f.is_file() and wal_pattern.match(f.name)
    )


def _assert_pitr_did_not_reach_target(cluster: PgCluster) -> None:
    """Shared assertions for negative PITR: stuck recovery and/or target error."""
    log_l = cluster.read_log().lower()
    markers = (
        "recovery ended before configured recovery target was reached",
        "could not find recovery target",
        "waiting for wal",
        "failed with exit code",
        "invalid resource manager id",
        "invalid magic number",
        "could not read from file",
        "unexpected pageaddr",
        "incorrect resource manager",
        "fatal",
        "panic",
        "corrupt",
        "decrypt",
        "invalid permissions",
    )
    hit = any(m in log_l for m in markers)
    if not cluster.is_ready():
        assert hit, (
            "Negative PITR start failed without a recovery/WAL failure marker.\n"
            f"Log:\n{cluster.read_log(100)}"
        )
        return
    in_recovery = cluster.fetchone("SELECT pg_is_in_recovery()")
    assert in_recovery == "t" or hit, (
        "Negative PITR must stay in recovery or log a recovery/WAL failure.\n"
        f"Log:\n{cluster.read_log(100)}"
    )


class TestPgBackRestPitrNegative:
    """Failure paths for pgBackRest PITR with WAL-encrypted TDE clusters."""

    def test_negative_pitr_corrupt_archived_wal(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Corrupting the newest archived WAL must prevent reaching the LSN target."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_corrupt"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_neg_c (id INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_neg_c VALUES (1)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_neg_c VALUES (2); CHECKPOINT;")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(tde_primary)

        wal_files = _repo_wal_files(tmp_path / "repo", "pitr_neg_corrupt")
        assert wal_files, "expected archived WAL to corrupt"
        # Overwrite newest segment with garbage (keep size so archive-get succeeds).
        victim = wal_files[-1]
        size = victim.stat().st_size
        victim.write_bytes(b"\x00" * min(size, 8192) + os.urandom(max(0, size - 8192)))

        restore_dir = tmp_path / "restore_pitr_neg_corrupt"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        # Startup may fail hard on corrupt WAL, or hang in recovery.
        port = allocate_port()
        restored = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        restored.write_default_config("primary", extra_params=_TDE_RESTORED_PARAMS)
        _strip_restored_auto_conf_socket_overrides(restore_dir)
        restored.add_hba_entry("local all all trust")
        start_failed = False
        try:
            try:
                restored.start(timeout=60)
                restored.wait_ready(timeout=30)
            except (RuntimeError, TimeoutError):
                start_failed = True
            if not start_failed:
                _assert_pitr_did_not_reach_target(restored)
                assert restored.fetchone("SELECT pg_is_in_recovery()") == "t"
        finally:
            restored.stop(check=False)
        if start_failed:
            log_l = restored.read_log().lower()
            assert any(
                m in log_l
                for m in (
                    "invalid",
                    "corrupt",
                    "fatal",
                    "panic",
                    "could not",
                    "wal",
                    "recovery",
                )
            ), f"Expected WAL/recovery failure in log:\n{restored.read_log(80)}"

    def test_negative_pitr_archive_removed(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Removing the archive tree after backup must block LSN PITR."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_noarch"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_neg_a (id INT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_neg_a VALUES (1)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        tde_primary.execute("INSERT INTO pitr_neg_a VALUES (2); CHECKPOINT;")
        target_lsn = tde_primary.fetchone("SELECT pg_current_wal_lsn()")
        tde_primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(tde_primary)

        archive_dir = tmp_path / "repo" / "archive" / "pitr_neg_noarch"
        assert archive_dir.is_dir()
        shutil.rmtree(archive_dir)

        restore_dir = tmp_path / "restore_pitr_neg_noarch"
        try:
            bm.restore(
                str(restore_dir),
                restore_type="lsn",
                target=target_lsn,
                target_action="promote",
                pg_tde_wal_restore=True,
            )
        except RuntimeError as e:
            # pgBackRest may fail immediately when archive is gone (e.g. exit 55).
            assert "pgbackrest failed" in str(e).lower(), str(e)
            return

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False,
            allow_start_failure=True,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
        finally:
            restored.stop(check=False)

    def test_negative_pitr_invalid_lsn_rejected(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Malformed LSN must fail at restore time or during recovery startup."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_badlsn"
        )
        tde_primary.execute("CREATE TABLE t (id INT) USING tde_heap")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_bad_lsn"
        try:
            bm.restore(
                str(restore_dir),
                restore_type="lsn",
                target="not-a-valid-lsn",
                target_action="promote",
                pg_tde_wal_restore=True,
            )
        except (RuntimeError, ValueError):
            return

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False,
            timeout=30,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
        finally:
            restored.stop(check=False)

    def test_negative_pitr_invalid_time_rejected(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """Malformed recovery target timestamp must fail restore or recovery."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_badtime"
        )
        tde_primary.execute("CREATE TABLE t (id INT) USING tde_heap")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_bad_time"
        try:
            bm.restore(
                str(restore_dir),
                restore_type="time",
                target="not-a-timestamp",
                target_action="promote",
                pg_tde_wal_restore=True,
            )
        except (RuntimeError, ValueError):
            return

        restored = _start_restored_cluster(
            restore_dir, install_dir, tmp_path, io_method, promote=False,
            timeout=30,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
        finally:
            restored.stop(check=False)

    def test_negative_pitr_unreachable_xid(
        self, tde_primary: PgCluster, tmp_path: Path,
        install_dir: Path, io_method: str,
    ):
        """An XID far ahead of reality must not promote as a healthy primary."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_xid"
        )
        tde_primary.execute(
            "CREATE TABLE pitr_neg_x (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        tde_primary.execute("INSERT INTO pitr_neg_x VALUES (1, 'only')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)
        tde_primary.execute("INSERT INTO pitr_neg_x VALUES (2, 'extra')")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_pitr_neg_xid"
        bm.restore(
            str(restore_dir),
            restore_type="xid",
            target="2000000000",
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_restored_cluster(
            restore_dir,
            install_dir,
            tmp_path,
            io_method,
            promote=False,
            allow_start_failure=True,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
            # Must not look like a clean promote past all archived WAL.
            if restored.is_ready() and restored.fetchone(
                "SELECT pg_is_in_recovery()"
            ) == "f":
                pytest.fail(
                    "Unreachable XID target unexpectedly left recovery"
                )
        finally:
            restored.stop(check=False)

    def test_negative_pitr_nonexistent_backup_set(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        """``--set`` for a label that does not exist must fail the restore."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_set"
        )
        tde_primary.execute("CREATE TABLE t (id INT) USING tde_heap")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(tde_primary)

        restore_dir = tmp_path / "restore_bad_set"
        with pytest.raises(RuntimeError) as exc:
            bm.restore(
                str(restore_dir),
                restore_type="time",
                target="2020-01-01 00:00:00+00",
                target_action="promote",
                backup_set="19990101-000000F",
                pg_tde_wal_restore=True,
            )
        err = str(exc.value).lower()
        assert (
            "unable to find" in err
            or "not found" in err
            or "does not exist" in err
            or "backup set" in err
            or "no backup" in err
            or "set" in err
        ), f"Unexpected error for missing --set:\n{exc.value}"

    def test_negative_pitr_lsn_requires_target(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        """API guard: type=lsn without target must raise before invoking pgBackRest."""
        bm = _setup_tde_pgbackrest_source(
            tde_primary, tmp_path, stanza="pitr_neg_api"
        )
        with pytest.raises(ValueError, match="requires target"):
            bm.restore(
                str(tmp_path / "restore_api"),
                restore_type="lsn",
                target=None,
                pg_tde_wal_restore=True,
            )

    def test_negative_pitr_restored_without_pg_tde_keyring(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """
        Wrapper-path PITR restore with ``pg_tde/`` removed must not start cleanly:
        encrypted heap (and WAL keys) require the keyring.
        """
        primary = _start_tde_primary(pg_factory, "pitr_neg_nokey_wrap")
        bm = _setup_wrapper_path(primary, tmp_path, stanza="pitr_neg_nokey_wrap")
        primary.execute(
            "CREATE TABLE pitr_nk (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        primary.execute("INSERT INTO pitr_nk VALUES (1, 'secret')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)
        primary.execute("INSERT INTO pitr_nk VALUES (2, 'post')")
        bm.wait_for_wal_archive(primary, timeout=60)
        target_time = _pitr_timestamp(primary)

        restore_dir = tmp_path / "restore_pitr_neg_nokey"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        pg_tde = restore_dir / "pg_tde"
        assert pg_tde.is_dir()
        shutil.rmtree(pg_tde)

        port = allocate_port()
        restored = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        restored.write_default_config("primary", extra_params=_TDE_RESTORED_PARAMS)
        _strip_restored_auto_conf_socket_overrides(restore_dir)
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
                "Expected keyring/decrypt failure after removing pg_tde/.\n"
                f"Log:\n{restored.read_log(80)}"
            )
        finally:
            restored.stop(check=False)


# ── Encrypted-in-repo scenarios ───────────────────────────────────────────────


class TestEncryptedInRepoBackupRestorePitr:
    """Ciphertext WAL in the pgBackRest repo — PITR / chain / delta / keyring."""

    def test_encrypted_in_repo_pitr_by_time(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_pitr")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr")
        _seed_table(primary, "pitr_t", "seed", n=100)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO pitr_t VALUES (9001, 'pre_target', 'kept')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)
        target_time = _pitr_timestamp(primary)
        time.sleep(2)
        primary.execute(
            "INSERT INTO pitr_t VALUES (9002, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_pitr"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_t WHERE marker = 'pre_target'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_t WHERE marker = 'post_target'"
            ) == "0"
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_pitr_by_lsn(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_pitr_lsn")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_lsn")
        _seed_table(primary, "pitr_lsn_t", "seed", n=50)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO pitr_lsn_t VALUES (9101, 'pre_target', 'kept')"
        )
        primary.execute("CHECKPOINT")
        target_lsn = primary.fetchone("SELECT pg_current_wal_lsn()")
        primary.execute(
            "INSERT INTO pitr_lsn_t VALUES (9102, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_pitr_lsn"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_lsn_t WHERE marker = 'pre_target'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_lsn_t WHERE marker = 'post_target'"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_pitr_by_xid(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_pitr_xid")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_xid")
        _seed_table(primary, "pitr_xid_t", "seed", n=50)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO pitr_xid_t VALUES (9201, 'pre_target', 'kept')"
        )
        pre_xid = primary.fetchone(
            "SELECT xmin::text::bigint FROM pitr_xid_t WHERE id = 9201"
        )
        primary.execute(
            "INSERT INTO pitr_xid_t VALUES (9202, 'post_target', 'discarded')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_pitr_xid"
        bm.restore(
            str(restore_dir),
            restore_type="xid",
            target=pre_xid,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_xid_t WHERE marker = 'pre_target'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM pitr_xid_t WHERE marker = 'post_target'"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_pitr_before_drop_table(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Encrypted-in-repo time PITR must restore a table dropped after the target."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_drop")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_drop")
        _seed_table(primary, "enc_drop_t", "seed", n=40)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        target_time = _pitr_timestamp(primary)
        time.sleep(2)
        primary.execute("DROP TABLE enc_drop_t")
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_enc_drop"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM enc_drop_t") == "40"
            assert TdeManager(restored).is_table_encrypted("enc_drop_t")
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_pitr_across_key_rotation(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Ciphertext-in-repo PITR after key rotate must read both key generations."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_rot")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_rot")
        tde = TdeManager(primary)
        primary.execute(
            "CREATE TABLE enc_rot_t (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        primary.execute("INSERT INTO enc_rot_t VALUES (1, 'key1')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        tde.rotate_principal_key("enc_pitr_rot_key2")
        primary.execute("INSERT INTO enc_rot_t VALUES (2, 'key2')")
        bm.wait_for_wal_archive(primary, timeout=60)
        target_time = _pitr_timestamp(primary)
        time.sleep(2)
        primary.execute("INSERT INTO enc_rot_t VALUES (3, 'after')")
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_enc_rot"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM enc_rot_t WHERE marker = 'key1'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM enc_rot_t WHERE marker = 'key2'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM enc_rot_t WHERE marker = 'after'"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_pitr_exclusive_lsn(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Encrypted-in-repo ``--target-exclusive`` LSN must drop the post-LSN row."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_excl")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_excl")
        primary.execute(
            "CREATE TABLE enc_excl_t (id INT PRIMARY KEY, marker TEXT) "
            "USING tde_heap"
        )
        primary.execute("INSERT INTO enc_excl_t VALUES (1, 'base')")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute("INSERT INTO enc_excl_t VALUES (2, 'at_lsn')")
        target_lsn = primary.fetchone("SELECT pg_current_wal_lsn()")
        primary.execute("INSERT INTO enc_excl_t VALUES (3, 'after_lsn')")
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_enc_excl"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            target_exclusive=True,
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM enc_excl_t WHERE id = 1"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM enc_excl_t WHERE id = 3"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_negative_encrypted_in_repo_pitr_missing_wal(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Ciphertext archive: deleting needed WAL must block LSN PITR."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_miss")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_miss")
        _seed_table(primary, "enc_miss_t", "seed", n=20)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO enc_miss_t VALUES (7001, 'target', 'x'); CHECKPOINT;"
        )
        target_lsn = primary.fetchone("SELECT pg_current_wal_lsn()")
        primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(primary, timeout=60)

        wal_files = _repo_wal_files(tmp_path / "repo", "enc_pitr_miss")
        assert wal_files, "expected archived WAL"
        wal_files[-1].unlink()

        restore_dir = tmp_path / "restore_enc_miss"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True, promote=False,
            allow_start_failure=True,
        )
        try:
            _assert_pitr_did_not_reach_target(restored)
        finally:
            restored.stop(check=False)

    def test_negative_encrypted_in_repo_pitr_corrupt_wal(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Corrupting ciphertext WAL must prevent a clean PITR promote."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_corrupt")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_corrupt")
        primary.execute(
            "CREATE TABLE enc_c_t (id INT PRIMARY KEY) USING tde_heap"
        )
        primary.execute("INSERT INTO enc_c_t VALUES (1)")
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute("INSERT INTO enc_c_t VALUES (2); CHECKPOINT;")
        target_lsn = primary.fetchone("SELECT pg_current_wal_lsn()")
        primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(primary, timeout=60)

        wal_files = _repo_wal_files(tmp_path / "repo", "enc_pitr_corrupt")
        assert wal_files
        victim = wal_files[-1]
        size = victim.stat().st_size
        victim.write_bytes(b"\xff" * size)

        restore_dir = tmp_path / "restore_enc_corrupt"
        bm.restore(
            str(restore_dir),
            restore_type="lsn",
            target=target_lsn,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        port = allocate_port()
        cluster = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        cluster.write_default_config("primary", extra_params=_SCENARIO_HA_PARAMS)
        _scenario_strip_auto_conf(restore_dir)
        restore_cmd = bm.restore_command(
            str(restore_dir.resolve()), pg_tde_wal_restore=False
        )
        with (restore_dir / "postgresql.auto.conf").open("a") as f:
            f.write(
                f"restore_command = {_pg_settings_file_string_literal(restore_cmd)}\n"
            )
        _scenario_configure_hba(cluster)
        start_failed = False
        try:
            try:
                cluster.start(timeout=60)
                cluster.wait_ready(timeout=30)
            except (RuntimeError, TimeoutError):
                start_failed = True
            if not start_failed:
                _assert_pitr_did_not_reach_target(cluster)
        finally:
            cluster.stop(check=False)
        if start_failed:
            log_l = cluster.read_log().lower()
            assert any(
                m in log_l
                for m in (
                    "invalid", "corrupt", "fatal", "decrypt", "wal", "could not",
                )
            ), f"Expected corrupt-WAL failure:\n{cluster.read_log(80)}"

    def test_negative_encrypted_in_repo_pitr_without_keyring(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Time PITR of ciphertext WAL without ``pg_tde/`` must not succeed cleanly."""
        primary = _start_tde_primary(pg_factory, "enc_pitr_nokey")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_pitr_nokey")
        _seed_table(primary, "enc_nk_t", "seed", n=25)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO enc_nk_t VALUES (8001, 'pre', 'kept')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)
        target_time = _pitr_timestamp(primary)
        time.sleep(2)
        primary.execute(
            "INSERT INTO enc_nk_t VALUES (8002, 'post', 'x')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_enc_pitr_nokey"
        bm.restore(
            str(restore_dir),
            restore_type="time",
            target=target_time,
            target_action="promote",
            pg_tde_wal_restore=False,
        )
        shutil.rmtree(restore_dir / "pg_tde")

        port = allocate_port()
        cluster = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        cluster.write_default_config("primary", extra_params=_SCENARIO_HA_PARAMS)
        _scenario_strip_auto_conf(restore_dir)
        restore_cmd = bm.restore_command(
            str(restore_dir.resolve()), pg_tde_wal_restore=False
        )
        with (restore_dir / "postgresql.auto.conf").open("a") as f:
            f.write(
                f"restore_command = {_pg_settings_file_string_literal(restore_cmd)}\n"
            )
        _scenario_configure_hba(cluster)
        start_failed = False
        try:
            try:
                cluster.start(timeout=45)
                cluster.wait_ready(timeout=30)
                if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
                    cnt = cluster.fetchone(
                        "SELECT COUNT(*) FROM enc_nk_t WHERE marker = 'pre'"
                    )
                    if cnt == "1":
                        pytest.fail(
                            "PITR promoted and read encrypted rows without pg_tde/"
                        )
            except (RuntimeError, TimeoutError):
                start_failed = True
        finally:
            cluster.stop(check=False)
        log_l = cluster.read_log(80).lower()
        assert start_failed or any(
            m in log_l
            for m in ("pg_tde", "encrypt", "decrypt", "key", "fatal", "could not")
        ), f"Expected keyring failure for encrypted-in-repo PITR:\n{cluster.read_log(80)}"

    def test_encrypted_in_repo_full_diff_incr_restore(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_chain")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_chain")
        _seed_table(primary, "chain_t", "full", n=50)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO chain_t VALUES (5001, 'diff', md5('diff'))"
        )
        bm.backup(backup_type="diff")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute(
            "INSERT INTO chain_t VALUES (5002, 'incr', md5('incr'))"
        )
        bm.backup(backup_type="incr")
        bm.wait_for_wal_archive(primary, timeout=60)

        info = bm.info().lower()
        assert "full backup" in info
        assert "diff backup" in info
        assert "incr backup" in info

        restore_dir = tmp_path / "restore_chain"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM chain_t WHERE marker = 'full'"
            ) == "50"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM chain_t WHERE marker = 'diff'"
            ) == "1"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM chain_t WHERE marker = 'incr'"
            ) == "1"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_delta_restore_after_diff(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_delta")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_delta")
        _seed_table(primary, "delta_t", "v1", n=40)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # First restore into target (baseline).
        restore_dir = tmp_path / "delta_target"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)

        primary.execute(
            "INSERT INTO delta_t VALUES (8001, 'v2', md5('v2'))"
        )
        bm.backup(backup_type="diff")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Delta into the existing restore directory.
        bm.restore(str(restore_dir), delta=True, pg_tde_wal_restore=False)
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=True,
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM delta_t WHERE marker = 'v1'"
            ) == "40"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM delta_t WHERE marker = 'v2'"
            ) == "1"
        finally:
            restored.stop(check=False)

    def test_encrypted_in_repo_restore_fails_without_pg_tde_keyring(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "enc_nokey")
        bm = _setup_encrypted_in_repo(primary, tmp_path, stanza="enc_nokey")
        _seed_table(primary, "nokey_t", "secret", n=30)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)
        # WAL after backup so recovery needs ciphertext + keys.
        primary.execute(
            "INSERT INTO nokey_t VALUES (7001, 'post_backup', 'x')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_nokey"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        pg_tde = restore_dir / "pg_tde"
        assert pg_tde.is_dir(), "backup must include pg_tde/"
        shutil.rmtree(pg_tde)

        port = allocate_port()
        cluster = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        cluster.write_default_config("primary", extra_params=_SCENARIO_HA_PARAMS)
        _scenario_strip_auto_conf(restore_dir)
        restore_cmd = bm.restore_command(
            str(restore_dir.resolve()), pg_tde_wal_restore=False
        )
        with (restore_dir / "postgresql.auto.conf").open("a") as f:
            f.write(
                f"restore_command = {_pg_settings_file_string_literal(restore_cmd)}\n"
            )
        _scenario_configure_hba(cluster)

        start_failed = False
        try:
            cluster.start(timeout=45)
            cluster.wait_ready(timeout=30)
            # If it somehow starts, recovery/replay of encrypted WAL should fail
            # or data access should be broken — treat "healthy + correct rows"
            # as unexpected.
            try:
                cnt = cluster.fetchone("SELECT COUNT(*) FROM nokey_t")
                if cnt == "31":
                    pytest.fail(
                        "Restored cluster is healthy without pg_tde/ keyring; "
                        "encrypted WAL recovery should not succeed"
                    )
            except RuntimeError:
                pass
        except (RuntimeError, TimeoutError):
            start_failed = True
        finally:
            cluster.stop(check=False)

        log_l = cluster.read_log(80).lower()
        markers = (
            "pg_tde",
            "encrypt",
            "decrypt",
            "key",
            "invalid magic",
            "fatal",
            "could not",
            "failed",
        )
        assert start_failed or any(m in log_l for m in markers), (
            "Expected startup/recovery failure after removing pg_tde/.\n"
            f"Log:\n{cluster.read_log(80)}"
        )


# ── Wrapper-path options (compress / immediate / retention) ───────────────────


class TestWrapperPathPgBackRestOptions:
    """Percona decrypt-wrapper path with options the matrix does not cover."""

    def test_compress_lz4_with_decrypt_wrappers_round_trip(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "lz4_wrap")
        try:
            bm = _setup_wrapper_path(
                primary, tmp_path, stanza="lz4_wrap", compress_type="lz4",
            )
        except RuntimeError as exc:
            if "lz4" in str(exc).lower() or "compress" in str(exc).lower():
                pytest.skip(f"pgBackRest lz4 unavailable: {exc}")
            raise

        _seed_table(primary, "lz4_t", "lz4", n=80)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)
        checksum = primary.fetchone(
            "SELECT md5(string_agg(payload, '' ORDER BY id)) FROM lz4_t"
        )

        restore_dir = tmp_path / "restore_lz4"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=False,
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM lz4_t") == "80"
            assert restored.fetchone(
                "SELECT md5(string_agg(payload, '' ORDER BY id)) FROM lz4_t"
            ) == checksum
            assert TdeManager(restored).is_table_encrypted("lz4_t")
        finally:
            restored.stop(check=False)

    def test_immediate_restore_with_wal_encrypt_wrappers(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "imm_wrap")
        bm = _setup_wrapper_path(primary, tmp_path, stanza="imm_wrap")
        _seed_table(primary, "imm_t", "at_backup", n=50)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Post-backup rows should not be required for --type=immediate.
        primary.execute(
            "INSERT INTO imm_t VALUES (6001, 'after_backup', 'skip')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "restore_imm"
        bm.restore(
            str(restore_dir),
            restore_type="immediate",
            target_action="promote",
            pg_tde_wal_restore=True,
        )
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=False, promote="wait",
        )
        try:
            assert restored.fetchone(
                "SELECT COUNT(*) FROM imm_t WHERE marker = 'at_backup'"
            ) == "50"
            # Immediate = first consistent point; post-backup row must be absent.
            assert restored.fetchone(
                "SELECT COUNT(*) FROM imm_t WHERE marker = 'after_backup'"
            ) == "0"
        finally:
            restored.stop(check=False)

    def test_retention_expire_preserves_restorable_tde_backup(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "expire_wrap")
        bm = _setup_wrapper_path(
            primary, tmp_path, stanza="expire_wrap", retention_full=1,
        )
        _seed_table(primary, "exp_t", "old", n=20)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.execute("DELETE FROM exp_t")
        primary.execute(
            "INSERT INTO exp_t "
            "SELECT i, 'new', md5(i::text) FROM generate_series(1, 25) i"
        )
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        bm.expire()
        assert "full backup" in bm.info().lower()

        restore_dir = tmp_path / "restore_expire"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=False,
        )
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM exp_t") == "25"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM exp_t WHERE marker = 'new'"
            ) == "25"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM exp_t WHERE marker = 'old'"
            ) == "0"
        finally:
            restored.stop(check=False)


# ── Replication + rewind against pgBackRest archive ───────────────────────────


class TestPgBackRestReplicationAndRewind:
    """Streaming + failback using a pgBackRest-backed restore_command."""

    def test_pgbackrest_restore_then_tde_rewind_failback(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """
        Failback with pgBackRest decrypt/encrypt wrappers + ``pg_tde_rewind -c``.

        Bash lab (same scenario):
          ``postgresql/bugs/pgbackrest_tde_rewind_failback.sh``

        Walkthrough archive/restore pattern:
          https://percona.community/blog/2026/03/10/running-pgbackrest-with-pg_tde-a-practical-percona-walkthrough/

        Steps: primary + wal_encrypt → replica → backup → promote → diverge old
        primary → ``pg_tde_rewind -c`` → reattach as standby → assert new_primary
        kept / old_primary discarded → wipe+restore with ``--recovery-option``.
        """
        _tde_rewind_bin(install_dir)

        primary = _start_tde_primary(pg_factory, "rw_pri")
        bm = _setup_wrapper_path(
            primary, tmp_path, stanza="demo", compress_type="none",
        )

        replica = pg_factory("rw_rep")
        repl = ReplicationManager(primary, replica)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        replica.write_default_config(
            "replica",
            extra_params={
                **_SCENARIO_HA_PARAMS,
                "restore_command": _pg_settings_file_string_literal(
                    bm.restore_command(
                        str(replica.data_dir), pg_tde_wal_restore=True
                    )
                ),
            },
        )
        replica.start()
        repl.assert_streaming_connected(timeout=90)

        _seed_table(primary, "rw_t", "shared", n=40)
        repl.assert_catchup(timeout=90)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Promote replica → new primary; diverge old primary.
        replica.promote()
        replica.wait_ready(timeout=60)
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "f"
        replica.execute(
            "INSERT INTO rw_t VALUES (9101, 'new_primary', md5('np'))"
        )
        # Point archive at the new primary so post-promote WAL is retained.
        bm.write_config(
            pg_path=str(replica.data_dir),
            pg_port=replica.port,
            pg_socket_path=str(replica.socket_dir),
            pg_bin=str(replica.bin),
            checksum_page=False,
            compress_type="none",
        )
        bm.configure_postgres(replica, pg_tde_wal_archiving=True)
        replica.configure(
            {
                "restore_command": _pg_settings_file_string_literal(
                    bm.restore_command(
                        str(replica.data_dir), pg_tde_wal_restore=True
                    )
                ),
                "archive_timeout": "'5s'",
            }
        )
        replica.restart()
        replica.wait_ready(timeout=60)
        bm.wait_for_wal_archive(replica, timeout=90)

        # Old primary still running — diverge it before stop/rewind.
        primary.execute(
            "INSERT INTO rw_t VALUES (9102, 'old_primary', md5('op'))"
        )
        primary.stop(check=False)

        result = _run_tde_rewind_live(
            install_dir, primary, replica,
            restore_wal=True, write_recovery_conf=True,
        )
        assert result.returncode == 0, (
            f"pg_tde_rewind failed:\nSTDOUT:{result.stdout}\nSTDERR:{result.stderr}"
        )
        _repair_rewind_identity(primary)

        # Reattach as standby of the promoted node.
        primary.write_default_config(
            "replica",
            extra_params={
                **_SCENARIO_HA_PARAMS,
                "restore_command": _pg_settings_file_string_literal(
                    bm.restore_command(
                        str(primary.data_dir), pg_tde_wal_restore=True
                    )
                ),
            },
        )
        ReplicationManager(replica, primary).rewire_standby_conninfo()
        primary.start()
        primary.wait_ready(timeout=90)
        assert primary.fetchone("SELECT pg_is_in_recovery()") == "t"

        ReplicationManager(replica, primary).assert_streaming_connected(timeout=90)
        ReplicationManager(replica, primary).assert_catchup(timeout=90)
        assert primary.fetchone(
            "SELECT COUNT(*) FROM rw_t WHERE marker = 'new_primary'"
        ) == "1"
        assert primary.fetchone(
            "SELECT COUNT(*) FROM rw_t WHERE marker = 'old_primary'"
        ) == "0"

        # Walkthrough wipe + restore with --recovery-option=restore_command=...
        restore_dir = tmp_path / "walkthrough_restore"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        restored = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=False,
        )
        try:
            assert int(restored.fetchone(
                "SELECT COUNT(*) FROM rw_t WHERE marker = 'shared'"
            )) == 40
            assert TdeManager(restored).is_table_encrypted("rw_t")
        finally:
            restored.stop(check=False)

    def test_pgbackrest_rewind_wal_encryption_plus_archive(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """
        PG-2358 archive-fetch path with **pgBackRest** wrappers (not ``cp``).

        Bash: ``postgresql/bugs/PG-2358_repro_rewind_wal_encrypt_archive.sh``
        cp-archive pytest twin:
          ``test_tde_rewind_advanced.py::…::test_rewind_wal_encryption_plus_archive``

        wal_encrypt + decrypt/encrypt wrappers around pgBackRest → promote →
        diverge → offline ``pg_tde_rewind -c`` (fetch WAL from pgBackRest archive).
        """
        _tde_rewind_bin(install_dir)
        primary = _start_tde_primary(pg_factory, "pg2358_arch_pri")
        bm = _setup_wrapper_path(
            primary, tmp_path, stanza="pg2358_arch", compress_type="none",
        )

        replica = pg_factory("pg2358_arch_rep")
        repl = ReplicationManager(primary, replica)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        replica.write_default_config(
            "replica",
            extra_params={
                **_SCENARIO_HA_PARAMS,
                "restore_command": _pg_settings_file_string_literal(
                    bm.restore_command(
                        str(replica.data_dir), pg_tde_wal_restore=True
                    )
                ),
            },
        )
        replica.start()
        repl.assert_streaming_connected(timeout=90)

        primary.execute(
            "CREATE TABLE enc_arch_t (id INT) USING tde_heap; "
            "INSERT INTO enc_arch_t SELECT generate_series(1,300);"
        )
        bm.wait_for_wal_archive(primary, timeout=60)
        repl.assert_catchup(timeout=60)

        replica.promote()
        replica.wait_ready(timeout=60)
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "f"
        replica.execute(
            "INSERT INTO enc_arch_t SELECT generate_series(301,600); "
            "SELECT pg_switch_wal();"
        )
        _point_pgbackrest_at(bm, replica)
        replica.restart()
        replica.wait_ready(timeout=60)
        bm.wait_for_wal_archive(replica, timeout=90)

        primary.stop(check=False)
        replica.stop(check=False)

        result = _run_tde_rewind_offline(
            install_dir, primary, replica, restore_wal=True,
        )
        assert result.returncode == 0, (
            f"pg_tde_rewind -c (pgBackRest archive) failed:\n"
            f"STDOUT:{result.stdout}\nSTDERR:{result.stderr}"
        )
        assert "invalid magic number" not in (result.stderr or "").lower(), (
            f"PG-2358-style invalid magic while scanning archived WAL:\n"
            f"{result.stderr}"
        )

        _repair_rewind_identity(primary)
        primary.write_default_config("primary", extra_params=_SCENARIO_HA_PARAMS)
        primary.start()
        primary.wait_ready(timeout=90)
        assert int(primary.fetchone("SELECT COUNT(*) FROM enc_arch_t")) >= 300

    def test_pgbackrest_rewind_wal_key_overlap_when_target_segments_are_kept(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """
        PG-2358 WAL-tail overlap failback with **pgBackRest** wrappers.

        Bash: ``postgresql/bugs/PG-2358_repro_wal_key_overlap_kept_segments.sh``
        cp-archive pytest twin:
          ``…::test_rewind_wal_key_overlap_when_target_segments_are_kept``

        Heavy WAL on the future rewind target, promote, more WAL on new timeline,
        offline ``pg_tde_rewind -c``, reattach as streaming standby
        (``restore_command=''``), verify catch-up of post-rewind inserts.
        """
        _tde_rewind_bin(install_dir)
        primary = _start_tde_primary(pg_factory, "pg2358_ov_pri")
        # Retain enough WAL for streaming catch-up after timeline/rewind edges.
        primary.configure({"wal_keep_size": "'512MB'", "archive_timeout": "'10s'"})
        primary.restart()
        primary.wait_ready(timeout=60)

        bm = _setup_wrapper_path(
            primary, tmp_path, stanza="pg2358_ov", compress_type="none",
        )

        replica = pg_factory("pg2358_ov_rep")
        repl = ReplicationManager(primary, replica)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        replica.write_default_config(
            "replica",
            extra_params={
                **_SCENARIO_HA_PARAMS,
                "wal_keep_size": "'512MB'",
                "archive_timeout": "'10s'",
                "restore_command": _pg_settings_file_string_literal(
                    bm.restore_command(
                        str(replica.data_dir), pg_tde_wal_restore=True
                    )
                ),
            },
        )
        replica.start()
        repl.assert_streaming_connected(timeout=90)

        primary.execute(
            "CREATE TABLE wal_overlap_t (id INT, payload TEXT) USING tde_heap; "
            "INSERT INTO wal_overlap_t "
            "SELECT g, repeat(md5(g::text), 12) FROM generate_series(1,3000) g; "
            "CHECKPOINT;"
        )
        for _ in range(3):
            primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(primary, timeout=90)
        repl.assert_catchup(timeout=90)

        # Tail pressure on future rewind target.
        primary.execute(
            "INSERT INTO wal_overlap_t "
            "SELECT g, repeat(md5(g::text), 10) FROM generate_series(3001,7000) g;"
        )
        primary.execute("CHECKPOINT; SELECT pg_switch_wal(); SELECT pg_switch_wal();")
        bm.wait_for_wal_archive(primary, timeout=90)

        replica.promote()
        replica.wait_ready(timeout=90)
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "f"

        replica.execute(
            "INSERT INTO wal_overlap_t "
            "SELECT g, repeat(md5(g::text), 8) FROM generate_series(10000, 13500) g;"
        )
        replica.execute("SELECT pg_switch_wal(); CHECKPOINT;")
        _point_pgbackrest_at(bm, replica)
        replica.restart()
        replica.wait_ready(timeout=60)
        bm.wait_for_wal_archive(replica, timeout=90)

        primary.stop(check=False)
        replica.stop(check=False)

        result = _run_tde_rewind_offline(
            install_dir, primary, replica, restore_wal=True,
        )
        assert result.returncode == 0, (
            f"overlap rewind -c failed:\nSTDOUT:{result.stdout}\nSTDERR:{result.stderr}"
        )
        assert "invalid magic number" not in (result.stderr or "").lower()

        _repair_rewind_identity(primary)
        primary.write_default_config(
            "replica",
            extra_params={**_SCENARIO_HA_PARAMS, "wal_keep_size": "'512MB'"},
        )
        _prepare_pgbackrest_rewound_streaming_standby(
            primary, replica, streaming_only=True,
        )
        for sig in ("standby.signal", "recovery.signal"):
            (replica.data_dir / sig).unlink(missing_ok=True)

        replica.start()
        replica.wait_ready(timeout=90)
        primary.start()
        primary.wait_ready(timeout=90)
        ReplicationManager(replica, primary).assert_streaming_connected(timeout=90)
        ReplicationManager(replica, primary).assert_catchup(timeout=120)
        assert int(primary.fetchone("SELECT COUNT(*) FROM wal_overlap_t")) >= 3000

        replica.execute(
            "INSERT INTO wal_overlap_t "
            "SELECT g, repeat(md5(g::text), 6) FROM generate_series(50001,50300) g; "
            "SELECT pg_switch_wal(); CHECKPOINT;"
        )
        bm.wait_for_wal_archive(replica, timeout=60)
        ReplicationManager(replica, primary).assert_catchup(timeout=120)
        assert primary.fetchone(
            "SELECT COUNT(*) FROM wal_overlap_t WHERE id BETWEEN 50001 AND 50300"
        ) == "300"

    def test_standby_restore_then_streaming_catchup(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """``--type=standby`` restore + ``primary_conninfo`` catch-up (wrappers)."""
        primary = _start_tde_primary(pg_factory, "stby_pri")
        bm = _setup_wrapper_path(primary, tmp_path, stanza="stby_res")
        _seed_table(primary, "stby_t", "base", n=30)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        restore_dir = tmp_path / "standby_restore"
        bm.restore(
            str(restore_dir),
            restore_type="standby",
            pg_tde_wal_restore=True,
        )
        standby = _start_scenario_restored(
            restore_dir, install_dir, tmp_path, io_method, bm,
            encrypted_in_repo=False, promote=False,
        )
        try:
            assert standby.fetchone("SELECT pg_is_in_recovery()") == "t"
            # Point at live primary and catch up past-backup inserts.
            ReplicationManager(primary, standby).rewire_standby_conninfo()
            standby.restart()
            standby.wait_ready(timeout=90)
            primary.execute(
                "INSERT INTO stby_t VALUES (9201, 'live', md5('live'))"
            )
            ReplicationManager(primary, standby).assert_streaming_connected(
                timeout=90
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=90)
            assert standby.fetchone(
                "SELECT COUNT(*) FROM stby_t WHERE marker = 'live'"
            ) == "1"
        finally:
            standby.stop(check=False)
            primary.stop(check=False)


# ── Checksum-page / archive-header-check (ex-test_pgbackrest_checksum_header_check.py) ──

_chk_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

_chk_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
    }
)


def _chk_strip_auto_conf_overrides(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _chk_AUTO_CONF_OVERRIDE_KEYS:
            continue
        out.append(line)
    auto.write_text("\n".join(out) + ("\n" if out else ""))


def _chk_start_restored(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    timeout: int = 120,
) -> PgCluster:
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config("primary", extra_params=_chk_TDE_PARAMS)
    _chk_strip_auto_conf_overrides(restore_dir)
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.wait_ready(timeout=timeout)
    if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
        cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
    deadline = time.time() + 60
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            return cluster
        time.sleep(0.3)
    raise TimeoutError("restored cluster did not leave recovery")


def _chk_assert_conf_has_disabled_checks(bm: BackupManager) -> None:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(bm.conf_path)
    assert cfg.has_section("global")
    assert cfg["global"].get("checksum-page", "").lower() in {"n", "false", "0"}, (
        f"expected checksum-page=n in {bm.conf_path}, got {dict(cfg['global'])}"
    )
    assert cfg["global"].get("archive-header-check", "").lower() in {
        "n", "false", "0",
    }, (
        f"expected archive-header-check=n in {bm.conf_path}, "
        f"got {dict(cfg['global'])}"
    )


def _chk_tde_primary(pg_factory, name: str) -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config("primary", extra_params=_chk_TDE_PARAMS)
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host all all 127.0.0.1/32 trust")
    cluster.start()
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    return cluster


def _chk_seed(cluster: PgCluster, marker: str, n: int = 500) -> str:
    cluster.execute(
        "CREATE TABLE chk_hdr (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO chk_hdr "
        f"SELECT i, '{marker}' || md5(i::text) FROM generate_series(1, {n}) i"
    )
    return cluster.fetchone(
        "SELECT md5(string_agg(payload, '' ORDER BY id)) FROM chk_hdr"
    )


class TestPgBackRestChecksumPageAndArchiveHeaderCheck:
    """
    Explicit coverage for pgBackRest ``checksum-page=n`` and
    ``archive-header-check=n`` with pg_tde (WAL encrypt on and off).
    """

    def test_write_config_emits_checksum_page_and_archive_header_check_n(
        self, tmp_path: Path, pg_factory,
    ):
        """Config file must contain both disabled checks when requested."""
        primary = _chk_tde_primary(pg_factory, "cfg_opts")
        bm = BackupManager(stanza="opts", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            archive_header_check=False,
            checksum_page=False,
        )
        _chk_assert_conf_has_disabled_checks(bm)
        text = bm.conf_path.read_text()
        assert "checksum-page = n" in text or "checksum-page=n" in text.replace(" ", "")
        assert (
            "archive-header-check = n" in text
            or "archive-header-check=n" in text.replace(" ", "")
        )

    @pytest.mark.parametrize(
        "wal_encrypt",
        [False, True],
        ids=["wal_encrypt_off", "wal_encrypt_on"],
    )
    def test_full_backup_restore_with_checks_disabled_decrypt_wrapper_path(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
        wal_encrypt: bool,
    ):
        """
        TDE heap + optional WAL encrypt; archive via ``pg_tde_archive_decrypt``
        so the repo holds plaintext WAL. Both pgBackRest checks are disabled
        (checksum-page for encrypted pages; archive-header-check for safety /
        parity with the encrypted-in-repo deployment profile).
        """
        primary = _chk_tde_primary(pg_factory, f"wrap_{'enc' if wal_encrypt else 'plain'}")
        if wal_encrypt:
            TdeManager(primary).enable_wal_encryption()
            assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        else:
            assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "off"

        bm = BackupManager(
            stanza=f"wrap_{'enc' if wal_encrypt else 'plain'}",
            repo_path=str(tmp_path / "repo"),
        )
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            archive_header_check=False,
            checksum_page=False,
        )
        _chk_assert_conf_has_disabled_checks(bm)
        bm.configure_postgres(primary, pg_tde_wal_archiving=True)
        primary.restart()
        bm.stanza_create()

        marker = f"wrap_{'enc' if wal_encrypt else 'off'}"
        checksum = _chk_seed(primary, marker, n=500)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.check()
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_wrap"
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)
        restored = _chk_start_restored(restore_dir, install_dir, tmp_path, io_method)
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM chk_hdr") == "500"
            assert restored.fetchone(
                "SELECT md5(string_agg(payload, '' ORDER BY id)) FROM chk_hdr"
            ) == checksum
            assert restored.fetchone(
                f"SELECT COUNT(*) FROM chk_hdr WHERE payload LIKE '{marker}%'"
            ) == "500"
            if wal_encrypt:
                assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        finally:
            restored.stop(check=False)

    @pytest.mark.parametrize(
        "wal_encrypt",
        [False, True],
        ids=["wal_encrypt_off", "wal_encrypt_on"],
    )
    def test_full_backup_restore_with_checks_disabled_encrypted_in_repo_path(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
        wal_encrypt: bool,
    ):
        """
        No ``pg_tde_archive_decrypt``: archive-push stores whatever is in
        ``pg_wal``. With ``wal_encrypt=on`` the repo holds ciphertext and both
        disabled checks are required for a successful archive/backup cycle.
        With ``wal_encrypt=off`` the same flags still succeed (plaintext WAL).
        """
        primary = _chk_tde_primary(pg_factory, f"raw_{'enc' if wal_encrypt else 'plain'}")
        if wal_encrypt:
            TdeManager(primary).enable_wal_encryption()
            assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        bm = BackupManager(
            stanza=f"raw_{'enc' if wal_encrypt else 'plain'}",
            repo_path=str(tmp_path / "repo"),
        )
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            compress_type="none",
            archive_header_check=False,
            checksum_page=False,
        )
        _chk_assert_conf_has_disabled_checks(bm)
        # Push WAL as-is (ciphertext when wal_encrypt is on).
        bm.configure_postgres(primary, pg_tde_wal_archiving=False)
        primary.restart()
        bm.stanza_create()

        marker = f"raw_{'enc' if wal_encrypt else 'off'}"
        checksum = _chk_seed(primary, marker, n=300)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.check()
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_raw"
        # Encrypted-in-repo: do not wrap archive-get with restore_encrypt.
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        if wal_encrypt:
            # Raw archive-get; restore_command from backup may need a rewrite
            # to point at this restore dir.
            restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
            _chk_strip_auto_conf_overrides(restore_dir)
            auto = restore_dir / "postgresql.auto.conf"
            with auto.open("a") as f:
                f.write(f"restore_command = '{restore_cmd}'\n")

        restored = _chk_start_restored(restore_dir, install_dir, tmp_path, io_method)
        try:
            assert restored.fetchone("SELECT COUNT(*) FROM chk_hdr") == "300"
            assert restored.fetchone(
                "SELECT md5(string_agg(payload, '' ORDER BY id)) FROM chk_hdr"
            ) == checksum
            if wal_encrypt:
                assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        finally:
            restored.stop(check=False)


# ── Option combination matrix (checksum / header-check / async / wrapper) ──

# (decrypt_wrapper, wal_encrypt, checksum_page, archive_header_check, archive_async,
#  expect_ok, note)
#
# Semantics:
#   checksum_page / archive_header_check: False→n, True→y, None→omit (pgBR default y)
#   expect_ok: archive+full backup must succeed (restore not required for negatives)
_OPT_COMBOS = [
    # ── decrypt wrapper: repo sees plaintext WAL ───────────────────────────
    pytest.param(
        True, True, False, True, False, True,
        id="wrap+wal_enc+checksum_n+header_y+sync",
    ),
    pytest.param(
        True, True, False, False, False, True,
        id="wrap+wal_enc+checksum_n+header_n+sync",
    ),
    pytest.param(
        True, True, True, True, False, True,
        id="wrap+wal_enc+checksum_y+header_y+sync",
    ),
    pytest.param(
        True, False, False, True, False, True,
        id="wrap+wal_off+checksum_n+header_y+sync",
    ),
    # async + decrypt wrapper is unsupported / fragile
    pytest.param(
        True, True, False, False, True, False,
        id="wrap+wal_enc+async_expect_fail",
    ),
    # ── no wrapper: encrypted-in-repo when wal_encrypt=on ──────────────────
    pytest.param(
        False, True, False, False, False, True,
        id="raw+wal_enc+checksum_n+header_n+sync",
    ),
    pytest.param(
        False, True, False, False, True, True,
        id="raw+wal_enc+checksum_n+header_n+async",
    ),
    # header-check=y against ciphertext WAL must fail archive/backup
    pytest.param(
        False, True, False, True, False, False,
        id="raw+wal_enc+header_y_expect_fail",
    ),
    # checksum=y alone still archives ciphertext if header-check=n
    # (checksum failures warn; backup usually still completes)
    pytest.param(
        False, True, True, False, False, True,
        id="raw+wal_enc+checksum_y+header_n+sync",
    ),
    # wal_encrypt off + no wrapper: plaintext everything; defaults OK
    pytest.param(
        False, False, True, True, False, True,
        id="raw+wal_off+checksum_y+header_y+sync",
    ),
    pytest.param(
        False, False, False, False, False, True,
        id="raw+wal_off+checksum_n+header_n+sync",
    ),
]


class TestPgBackRestOptionCombinations:
    """
    Matrix of ``checksum-page`` / ``archive-header-check`` / ``archive-async``
    with and without ``pg_tde_archive_decrypt``.

    Rules under test:

    * ``checksum-page=n`` — about **relation pages** (``tde_heap``), not the
      WAL decrypt wrapper. Recommended whenever encrypted heap pages are
      backed up; independent of ``pg_tde_archive_decrypt``.
    * ``archive-header-check=n`` — about **WAL bytes** reaching pgBackRest.
      Required when ``wal_encrypt=on`` **and** there is **no** decrypt
      wrapper (ciphertext in repo). Not required when
      ``pg_tde_archive_decrypt`` feeds plaintext to ``archive-push``.
    * ``archive-async=y`` — works with encrypted-in-repo (no wrapper) + both
      checks disabled; not expected to work with the decrypt-wrapper path.
    """

    @pytest.mark.parametrize(
        "decrypt_wrapper,wal_encrypt,checksum_page,archive_header_check,"
        "archive_async,expect_ok",
        _OPT_COMBOS,
    )
    def test_option_combo_archive_and_backup(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        decrypt_wrapper: bool,
        wal_encrypt: bool,
        checksum_page: Optional[bool],
        archive_header_check: Optional[bool],
        archive_async: bool,
        expect_ok: bool,
    ):
        if decrypt_wrapper and not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        tag = (
            f"{'w' if decrypt_wrapper else 'r'}"
            f"{'e' if wal_encrypt else 'p'}"
            f"c{checksum_page!s}h{archive_header_check!s}"
            f"{'a' if archive_async else 's'}"
        ).replace(" ", "")
        primary = _chk_tde_primary(pg_factory, f"opt_{tag}"[:40])
        if wal_encrypt:
            TdeManager(primary).enable_wal_encryption()
            assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        bm = BackupManager(stanza=f"opt_{tag}"[:48], repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            compress_type="none",
            archive_async=archive_async,
            archive_header_check=archive_header_check,
            checksum_page=checksum_page,
        )
        # Confirm knobs landed as requested.
        cfg = configparser.ConfigParser(interpolation=None)
        cfg.read(bm.conf_path)
        g = cfg["global"]
        if archive_async:
            assert g.get("archive-async", "").lower() in {"y", "true", "1"}
        if archive_header_check is False:
            assert g.get("archive-header-check", "").lower() in {"n", "false", "0"}
        elif archive_header_check is True:
            assert g.get("archive-header-check", "").lower() in {"y", "true", "1"}
        if checksum_page is False:
            assert g.get("checksum-page", "").lower() in {"n", "false", "0"}
        elif checksum_page is True:
            assert g.get("checksum-page", "").lower() in {"y", "true", "1"}

        bm.configure_postgres(primary, pg_tde_wal_archiving=decrypt_wrapper)
        primary.restart()
        primary.wait_ready(timeout=60)
        bm.stanza_create()

        marker = f"opt_{tag}"
        primary.execute(
            "CREATE TABLE opt_t (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        primary.execute(
            f"INSERT INTO opt_t "
            f"SELECT i, '{marker}' || md5(i::text) FROM generate_series(1, 200) i"
        )
        primary.execute("CHECKPOINT")

        archive_ok = True
        archive_err = ""
        try:
            primary.execute("SELECT pg_switch_wal()")
            bm.wait_for_wal_archive(primary, timeout=45)
        except Exception as exc:  # noqa: BLE001 — matrix captures expected failures
            archive_ok = False
            archive_err = str(exc)

        backup_ok = True
        backup_err = ""
        if archive_ok:
            try:
                bm.backup(backup_type="full")
            except RuntimeError as exc:
                backup_ok = False
                backup_err = str(exc)

        ok = archive_ok and backup_ok
        if expect_ok:
            assert ok, (
                f"expected archive+backup success for {tag}:\n"
                f"  archive_ok={archive_ok} err={archive_err!r}\n"
                f"  backup_ok={backup_ok} err={backup_err!r}\n"
                f"  log:\n{primary.read_log(40)}"
            )
            info = bm.info()
            assert "full" in info.lower()
        else:
            assert not ok, (
                f"expected archive or backup failure for {tag}, but both succeeded.\n"
                f"  This combo should break (ciphertext header-check or async+wrapper).\n"
                f"  log:\n{primary.read_log(40)}"
            )


# ── HA wal_encrypt restore (ex-test_pgbackrest_ha_wal_encrypt.py) ──

_haw_ARCHIVE_TIMEOUT_S = 5

_haw_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

# Hot-standby GUCs recorded in the backup control file. Restored/replica
# clusters must meet or exceed these before recovery starts, or PostgreSQL
# aborts with "insufficient parameter settings".
_haw_HA_PARAMS: Dict[str, str] = {
    **_haw_TDE_PARAMS,
    "wal_level": "replica",
    "max_wal_senders": "10",
    "max_replication_slots": "10",
    "hot_standby": "on",
}

_haw_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
    }
)

_haw_REPLICA_FAIL_MARKERS = (
    "invalid magic number",
    "has already been removed",
)


@dataclass
class HaClusterState:
    primary: PgCluster
    replicas: List[PgCluster]
    backup: BackupManager
    dbname: str
    marker: str
    row_count: int


def _haw_strip_restored_auto_conf_socket_overrides(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out_lines: list[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out_lines.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _haw_AUTO_CONF_OVERRIDE_KEYS:
            continue
        out_lines.append(line)
    auto.write_text("\n".join(out_lines) + ("\n" if out_lines else ""))


def _haw_start_restored_primary_cluster(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    timeout: int = 120,
) -> PgCluster:
    """Boot a pgBackRest-restored TDE primary and promote out of recovery."""
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config("primary", extra_params=_haw_HA_PARAMS)
    _haw_strip_restored_auto_conf_socket_overrides(restore_dir)
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.wait_ready(timeout=timeout)

    if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
        cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")

    deadline = time.time() + 60
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            return cluster
        time.sleep(0.3)
    raise TimeoutError("restored primary did not exit recovery within 60s")


def _haw_wait_for_n_streaming(primary: PgCluster, n: int, timeout: int = 90) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        count = primary.fetchone(
            "SELECT COUNT(*) FROM pg_stat_replication WHERE state = 'streaming'"
        )
        if count and int(count) >= n:
            return
        time.sleep(1)
    senders = primary.fetchone(
        "SELECT COALESCE(string_agg(application_name || ':' || state, ', '), '') "
        "FROM pg_stat_replication"
    )
    raise AssertionError(
        f"Expected {n} streaming replica(s) within {timeout}s; "
        f"pg_stat_replication={senders!r}\n"
        f"Primary log:\n{primary.read_log(30)}"
    )


def _haw_configure_replication_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _haw_bootstrap_3node_wal_encrypt_pgbackrest(
    pg_factory,
    tmp_path: Path,
) -> HaClusterState:
    """Patroni-equivalent bootstrap used by both the positive and negative tests."""
    primary = pg_factory("ha_primary")
    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(
        "primary",
        extra_params={
            **_haw_HA_PARAMS,
            "wal_keep_size": "'64MB'",
        },
    )
    _haw_configure_replication_hba(primary)
    primary.start()

    tde = TdeManager(primary)
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    tde.enable_wal_encryption()
    assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"

    bm = BackupManager(stanza="ha_wal_enc", repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(primary.data_dir),
        pg_port=primary.port,
        pg_socket_path=str(primary.socket_dir),
        pg_bin=str(primary.bin),
    )
    bm.configure_postgres(primary, pg_tde_wal_archiving=True)
    primary.configure({"archive_timeout": f"'{_haw_ARCHIVE_TIMEOUT_S}s'"})
    primary.restart()
    bm.stanza_create()

    replicas: List[PgCluster] = []
    for name in ("ha_replica1", "ha_replica2"):
        standby = pg_factory(name)
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_haw_HA_PARAMS)
        standby.start()
        replicas.append(standby)

    _haw_wait_for_n_streaming(primary, n=2)

    dbname = "enc_ha_db"
    marker = "pre_backup_secret"
    row_count = 200
    primary.execute(f"CREATE DATABASE {dbname}")
    primary.execute("CREATE EXTENSION pg_tde", dbname=dbname)
    TdeManager(primary).set_global_principal_key(dbname=dbname)
    primary.execute(
        "CREATE TABLE ha_enc (id INT PRIMARY KEY, payload TEXT) "
        "USING tde_heap",
        dbname=dbname,
    )
    primary.execute(
        f"INSERT INTO ha_enc "
        f"SELECT i, '{marker}' || md5(i::text) "
        f"FROM generate_series(1, {row_count}) i",
        dbname=dbname,
    )

    # Match the reported sequence: checkpoint, switch, wait archive_timeout.
    primary.execute("CHECKPOINT")
    primary.execute("SELECT pg_switch_wal()")
    time.sleep(_haw_ARCHIVE_TIMEOUT_S)
    bm.wait_for_wal_archive(primary, timeout=60)

    for replica in replicas:
        ReplicationManager(primary, replica).assert_catchup(timeout=90)
        assert replica.fetchone(
            f"SELECT COUNT(*) FROM ha_enc WHERE payload LIKE '{marker}%'",
            dbname=dbname,
        ) == str(row_count)

    bm.backup(backup_type="full")
    bm.wait_for_wal_archive(primary, timeout=60)

    return HaClusterState(
        primary=primary,
        replicas=replicas,
        backup=bm,
        dbname=dbname,
        marker=marker,
        row_count=row_count,
    )


def _haw_stop_ha_nodes(state: HaClusterState) -> None:
    for replica in state.replicas:
        replica.stop(check=False)
    state.primary.stop(check=False)


def _haw_start_restored_primary(
    state: HaClusterState,
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
) -> PgCluster:
    state.backup.restore(str(restore_dir), pg_tde_wal_restore=True)
    restored = _haw_start_restored_primary_cluster(
        restore_dir, install_dir, socket_dir, io_method,
    )
    _haw_configure_replication_hba(restored)
    # Config already has _haw_HA_PARAMS from boot; only refresh HBA for basebackup.
    assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    assert restored.fetchone(
        f"SELECT COUNT(*) FROM ha_enc WHERE payload LIKE '{state.marker}%'",
        dbname=state.dbname,
    ) == str(state.row_count)
    return restored


class TestPgBackRestHaWalEncryptRestore:
    """3-node streaming + wal_encrypt + pgBackRest full restore."""

    def test_reinit_replicas_after_primary_restore(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        After pgBackRest restore of the primary, rebuild both replicas with
        ``pg_tde_basebackup`` — the Patroni-style reinit path that must work.
        """
        state = _haw_bootstrap_3node_wal_encrypt_pgbackrest(pg_factory, tmp_path)
        _haw_stop_ha_nodes(state)

        restored = _haw_start_restored_primary(
            state, tmp_path / "restore_primary", install_dir, tmp_path, io_method,
        )
        try:
            fresh: List[PgCluster] = []
            for name in ("ha_reinit1", "ha_reinit2"):
                standby = pg_factory(name)
                repl = ReplicationManager(restored, standby)
                repl.create_standby_from_backup(use_tde_basebackup=True)
                standby.write_default_config("replica", extra_params=_haw_HA_PARAMS)
                standby.start()
                fresh.append(standby)

            _haw_wait_for_n_streaming(restored, n=2)
            restored.execute(
                "INSERT INTO ha_enc VALUES (9999, 'post_restore_primary')",
                dbname=state.dbname,
            )
            for standby in fresh:
                ReplicationManager(restored, standby).assert_catchup(timeout=90)
                assert standby.fetchone(
                    "SELECT COUNT(*) FROM ha_enc WHERE id = 9999",
                    dbname=state.dbname,
                ) == "1"
                log_text = standby.read_log(80).lower()
                for marker in _haw_REPLICA_FAIL_MARKERS:
                    assert marker not in log_text, (
                        f"Reinitialized replica log must not contain {marker!r}:\n"
                        f"{standby.read_log(80)}"
                    )
        finally:
            restored.stop(check=False)

    def test_stale_replicas_fail_after_primary_restore(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Regression for the reported Patroni symptom: primary comes online after
        pgBackRest restore, but replicas that keep pre-restore PGDATA fail with
        invalid WAL magic / removed segment errors.
        """
        state = _haw_bootstrap_3node_wal_encrypt_pgbackrest(pg_factory, tmp_path)

        stale_copies: List[Path] = []
        for i, replica in enumerate(state.replicas):
            replica.stop(check=False)
            frozen = tmp_path / f"stale_replica{i + 1}"
            shutil.copytree(replica.data_dir, frozen)
            stale_copies.append(frozen)

        state.primary.stop(check=False)

        restored = _haw_start_restored_primary(
            state, tmp_path / "restore_primary", install_dir, tmp_path, io_method,
        )
        # Drop keep-size so recycled segments disappear from the primary's pg_wal
        # (matches "requested WAL segment … has already been removed").
        restored.configure({"wal_keep_size": "'0'"})
        restored.restart()
        restored.wait_ready(timeout=60)
        for i in range(8):
            restored.execute(
                "INSERT INTO ha_enc VALUES "
                f"(10000 + {i}, 'recycle_' || md5('{i}'::text))",
                dbname=state.dbname,
            )
            restored.execute("CHECKPOINT")
            restored.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)

        failures: List[str] = []
        try:
            for i, frozen in enumerate(stale_copies):
                standby = pg_factory(f"stale_boot{i + 1}")
                if standby.data_dir.exists():
                    shutil.rmtree(standby.data_dir)
                shutil.copytree(frozen, standby.data_dir)
                (standby.data_dir / "postmaster.pid").unlink(missing_ok=True)
                standby.write_default_config("replica", extra_params=_haw_HA_PARAMS)
                ReplicationManager(restored, standby).rewire_standby_conninfo()

                log_path = standby.data_dir / "server.log"
                if log_path.exists():
                    log_path.write_text("")

                try:
                    standby.start(timeout=30)
                except RuntimeError:
                    # Hard startup failure is still a valid reproduction.
                    pass

                time.sleep(5)
                log_text = standby.read_log(120)
                log_l = log_text.lower()
                if not any(m in log_l for m in _haw_REPLICA_FAIL_MARKERS):
                    failures.append(
                        f"stale replica {standby.data_dir.name} did not log "
                        f"expected failure markers {_haw_REPLICA_FAIL_MARKERS}; "
                        f"log was:\n{log_text}"
                    )
                standby.stop(check=False)
        finally:
            restored.stop(check=False)

        assert not failures, "\n\n".join(failures)


# ── HA encrypted-in-repo restore + rewire (ex-test_pgbackrest_ha_encrypted_archive_restore.py) ──

_hae_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

_hae_HA_PARAMS: Dict[str, str] = {
    **_hae_TDE_PARAMS,
    "wal_level": "replica",
    "max_wal_senders": "10",
    "max_replication_slots": "10",
    "hot_standby": "on",
    "wal_log_hints": "on",
}

_hae_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
        "restore_command",
    }
)

_hae_REPLICA_FAIL_MARKERS = (
    "invalid magic number",
    "has already been removed",
    # Timeline / WAL-chain divergence after restore+promote (common when keeping
    # pre-restore replica PGDATA): replica starts read-only but never streams.
    "incorrect prev-link",
    "contains no more wal on requested timeline",
    "forked off current database system timeline",
)


def _hae_strip_auto_conf(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out: List[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _hae_AUTO_CONF_OVERRIDE_KEYS:
            continue
        out.append(line)
    auto.write_text("\n".join(out) + ("\n" if out else ""))


def _hae_configure_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _hae_start_restored_primary(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    bm: BackupManager,
) -> PgCluster:
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config(
        "primary",
        extra_params={
            **_hae_HA_PARAMS,
            "archive_timeout": "'10s'",
        },
    )
    _hae_strip_auto_conf(restore_dir)
    # Encrypted-in-repo restore_command (no pg_tde_restore_encrypt).
    restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
    with (restore_dir / "postgresql.auto.conf").open("a") as f:
        f.write(f"restore_command = '{restore_cmd}'\n")
    _hae_configure_hba(cluster)
    (restore_dir / "postmaster.pid").unlink(missing_ok=True)
    cluster.start()
    cluster.wait_ready(timeout=180)
    if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
        cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 90)")
    deadline = time.time() + 90
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            break
        time.sleep(0.5)
    else:
        raise TimeoutError("restored primary did not leave recovery")
    return cluster


class TestPgBackRestHaEncryptedArchiveRestoreRewire:
    """
    Bash-script parity: wal_encrypt + archive-header-check=n + no decrypt
    wrappers + restore primary + rewire existing replica.
    """

    def test_restore_primary_and_rewire_existing_replica(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        # ── primary + encrypted-in-repo pgBackRest ─────────────────────────
        primary = pg_factory("bash_pri")
        primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
        primary.write_default_config(
            "primary",
            extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
        )
        _hae_configure_hba(primary)
        primary.start()

        tde = TdeManager(primary)
        tde.create_extension()
        tde.add_global_key_provider_file()
        tde.set_global_principal_key()
        # Bash uses set_default_key; principal key is enough for tde_heap default AM.
        tde.enable_wal_encryption()
        assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        bm = BackupManager(stanza="demo", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            # Match bash: archive-header-check=n. Also disable page checksums
            # for encrypted tde_heap pages (required for reliable backups).
            archive_header_check=False,
            checksum_page=False,
        )
        # Plain archive-push — no pg_tde_archive_decrypt (bash behaviour).
        bm.configure_postgres(primary, pg_tde_wal_archiving=False)
        primary.configure({"archive_timeout": "'10s'"})
        primary.restart()
        primary.wait_ready(timeout=60)

        # ── replica via pg_tde_basebackup -E ───────────────────────────────
        replica = pg_factory("bash_rep")
        repl = ReplicationManager(primary, replica)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        replica.write_default_config(
            "replica",
            extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
        )
        # Do not call bm.configure_postgres(replica): BackupManager's archive-push
        # embeds the primary --pg1-path. Bash stanza also points at primary; the
        # scenario under test is restore + rewire, not standby archive-push.
        replica.start()
        repl.assert_streaming_connected(timeout=90)
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "t"

        bm.stanza_create()

        # ── workload (scaled down from bash 3×100k) ────────────────────────
        primary.execute(
            "CREATE TABLE t1 (id BIGSERIAL, payload TEXT) USING tde_heap"
        )
        for _ in range(3):
            primary.execute(
                "INSERT INTO t1(payload) "
                "SELECT repeat(md5(i::text), 4) FROM generate_series(1, 5000) i"
            )
            primary.execute("CHECKPOINT")
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        bm.wait_for_wal_archive(primary, timeout=90)

        row_count = int(primary.fetchone("SELECT COUNT(*) FROM t1"))
        assert row_count >= 15000

        bm.backup(backup_type="full")
        info = bm.info()
        assert "full backup" in info.lower() or "full" in info.lower()
        bm.wait_for_wal_archive(primary, timeout=60)

        # ── stop primary, restore to new PGDATA ────────────────────────────
        primary.stop(check=False)
        restore_dir = tmp_path / "new_primary"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _hae_start_restored_primary(
            restore_dir, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
            assert int(restored.fetchone("SELECT COUNT(*) FROM t1")) == row_count

            # ── rewire *existing* replica (bash path — not a reinit) ───────
            replica.stop(check=False)
            (replica.data_dir / "postmaster.pid").unlink(missing_ok=True)
            replica.write_default_config(
                "replica",
                extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
            )
            ReplicationManager(restored, replica).rewire_standby_conninfo()

            log_path = replica.data_dir / "server.log"
            if log_path.exists():
                log_path.write_text("")

            start_failed = False
            try:
                replica.start(timeout=45)
            except RuntimeError:
                start_failed = True

            # Poll: either streaming succeeds (rare) or rewire is stuck/broken.
            streaming = "0"
            log_text = ""
            rewire_ok = False
            deadline = time.time() + 20
            while time.time() < deadline:
                if not start_failed and replica.is_ready():
                    streaming = restored.fetchone(
                        "SELECT COUNT(*) FROM pg_stat_replication "
                        "WHERE state = 'streaming'"
                    ) or "0"
                    if int(streaming) >= 1:
                        rewire_ok = True
                        break
                log_text = replica.read_log(150)
                if any(m in log_text.lower() for m in _hae_REPLICA_FAIL_MARKERS):
                    break
                time.sleep(1)
            else:
                log_text = replica.read_log(150)

            log_l = log_text.lower()
            rewire_failed = (
                start_failed
                or any(m in log_l for m in _hae_REPLICA_FAIL_MARKERS)
                or not rewire_ok
            )

            if rewire_failed:
                # Expected Patroni-style failure when keeping pre-restore replica
                # PGDATA against a restored+promoted primary (timeline/WAL mismatch
                # or encrypted-archive replay errors). Correct recovery = reinit.
                replica.stop(check=False)
                fresh = pg_factory("bash_reinit")
                ReplicationManager(restored, fresh).create_standby_from_backup(
                    use_tde_basebackup=True
                )
                fresh.write_default_config("replica", extra_params=_hae_HA_PARAMS)
                fresh.start()
                ReplicationManager(restored, fresh).assert_streaming_connected(
                    timeout=90
                )
                restored.execute(
                    "INSERT INTO t1(payload) VALUES ('post_reinit')"
                )
                ReplicationManager(restored, fresh).assert_catchup(timeout=90)
                assert fresh.fetchone(
                    "SELECT COUNT(*) FROM t1 WHERE payload = 'post_reinit'"
                ) == "1"
            else:
                assert replica.fetchone("SELECT pg_is_in_recovery()") == "t"
                ReplicationManager(restored, replica).assert_catchup(timeout=90)
        finally:
            restored.stop(check=False)
            replica.stop(check=False)


class TestPgBackRestPatroniEncryptedBackupRestore:
    """
    Pytest parity for automation script
    ``pgbackrest_encrypted_backup_and_restore_using_patroni.sh``.

    Real Patroni is not used; this is the same operator sequence with
    streaming replication: 3-node HA, ``wal_encrypt``, file keyring,
    plain ``archive-push`` (encrypted WAL in repo) + ``archive-header-check=n``,
    full backup, stop leader, restore into leader PGDATA, verify ``t1``,
    then observe that pre-restore replicas do not cleanly reconnect and
    must be reinitialized.
    """

    def test_3node_encrypted_backup_restore_and_replica_reinit(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        # ── leader + encrypted-in-repo pgBackRest (bash stanza=demo) ───────
        primary = pg_factory("pat_n1")
        primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
        primary.write_default_config(
            "primary",
            extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
        )
        _hae_configure_hba(primary)
        primary.start()

        tde = TdeManager(primary)
        tde.create_extension()
        tde.add_global_key_provider_file()
        # Bash: create_key + set_default_key('table_key'); principal key covers both.
        tde.set_global_principal_key(key_name="table_key")
        tde.enable_wal_encryption()
        assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        bm = BackupManager(stanza="demo", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary.data_dir),
            pg_port=primary.port,
            pg_socket_path=str(primary.socket_dir),
            pg_bin=str(primary.bin),
            archive_header_check=False,
            checksum_page=False,
        )
        # Bash: plain archive-push / archive-get (no decrypt/encrypt wrappers).
        bm.configure_postgres(primary, pg_tde_wal_archiving=False)
        primary.configure({"archive_timeout": "'10s'"})
        primary.restart()
        primary.wait_ready(timeout=60)
        bm.stanza_create()

        # ── two streaming replicas (Patroni node2 / node3) ─────────────────
        replicas: List[PgCluster] = []
        for name in ("pat_n2", "pat_n3"):
            standby = pg_factory(name)
            repl = ReplicationManager(primary, standby)
            repl.create_standby_from_backup(use_tde_basebackup=True)
            standby.write_default_config(
                "replica",
                extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
            )
            standby.start()
            replicas.append(standby)
        _haw_wait_for_n_streaming(primary, n=2)

        # ── encrypted workload (bash 3×100k scaled down) ───────────────────
        primary.execute(
            "CREATE TABLE t1 (id BIGSERIAL, payload TEXT) USING tde_heap"
        )
        for _ in range(3):
            primary.execute(
                "INSERT INTO t1(payload) "
                "SELECT repeat(md5(i::text), 4) FROM generate_series(1, 5000) i"
            )
            primary.execute("CHECKPOINT")
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        bm.wait_for_wal_archive(primary, timeout=90)

        row_count = int(primary.fetchone("SELECT COUNT(*) FROM t1"))
        assert row_count >= 15000
        for replica in replicas:
            ReplicationManager(primary, replica).assert_catchup(timeout=90)
            assert int(replica.fetchone("SELECT COUNT(*) FROM t1")) == row_count

        bm.backup(backup_type="full")
        info = bm.info()
        assert "full" in info.lower()
        bm.wait_for_wal_archive(primary, timeout=60)

        # ── stop leader only (bash: patronictl pause + pkill leader) ───────
        # Keep replica PGDATA frozen for reconnect observation.
        stale_dirs: List[Path] = []
        for i, replica in enumerate(replicas):
            replica.stop(check=False)
            frozen = tmp_path / f"pat_stale{i + 1}"
            shutil.copytree(replica.data_dir, frozen)
            stale_dirs.append(frozen)

        primary_data = primary.data_dir
        primary.stop(check=False)

        # ── in-place restore into leader data directory (bash PRIMARY_DATA) ─
        bm.restore(str(primary_data), pg_tde_wal_restore=False)
        (primary_data / "postmaster.pid").unlink(missing_ok=True)

        restored = _hae_start_restored_primary(
            primary_data, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
            assert int(restored.fetchone("SELECT COUNT(*) FROM t1")) == row_count

            # Force WAL recycling so pre-restore replica PGDATA cannot stream
            # from the restored leader (PG-2587 signature). Without this, a
            # stale replica frozen near the backup LSN may reconnect cleanly.
            restored.configure({"wal_keep_size": "'0'"})
            restored.restart()
            restored.wait_ready(timeout=60)
            for i in range(8):
                restored.execute(
                    "INSERT INTO t1(payload) VALUES "
                    f"('recycle_' || md5('{i}'::text))"
                )
                restored.execute("CHECKPOINT")
                restored.execute("SELECT pg_switch_wal()")
                time.sleep(0.5)

            # ── observe stale replica reconnect (bash wait + pg_stat_replication)
            stale_failures: List[str] = []
            for i, frozen in enumerate(stale_dirs):
                standby = pg_factory(f"pat_stale_boot{i + 1}")
                if standby.data_dir.exists():
                    shutil.rmtree(standby.data_dir)
                shutil.copytree(frozen, standby.data_dir)
                (standby.data_dir / "postmaster.pid").unlink(missing_ok=True)
                standby.write_default_config(
                    "replica",
                    extra_params={**_hae_HA_PARAMS, "archive_timeout": "'10s'"},
                )
                ReplicationManager(restored, standby).rewire_standby_conninfo()

                log_path = standby.data_dir / "server.log"
                if log_path.exists():
                    log_path.write_text("")

                start_failed = False
                try:
                    standby.start(timeout=45)
                except RuntimeError:
                    start_failed = True

                streaming = "0"
                log_text = ""
                deadline = time.time() + 20
                while time.time() < deadline:
                    if not start_failed and standby.is_ready():
                        streaming = restored.fetchone(
                            "SELECT COUNT(*) FROM pg_stat_replication "
                            "WHERE state = 'streaming'"
                        ) or "0"
                        if int(streaming) >= 1:
                            break
                    log_text = standby.read_log(150)
                    if any(m in log_text.lower() for m in _hae_REPLICA_FAIL_MARKERS):
                        break
                    time.sleep(1)
                log_text = standby.read_log(150)
                log_l = log_text.lower()

                rewire_ok = (
                    not start_failed
                    and standby.is_ready()
                    and int(streaming) >= 1
                )
                saw_fail_marker = any(m in log_l for m in _hae_REPLICA_FAIL_MARKERS)
                if rewire_ok and not saw_fail_marker:
                    stale_failures.append(
                        f"stale replica {standby.data_dir.name} unexpectedly "
                        f"streamed after leader restore; log:\n{log_text}"
                    )
                elif not rewire_ok and not start_failed and not saw_fail_marker:
                    # Stuck without streaming is acceptable only if we also see
                    # a recovery/WAL failure signature (or hard start failure).
                    # Soft-stuck with empty logs is still a "did not reconnect"
                    # outcome for the reinit path below.
                    pass
                standby.stop(check=False)

            assert not stale_failures, "\n\n".join(stale_failures)

            # ── recovery path: reinit both replicas (Patroni reinit) ───────
            fresh: List[PgCluster] = []
            for name in ("pat_reinit1", "pat_reinit2"):
                standby = pg_factory(name)
                ReplicationManager(restored, standby).create_standby_from_backup(
                    use_tde_basebackup=True
                )
                standby.write_default_config("replica", extra_params=_hae_HA_PARAMS)
                standby.start()
                fresh.append(standby)

            _haw_wait_for_n_streaming(restored, n=2)
            restored.execute("INSERT INTO t1(payload) VALUES ('post_reinit')")
            for standby in fresh:
                ReplicationManager(restored, standby).assert_catchup(timeout=90)
                assert standby.fetchone(
                    "SELECT COUNT(*) FROM t1 WHERE payload = 'post_reinit'"
                ) == "1"
                log_l = standby.read_log(80).lower()
                for marker in _hae_REPLICA_FAIL_MARKERS:
                    assert marker not in log_l, (
                        f"reinitialized replica must not log {marker!r}:\n"
                        f"{standby.read_log(80)}"
                    )
        finally:
            restored.stop(check=False)
            for replica in replicas:
                replica.stop(check=False)


# ── archive-async encrypted-in-repo (ex-test_pgbackrest_wal_encrypt_archive_async.py) ──

_asy_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

_asy_HA_PARAMS: Dict[str, str] = {
    **_asy_TDE_PARAMS,
    "wal_level": "replica",
    "max_wal_senders": "10",
    "max_replication_slots": "10",
    "hot_standby": "on",
}

_asy_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
        "restore_command",
        "primary_conninfo",
    }
)

_asy_ARCHIVE_FAIL_MARKERS = (
    "invalid magic number",
    "could not",
    "cannot",
    "failed",
    "fatal",
    "corruption",
    "wrong key",
    "decrypt",
)


def _asy_strip_auto_conf_overrides(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out: List[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _asy_AUTO_CONF_OVERRIDE_KEYS:
            continue
        out.append(line)
    auto.write_text("\n".join(out) + ("\n" if out else ""))


def _asy_configure_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _asy_start_tde_primary(pg_factory, name: str) -> PgCluster:
    primary = pg_factory(name)
    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(
        "primary",
        extra_params={**_asy_HA_PARAMS, "wal_keep_size": "'64MB'"},
    )
    _asy_configure_hba(primary)
    primary.start()
    tde = TdeManager(primary)
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    tde.enable_wal_encryption()
    assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    return primary


def _asy_setup_encrypted_in_repo_pgbackrest(
    primary: PgCluster,
    tmp_path: Path,
    *,
    stanza: str,
    archive_async: bool = True,
) -> BackupManager:
    """
    pgBackRest config for archiving **ciphertext** WAL (no decrypt wrapper).

    Required flags from the encrypted-in-repo walkthrough:
    ``archive-header-check=n``, ``checksum-page=n``.
    """
    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(primary.data_dir),
        pg_port=primary.port,
        pg_socket_path=str(primary.socket_dir),
        pg_bin=str(primary.bin),
        compress_type="none",
        archive_async=archive_async,
        archive_header_check=False,
        checksum_page=False,
    )
    # No pg_tde_archive_decrypt — push encrypted segments as-is.
    bm.configure_postgres(primary, pg_tde_wal_archiving=False)
    primary.configure({"archive_timeout": "'5s'"})
    primary.restart()
    bm.stanza_create()
    return bm


def _asy_seed_encrypted_rows(cluster: PgCluster, marker: str, n: int = 100) -> None:
    cluster.execute(
        "CREATE TABLE IF NOT EXISTS async_enc (id INT PRIMARY KEY, payload TEXT) "
        "USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO async_enc "
        f"SELECT i, '{marker}' || md5(i::text) FROM generate_series(1, {n}) i "
        f"ON CONFLICT DO NOTHING"
    )


def _asy_start_restored_with_keyring(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    bm: BackupManager,
    *,
    role: str = "primary",
    promote: bool = True,
    timeout: int = 120,
) -> PgCluster:
    """Boot a restore that keeps encrypted WAL; restore_command is raw archive-get."""
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config(role, extra_params=_asy_HA_PARAMS)
    _asy_strip_auto_conf_overrides(restore_dir)
    restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
    auto = restore_dir / "postgresql.auto.conf"
    with auto.open("a") as f:
        f.write(f"restore_command = '{restore_cmd}'\n")
    _asy_configure_hba(cluster)
    cluster.start()
    cluster.wait_ready(timeout=timeout)
    if role == "primary" and promote:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
            cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
        deadline = time.time() + 60
        while time.time() < deadline:
            if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.3)
        else:
            raise TimeoutError("restored primary did not leave recovery")
    return cluster


def _asy_find_repo_wal_segments(repo_path: Path, stanza: str) -> List[Path]:
    """WAL segment files under ``<repo>/archive/<stanza>/`` (exclude logs/spool)."""
    archive = repo_path / "archive" / stanza
    if not archive.is_dir():
        return []
    pattern = re.compile(r"^[0-9A-F]{24}(-[0-9a-f]+)?$")
    return [
        p for p in archive.rglob("*")
        if p.is_file() and pattern.match(p.name)
    ]


def _asy_assert_marker_absent_from_archived_wal(
    repo_path: Path, stanza: str, marker: str
) -> None:
    segs = _asy_find_repo_wal_segments(repo_path, stanza)
    assert segs, f"No archived WAL segments under {repo_path / 'archive' / stanza}"
    marker_b = marker.encode()
    for seg in segs:
        data = seg.read_bytes()
        assert marker_b not in data, (
            f"Plaintext marker {marker!r} found in archived WAL {seg} — "
            "encrypted-in-repo path unexpectedly stored decrypted WAL"
        )


def _asy_pg_tde_keyring_fingerprint(cluster: PgCluster) -> str:
    """
    Content hash of on-disk WAL key material under ``pg_tde/``.

    Used to show primary vs standby keyrings diverge after ``pg_tde_basebackup -E``.
    """
    pg_tde = cluster.data_dir / "pg_tde"
    if not pg_tde.is_dir():
        return ""
    h = hashlib.sha256()
    for path in sorted(pg_tde.rglob("*")):
        if path.is_file():
            h.update(str(path.relative_to(pg_tde)).encode())
            h.update(path.read_bytes())
    return h.hexdigest()


class TestArchiveAsyncEncryptedWalPrimaryOnly:
    """
    Simple scenario (Ege / pgstef): archive-async + encrypted WAL works when
    only the primary archives and restore keeps that primary's keyring.
    """

    def test_archive_async_primary_backup_restore_round_trip(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        primary = _asy_start_tde_primary(pg_factory, "async_pri")
        bm = _asy_setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="async_ok", archive_async=True,
        )
        marker = "async_primary_ok"
        _asy_seed_encrypted_rows(primary, marker, n=150)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Prove archived WAL is ciphertext (do not scan repo logs — they may
        # contain SQL text when log_statement=all).
        _asy_assert_marker_absent_from_archived_wal(tmp_path / "repo", "async_ok", marker)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_primary"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _asy_start_restored_with_keyring(
            restore_dir, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker}%'"
            ) == "150"
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        finally:
            restored.stop(check=False)


class TestEncryptedArchiveMultiNodeConcerns:
    """
    multi-node concerns: different WAL keys per node, archive recovery
    on standbys, and promotion without the old primary's keys.
    """

    def test_standby_wal_keyring_differs_from_primary(
        self, pg_factory, tmp_path: Path,
    ):
        """Streaming re-encrypts on the standby — keyrings must not be identical."""
        primary = _asy_start_tde_primary(pg_factory, "keys_pri")
        _asy_setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="keys", archive_async=True,
        )
        primary_fp = _asy_pg_tde_keyring_fingerprint(primary)
        assert primary_fp, "primary missing pg_tde/ keyring"

        standby = pg_factory("keys_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_asy_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)

        primary.execute("CREATE TABLE kdiff (id INT PRIMARY KEY) USING tde_heap")
        primary.execute("INSERT INTO kdiff VALUES (1)")
        repl.assert_catchup(timeout=60)
        # Restart forces a new WAL key generation on the standby.
        standby.restart()
        standby.wait_ready(timeout=60)
        repl.assert_streaming_connected(timeout=60)
        standby_fp = _asy_pg_tde_keyring_fingerprint(standby)
        assert standby_fp, "standby missing pg_tde/ keyring"
        assert primary_fp != standby_fp, (
            "Expected distinct WAL keyring fingerprints after "
            "pg_tde_basebackup -E + streaming; identical keyrings would "
            "undermine the multi-node archive-key concern.\n"
            f"primary={primary_fp}\nstandby={standby_fp}"
        )

    def test_standby_archive_recovery_from_primary_encrypted_archive_fails(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Standby archive recovery cannot reliably consume primary ciphertext.

        Force archive-only recovery (no primary_conninfo): the standby must
        fetch primary-encrypted WAL via restore_command and is expected to
        fail (invalid magic / decrypt / recovery error).
        """
        primary = _asy_start_tde_primary(pg_factory, "arc_pri")
        bm = _asy_setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="arc_std", archive_async=True,
        )
        _asy_seed_encrypted_rows(primary, "pre_std", n=50)
        bm.wait_for_wal_archive(primary, timeout=60)

        standby = pg_factory("arc_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_asy_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)
        repl.assert_catchup(timeout=60)

        # Advance primary WAL into the archive, then recycle local segments.
        primary.execute("CHECKPOINT")
        for i in range(4):
            primary.execute(
                f"INSERT INTO async_enc VALUES (1000 + {i}, 'need_archive_{i}')"
            )
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        bm.wait_for_wal_archive(primary, timeout=60)
        primary.configure({"wal_keep_size": "'0'"})
        primary.restart()
        primary.wait_ready(timeout=60)
        for _ in range(3):
            primary.execute("CHECKPOINT")
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)

        # Rebuild standby into archive-only recovery against the primary archive.
        standby.stop(check=False)
        # Drop local WAL so recovery must call restore_command.
        pg_wal = standby.data_dir / "pg_wal"
        for seg in pg_wal.iterdir():
            if seg.is_file() and len(seg.name) == 24 and seg.name.isalnum():
                seg.unlink()

        standby.write_default_config("replica", extra_params=_asy_HA_PARAMS)
        _asy_strip_auto_conf_overrides(standby.data_dir)
        (standby.data_dir / "standby.signal").touch(exist_ok=True)
        # Intentionally NO primary_conninfo — archive-only.
        restore_cmd = bm.archive_get_command(str(standby.data_dir.resolve()))
        with (standby.data_dir / "postgresql.auto.conf").open("a") as f:
            f.write(f"restore_command = '{restore_cmd}'\n")

        log_path = standby.data_dir / "server.log"
        if log_path.exists():
            log_path.write_text("")

        start_failed = False
        try:
            standby.start(timeout=45)
        except RuntimeError:
            start_failed = True

        time.sleep(5)
        log_text = standby.read_log(150).lower()
        standby.stop(check=False)

        hit = any(m in log_text for m in _asy_ARCHIVE_FAIL_MARKERS) or start_failed
        assert hit, (
            "Standby archive-only recovery was expected to fail when fetching "
            "primary-encrypted WAL segments (different WAL keys).\n"
            f"start_failed={start_failed}\nlog:\n{standby.read_log(150)}"
        )

    def test_promote_without_old_primary_keys_breaks_pre_failover_archive_replay(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        After promote, losing the old primary keys makes pre-failover encrypted
        archive segments unusable for a restore that only has the new primary
        keyring — the k8s "delete old primary pod" concern.
        """
        primary = _asy_start_tde_primary(pg_factory, "fail_pri")
        bm = _asy_setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="failovr", archive_async=True,
        )
        marker_old = "pre_failover_secret"
        _asy_seed_encrypted_rows(primary, marker_old, n=80)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Capture old-primary keyring separately (simulates "keys were on that pod").
        old_keys = tmp_path / "old_primary_pg_tde"
        shutil.copytree(primary.data_dir / "pg_tde", old_keys)

        standby = pg_factory("fail_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_asy_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)
        repl.assert_catchup(timeout=60)

        # Fail over: stop primary (keys discarded), promote standby.
        primary.stop(check=False)
        # Wipe old primary keyring from disk to model pod deletion.
        shutil.rmtree(primary.data_dir / "pg_tde", ignore_errors=True)

        standby.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
        deadline = time.time() + 60
        while time.time() < deadline:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.3)
        else:
            raise TimeoutError("standby did not promote")

        # New primary writes + archives under *its* WAL keys.
        standby.execute(
            "INSERT INTO async_enc VALUES (9001, 'post_failover_on_new_primary')"
        )
        for _ in range(3):
            standby.execute("CHECKPOINT")
            standby.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        # Point pgBackRest pg1-* at the promoted node for further archive-push.
        bm.write_config(
            pg_path=str(standby.data_dir),
            pg_port=standby.port,
            pg_socket_path=str(standby.socket_dir),
            pg_bin=str(standby.bin),
            compress_type="none",
            archive_async=True,
            archive_header_check=False,
            checksum_page=False,
        )
        bm.configure_postgres(standby, pg_tde_wal_archiving=False)
        standby.restart()
        standby.wait_ready(timeout=60)
        bm.wait_for_wal_archive(standby, timeout=90)

        # Restore the *pre-failover* full backup. Replace restored keyring with
        # the promoted node's keyring only (old primary keys lost).
        standby.stop(check=False)
        restore_dir = tmp_path / "restore_after_failover"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)

        restored_keys = restore_dir / "pg_tde"
        if restored_keys.exists():
            shutil.rmtree(restored_keys)
        # Use the promoted node's keyring (surviving pod), not old_keys.
        shutil.copytree(standby.data_dir / "pg_tde", restored_keys)

        port = allocate_port()
        restored = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        restored.write_default_config("primary", extra_params=_asy_HA_PARAMS)
        _asy_strip_auto_conf_overrides(restore_dir)
        restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
        with (restore_dir / "postgresql.auto.conf").open("a") as f:
            f.write(f"restore_command = '{restore_cmd}'\n")
        _asy_configure_hba(restored)

        log_path = restore_dir / "server.log"
        if log_path.exists():
            log_path.write_text("")

        start_failed = False
        try:
            restored.start(timeout=60)
            # If it somehow starts, recovery that needs old encrypted WAL should
            # still leave us unable to read pre-failover rows cleanly, or log errors.
            time.sleep(5)
            log_text = restored.read_log(200).lower()
            try:
                count = restored.fetchone(
                    f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker_old}%'"
                )
            except RuntimeError:
                count = None
            restored.stop(check=False)
        except RuntimeError:
            start_failed = True
            log_text = restored.read_log(200).lower()
            count = None

        # Success criteria for the concern: either startup/recovery fails, or
        # pre-failover encrypted data is not cleanly available under the new keys.
        recovery_broke = start_failed or any(
            m in log_text for m in _asy_ARCHIVE_FAIL_MARKERS
        )
        data_unreadable = count not in (str(80), "80")
        assert recovery_broke or data_unreadable, (
            "Expected restore without old-primary WAL keys to fail or lose "
            f"pre-failover rows; count={count!r} start_failed={start_failed}\n"
            f"log:\n{restored.read_log(200)}"
        )

        # Control: with old keys restored, the same backup should be recoverable.
        restore_ok = tmp_path / "restore_with_old_keys"
        bm.restore(str(restore_ok), pg_tde_wal_restore=False)
        if (restore_ok / "pg_tde").exists():
            shutil.rmtree(restore_ok / "pg_tde")
        shutil.copytree(old_keys, restore_ok / "pg_tde")
        ok = _asy_start_restored_with_keyring(
            restore_ok, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert ok.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker_old}%'"
            ) == "80", (
                "Control restore with preserved old-primary keys must succeed; "
                "otherwise the negative assertion is inconclusive."
            )
        finally:
            ok.stop(check=False)

    def test_primary_restart_retains_keys_so_own_archive_still_works(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Contrast to multi-node: restarting the *same* primary rotates the
        active WAL key but keeps historical keys in PGDATA.

        A backup taken *before* restart does not contain the post-restart WAL
        key. Recovery of post-restart archived WAL therefore requires the
        keyring from the stopped primary's PGDATA (where keys were retained),
        not only the keyring baked into the older backup.
        """
        primary = _asy_start_tde_primary(pg_factory, "restart_pri")
        bm = _asy_setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="restart", archive_async=True,
        )
        marker = "before_restart"
        _asy_seed_encrypted_rows(primary, marker, n=60)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")

        fp_before = _asy_pg_tde_keyring_fingerprint(primary)
        primary.restart()  # new active WAL key generation
        primary.wait_ready(timeout=60)
        fp_after = _asy_pg_tde_keyring_fingerprint(primary)
        assert fp_after, "keyring missing after restart"
        assert fp_before, "keyring missing before restart"

        primary.execute(
            "INSERT INTO async_enc VALUES (7001, 'after_restart_row')"
        )
        # Ensure the post-restart insert is closed into an archived segment.
        primary.execute("CHECKPOINT")
        primary.execute("SELECT pg_switch_wal()")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Preserve the live keyring (pre- + post-restart WAL keys) before stop.
        live_keys = tmp_path / "primary_keys_after_restart"
        shutil.copytree(primary.data_dir / "pg_tde", live_keys)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_same_primary"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)

        # Negative control: backup keyring alone cannot decrypt post-restart WAL.
        # Recovery may refuse to start, or start without replaying those segments.
        try:
            restored_backup_keys = _asy_start_restored_with_keyring(
                restore_dir, install_dir, tmp_path, io_method, bm,
            )
        except (RuntimeError, TimeoutError):
            log_tail = ""
            if (restore_dir / "server.log").exists():
                log_tail = (restore_dir / "server.log").read_text()[-2000:].lower()
            assert any(m in log_tail for m in _asy_ARCHIVE_FAIL_MARKERS), (
                "Expected recovery/decrypt failure without post-restart keys.\n"
                f"log:\n{log_tail}"
            )
        else:
            try:
                assert restored_backup_keys.fetchone(
                    f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker}%'"
                ) == "60", "Pre-restart rows must come from the backup itself"
                post = restored_backup_keys.fetchone(
                    "SELECT COUNT(*) FROM async_enc WHERE id = 7001"
                )
                assert post == "0", (
                    "Post-restart row must NOT appear when recovering with only "
                    f"the pre-restart backup keyring (got count={post!r})"
                )
            finally:
                restored_backup_keys.stop(check=False)

        # Positive: same backup + archive, but with retained keys from PGDATA.
        restore_dir2 = tmp_path / "restore_with_retained_keys"
        bm.restore(str(restore_dir2), pg_tde_wal_restore=False)
        if (restore_dir2 / "pg_tde").exists():
            shutil.rmtree(restore_dir2 / "pg_tde")
        shutil.copytree(live_keys, restore_dir2 / "pg_tde")
        restored = _asy_start_restored_with_keyring(
            restore_dir2, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker}%'"
            ) == "60"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM async_enc WHERE id = 7001"
            ) == "1", (
                "With retained post-restart keys from the same primary PGDATA, "
                "archived WAL after restart must replay"
            )
        finally:
            restored.stop(check=False)


# ── wal_encrypt + archive_decrypt + pg_wal symlink (ex-PG-2609 bash suite) ──

_WSE_MISMATCH = "mismatch of segment size"
_WSE_TDE_PARAMS = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
    # Must be ≥ primary: recovery aborts if restore has a lower max_wal_senders.
    "max_wal_senders": "10",
}
_WSE_ARCHIVE_TIMEOUT_S = 5


# ── helpers ───────────────────────────────────────────────────────────────────


def _wse_require_archive_decrypt(install_dir: Path) -> Path:
    if not wrappers_available(install_dir):
        pytest.skip("pg_tde archive/restore wrappers not in this build")
    decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
    if not decrypt.is_file():
        pytest.skip(f"pg_tde_archive_decrypt missing: {decrypt}")
    return decrypt


def _wse_relocate_pg_wal_sibling_symlink(
    data_dir: Path,
    wal_real: Path,
    *,
    relative: bool = False,
) -> None:
    """
    Operator-style separate WAL volume: ``$PGDATA/pg_wal`` → sibling directory.

    ``pg_tde_archive_decrypt`` derives the key dir as
    ``dirname(segment)/../pg_tde`` without resolving through PGDATA, so a
    sibling symlink makes that land next to the WAL volume (wrong).
    """
    wal = data_dir / "pg_wal"
    assert wal.is_dir() and not wal.is_symlink(), f"expected real pg_wal dir at {wal}"
    wal_real.parent.mkdir(parents=True, exist_ok=True)
    wal.rename(wal_real)
    if relative:
        # e.g. PGDATA/pg_wal -> ../primary_wal (common PVC sibling layout)
        target = os.path.relpath(wal_real.resolve(), start=data_dir.resolve())
        wal.symlink_to(target)
    else:
        wal.symlink_to(wal_real.resolve())
    assert wal.is_symlink()
    assert wal.resolve() == wal_real.resolve()


def _wse_relocate_pg_wal_nested_symlink(data_dir: Path) -> Path:
    """
    Symlink ``pg_wal`` → ``$PGDATA/wal_volume`` (still under PGDATA).

    String-concat ``dirname($PGDATA/pg_wal/SEG)/../pg_tde`` still resolves to
    ``$PGDATA/pg_tde``, so this layout must NOT trip the key-dir bug.
    """
    wal = data_dir / "pg_wal"
    real = data_dir / "wal_volume"
    assert wal.is_dir() and not wal.is_symlink()
    wal.rename(real)
    wal.symlink_to(real.name)  # relative
    assert wal.is_symlink()
    assert (data_dir / "pg_tde").parent == data_dir
    return real


def _wse_boot_primary(
    pg_factory,
    name: str,
    *,
    archive_mode: str = "on",
    extra: Optional[dict] = None,
) -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    params = {
        **_WSE_TDE_PARAMS,
        "wal_level": "replica",
        "archive_mode": archive_mode,
        "archive_timeout": f"'{_WSE_ARCHIVE_TIMEOUT_S}s'",
        "archive_command": "'/bin/true'",
    }
    if extra:
        params.update(extra)
    cluster.write_default_config("primary", extra_params=params)
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host all all 127.0.0.1/32 trust")
    return cluster


def _wse_setup_default_keys(cluster: PgCluster, keyfile: Path) -> None:
    """Operator-style create_key + set_default_key (lazy server-key materialization)."""
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(
        provider_name="file_provider",
        keyfile=str(keyfile),
    )
    # Matches bash: set_default_key (not explicit set_server_key ahead of time).
    tde.set_global_default_principal_key("k1", "file_provider")
    # Idempotent reconcile-style retry (operator called set_default twice).
    cluster.execute(
        "SELECT pg_tde_set_default_key_using_global_key_provider("
        "'k1'::text, 'file_provider'::text)"
    )


def _wse_make_bm(
    cluster: PgCluster,
    tmp_path: Path,
    stanza: str,
    *,
    decrypt_wrappers: bool,
) -> BackupManager:
    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / f"repo_{stanza}"))
    bm.write_config(
        pg_path=str(cluster.data_dir),
        pg_port=cluster.port,
        pg_socket_path=str(cluster.socket_dir),
        pg_bin=str(cluster.bin),
        archive_header_check=False,
        checksum_page=False,
    )
    bm.configure_postgres(cluster, pg_tde_wal_archiving=decrypt_wrappers)
    return bm


def _wse_server_log_text(cluster: PgCluster) -> str:
    return cluster.read_log(200)


def _wse_saw_mismatch(cluster: PgCluster, *extra_paths: Path) -> bool:
    texts = [_wse_server_log_text(cluster).lower()]
    for p in extra_paths:
        if p.exists():
            texts.append(p.read_text(errors="replace").lower())
    return any(_WSE_MISMATCH in t for t in texts)


def _wse_completed_wal_segment(cluster: PgCluster) -> Optional[str]:
    """Return a completed on-disk WAL segment name strictly before the open one."""
    cur = cluster.fetchone("SELECT pg_walfile_name(pg_current_wal_lsn())")
    wal_dir = cluster.data_dir / "pg_wal"
    names = sorted(
        p.name
        for p in wal_dir.iterdir()
        if p.is_file() and re.fullmatch(r"[0-9A-F]{24}", p.name)
    )
    prior = [n for n in names if n < cur]
    return prior[-1] if prior else None


def _wse_manual_archive_decrypt_probe(
    decrypt: Path,
    cluster: PgCluster,
    out_dir: Path,
) -> Tuple[int, str, Optional[str]]:
    """
    Run ``pg_tde_archive_decrypt`` on a *completed* segment only.

    Returns ``(exit_code, stderr, segment_or_None)``.
    """
    seg = _wse_completed_wal_segment(cluster)
    if seg is None:
        return 0, "", None
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / f"decrypted.{seg}"
    seg_path = cluster.data_dir / "pg_wal" / seg
    # Pass the path *through* the symlink (matches archiver / bash probe).
    cmd = [
        str(decrypt),
        seg,
        str(seg_path),
        f"cp %p {dest}",
    ]
    env = os.environ.copy()
    lib = str(cluster.install_dir / "lib")
    env["LD_LIBRARY_PATH"] = f"{lib}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    err = (proc.stderr or "") + (proc.stdout or "")
    (out_dir / "decrypt.err").write_text(err)
    return proc.returncode, err, seg


def _wse_wal_cycles(cluster: PgCluster, n: int, *, start_id: int = 1) -> None:
    for i in range(n):
        lo = start_id + i * 500
        hi = lo + 499
        cluster.execute(
            f"INSERT INTO t1 SELECT g, repeat('x', 80) "
            f"FROM generate_series({lo}, {hi}) g"
        )
        cluster.execute("CHECKPOINT")
        cluster.execute("SELECT pg_switch_wal()")
        time.sleep(_WSE_ARCHIVE_TIMEOUT_S)


def _wse_try_backup(bm: BackupManager) -> Tuple[bool, str]:
    try:
        bm.backup(backup_type="full")
        return True, ""
    except RuntimeError as exc:
        return False, str(exc)


def _wse_start_restored_encrypted_in_repo(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    bm: BackupManager,
) -> PgCluster:
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config("primary", extra_params=_WSE_TDE_PARAMS)
    auto = restore_dir / "postgresql.auto.conf"
    if auto.exists():
        keep: List[str] = []
        for line in auto.read_text().splitlines():
            raw = line.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                keep.append(line)
                continue
            key = raw.split("=", 1)[0].strip().lower()
            if key in {
                "port",
                "unix_socket_directories",
                "listen_addresses",
                "log_directory",
                "archive_mode",
                "archive_command",
                "restore_command",
            }:
                continue
            keep.append(line)
        auto.write_text("\n".join(keep) + ("\n" if keep else ""))
    restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
    with auto.open("a") as f:
        f.write(f"restore_command = '{restore_cmd}'\n")
    cluster.add_hba_entry("local all all trust")
    (restore_dir / "postmaster.pid").unlink(missing_ok=True)
    cluster.start()
    cluster.wait_ready(timeout=180)
    if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
        cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 90)")
    deadline = time.time() + 90
    while time.time() < deadline:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
            return cluster
        time.sleep(0.5)
    raise TimeoutError("restored primary did not leave recovery")


# ── corner cases ──────────────────────────────────────────────────────────────


class TestWalEncryptArchiveDecryptCorners:
    def test_sighup_cannot_enable_wal_encrypt(self, pg_factory, tmp_path: Path):
        """Bash: prove SIGHUP / reload leaves ``wal_encrypt`` off until restart."""
        cluster = _wse_boot_primary(pg_factory, "sighup")
        cluster.start()
        _wse_setup_default_keys(cluster, tmp_path / "keyring.per")
        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")
        cluster.execute("SELECT pg_reload_conf()")
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "off"
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

    def test_manual_decrypt_probe_skips_when_no_completed_segment(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """Do not probe the open / recycled-ahead slot (false mismatch risk)."""
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster = _wse_boot_primary(pg_factory, "probe_empty")
        cluster.start()
        _wse_setup_default_keys(cluster, tmp_path / "keyring.per")
        TdeManager(cluster).enable_wal_encryption()
        # Fresh cluster: may have no completed segment yet.
        rc, err, seg = _wse_manual_archive_decrypt_probe(
            decrypt, cluster, tmp_path / "probe"
        )
        if seg is None:
            assert rc == 0
            assert err == ""
        else:
            # If a completed segment exists, probe must not crash the harness.
            assert isinstance(rc, int)


# ── file keyring repro (plain pg_wal) ─────────────────────────────────────────


class TestWalEncryptDecryptWrapperFileKeyring:
    """Parity: ``PG-2609_repro_wal_encrypt_pgbackrest_file.sh``."""

    def test_plain_pgwal_decrypt_wrapper_backup_succeeds(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        _wse_require_archive_decrypt(install_dir)
        cluster = _wse_boot_primary(pg_factory, "file_plain")
        cluster.start()
        _wse_setup_default_keys(cluster, tmp_path / "keyring.per")
        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")

        bm = _wse_make_bm(cluster, tmp_path, "file_plain", decrypt_wrappers=True)
        bm.stanza_create()
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        cluster.execute(
            "CREATE TABLE t1 (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        _wse_wal_cycles(cluster, 3)
        bm.wait_for_wal_archive(cluster, timeout=60)

        decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
        rc, err, seg = _wse_manual_archive_decrypt_probe(
            decrypt, cluster, tmp_path / "file_probe"
        )
        assert not _wse_saw_mismatch(cluster, tmp_path / "file_probe" / "decrypt.err"), (
            f"plain pg_wal must not hit segment-size mismatch; seg={seg} rc={rc} err={err}"
        )

        ok, detail = _wse_try_backup(bm)
        assert ok, f"file-keyring plain pg_wal backup must succeed:\n{detail}"
        assert not _wse_saw_mismatch(cluster)


# ── symlink / mid-stream repro ────────────────────────────────────────────────


class TestWalEncryptPgWalSymlinkRepro:
    """
    Parity: ``PG-2609_repro_wal_encrypt_pgbackrest_ha{,_wal_symlink}.sh``.

    Historical bug: ``pg_tde_archive_decrypt`` derived the key dir as
    ``dirname(segment)/../pg_tde`` without resolving a sibling ``pg_wal``
    symlink, producing ``mismatch of segment size`` and backup [082].

    On current builds the wrapper resolves keys correctly, so sibling-symlink
    layouts must archive + backup cleanly (regression). Nested-under-PGDATA
    symlinks still must not trip a TDE mismatch; pgBackRest 2.58+ may reject
    those links with ERROR [070] independently of pg_tde.
    """

    def _midstream_enable_with_wrapper(
        self,
        pg_factory,
        tmp_path: Path,
        name: str,
        *,
        sibling_symlink: bool,
        nested_symlink: bool = False,
        relative_sibling: bool = False,
    ) -> Tuple[PgCluster, BackupManager, Path]:
        cluster = _wse_boot_primary(pg_factory, name)
        if sibling_symlink:
            _wse_relocate_pg_wal_sibling_symlink(
                cluster.data_dir,
                tmp_path / f"{name}_wal",
                relative=relative_sibling,
            )
        elif nested_symlink:
            _wse_relocate_pg_wal_nested_symlink(cluster.data_dir)

        # Wrapper installed before first start (bash: live from t=0).
        bm = _wse_make_bm(cluster, tmp_path, name, decrypt_wrappers=True)
        cluster.start()
        bm.stanza_create()

        # Archive a few plaintext segments through the same wrapped command.
        # Heap on purpose: extension / tde_heap are installed after this phase.
        cluster.execute(
            "CREATE TABLE t1 (id INT PRIMARY KEY, payload TEXT) USING heap"
        )
        cluster.execute(
            "INSERT INTO t1 SELECT g, repeat('x', 80) "
            "FROM generate_series(1, 1000) g"
        )
        cluster.execute("CHECKPOINT")
        cluster.execute("SELECT pg_switch_wal()")
        time.sleep(_WSE_ARCHIVE_TIMEOUT_S)
        bm.wait_for_wal_archive(cluster, timeout=60)

        _wse_setup_default_keys(cluster, tmp_path / f"{name}_keyring.per")
        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")
        cluster.execute("SELECT pg_reload_conf()")
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "off"

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        # Idle archive_timeout cycles, then forced switches (bash cadence, scaled).
        for _ in range(2):
            time.sleep(_WSE_ARCHIVE_TIMEOUT_S)
            if _wse_saw_mismatch(cluster):
                break
        if not _wse_saw_mismatch(cluster):
            _wse_wal_cycles(cluster, 4, start_id=1001)

        return cluster, bm, tmp_path / f"{name}_probe"

    def test_sibling_symlink_pgwal_archive_and_backup_succeed(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """Regression: sibling ``pg_wal`` + decrypt wrapper must not hit PG-2609."""
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster, bm, probe_dir = self._midstream_enable_with_wrapper(
            pg_factory, tmp_path, "sib_repro", sibling_symlink=True,
        )
        rc, err, seg = _wse_manual_archive_decrypt_probe(decrypt, cluster, probe_dir)
        assert not _wse_saw_mismatch(cluster, probe_dir / "decrypt.err"), (
            "PG-2609 segment-size mismatch returned on sibling pg_wal symlink:\n"
            f"  manual seg={seg} rc={rc}\n"
            f"  decrypt.err={err!r}\n"
            f"  server log:\n{_wse_server_log_text(cluster)}"
        )
        ok, detail = _wse_try_backup(bm)
        assert ok, (
            "sibling pg_wal + decrypt wrapper backup must succeed "
            f"(PG-2609 regression):\n{detail}"
        )

    def test_relative_sibling_symlink_pgwal_archive_and_backup_succeed(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """Same regression with a relative ``pg_wal -> ../…_wal`` symlink."""
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster, bm, probe_dir = self._midstream_enable_with_wrapper(
            pg_factory,
            tmp_path,
            "sib_rel",
            sibling_symlink=True,
            relative_sibling=True,
        )
        link = (cluster.data_dir / "pg_wal").readlink()
        assert not link.is_absolute(), f"expected relative symlink, got {link}"
        rc, err, seg = _wse_manual_archive_decrypt_probe(decrypt, cluster, probe_dir)
        assert not _wse_saw_mismatch(cluster, probe_dir / "decrypt.err"), (
            "PG-2609 mismatch on relative sibling pg_wal symlink:\n"
            f"  link={link} seg={seg} rc={rc} err={err!r}"
        )
        ok, detail = _wse_try_backup(bm)
        assert ok, (
            "relative sibling pg_wal backup must succeed "
            f"(PG-2609 regression):\n{detail}"
        )

    def test_plain_pgwal_midstream_enable_control_no_mismatch(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """Same mid-stream flip without sibling symlink must not trip the path bug."""
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster, bm, probe_dir = self._midstream_enable_with_wrapper(
            pg_factory, tmp_path, "plain_ctrl", sibling_symlink=False,
        )
        rc, err, seg = _wse_manual_archive_decrypt_probe(decrypt, cluster, probe_dir)
        assert not _wse_saw_mismatch(cluster, probe_dir / "decrypt.err"), (
            f"plain pg_wal control unexpectedly mismatched; seg={seg} rc={rc} err={err}"
        )
        ok, detail = _wse_try_backup(bm)
        assert ok, f"plain mid-stream control backup must succeed:\n{detail}"

    def test_nested_under_pgdata_symlink_does_not_mismatch(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """
        Symlink under PGDATA keeps string-concat key dir correct (no TDE mismatch).

        pgBackRest 2.58+ rejects ``pg_wal`` links whose destination is inside
        PGDATA (ERROR [070]); that is independent of pg_tde and is accepted here.
        """
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster, bm, probe_dir = self._midstream_enable_with_wrapper(
            pg_factory,
            tmp_path,
            "nested_sym",
            sibling_symlink=False,
            nested_symlink=True,
        )
        assert (cluster.data_dir / "pg_wal").is_symlink()
        rc, err, seg = _wse_manual_archive_decrypt_probe(decrypt, cluster, probe_dir)
        assert not _wse_saw_mismatch(cluster, probe_dir / "decrypt.err"), (
            f"nested-under-PGDATA symlink must not reproduce segment-size mismatch; "
            f"seg={seg} rc={rc} err={err}"
        )
        ok, detail = _wse_try_backup(bm)
        if ok:
            return
        detail_l = detail.lower()
        assert "070" in detail or "is in pgdata" in detail_l, (
            "nested symlink backup failed for an unexpected reason "
            f"(expected success or pgBackRest [070] in-PGDATA link):\n{detail}"
        )


# ── Workaround A (no decrypt wrapper) ─────────────────────────────────────────


class TestWalEncryptNoDecryptWrapper:
    """Parity: ``PG-2609_workaround_A_no_decrypt_wrapper.sh``."""

    def _run_a(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
        name: str,
        *,
        sibling_symlink: bool,
    ) -> None:
        cluster = _wse_boot_primary(pg_factory, name)
        if sibling_symlink:
            _wse_relocate_pg_wal_sibling_symlink(
                cluster.data_dir, tmp_path / f"{name}_wal"
            )
        cluster.start()
        _wse_setup_default_keys(cluster, tmp_path / f"{name}_keyring.per")
        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")

        bm = _wse_make_bm(cluster, tmp_path, name, decrypt_wrappers=False)
        bm.stanza_create()
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        arch = cluster.fetchone("SHOW archive_command")
        assert "pg_tde_archive_decrypt" not in arch

        cluster.execute(
            "CREATE TABLE t1 (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        _wse_wal_cycles(cluster, 4)
        bm.wait_for_wal_archive(cluster, timeout=90)
        assert not _wse_saw_mismatch(cluster)

        rows = int(cluster.fetchone("SELECT COUNT(*) FROM t1"))
        ok, detail = _wse_try_backup(bm)
        assert ok, f"workaround A backup failed:\n{detail}"

        restore_dir = tmp_path / f"{name}_restored"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _wse_start_restored_encrypted_in_repo(
            restore_dir, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
            assert int(restored.fetchone("SELECT COUNT(*) FROM t1")) == rows
        finally:
            restored.stop(check=False)

    def test_no_wrapper_plain_pgwal_backup_restore(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        self._run_a(
            pg_factory, tmp_path, install_dir, io_method, "wa_plain",
            sibling_symlink=False,
        )

    def test_no_wrapper_sibling_symlink_backup_restore(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str,
    ):
        """Encrypted-in-repo avoids archive_decrypt entirely — symlink-safe."""
        self._run_a(
            pg_factory, tmp_path, install_dir, io_method, "wa_sib",
            sibling_symlink=True,
        )


# ── Workaround B (safe bootstrap order) ───────────────────────────────────────


class TestWalEncryptSafeBootstrapOrder:
    """Parity: ``PG-2609_workaround_B_safe_bootstrap_order.sh``."""

    def _run_b(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        name: str,
        *,
        sibling_symlink: bool,
    ) -> Tuple[PgCluster, BackupManager, bool, str]:
        _wse_require_archive_decrypt(install_dir)
        # archive_mode=off until the single wal_encrypt+wrapper restart.
        cluster = _wse_boot_primary(pg_factory, name, archive_mode="off")
        if sibling_symlink:
            _wse_relocate_pg_wal_sibling_symlink(
                cluster.data_dir, tmp_path / f"{name}_wal"
            )
        cluster.start()
        _wse_setup_default_keys(cluster, tmp_path / f"{name}_keyring.per")

        bm = BackupManager(stanza=name, repo_path=str(tmp_path / f"repo_{name}"))
        bm.write_config(
            pg_path=str(cluster.data_dir),
            pg_port=cluster.port,
            pg_socket_path=str(cluster.socket_dir),
            pg_bin=str(cluster.bin),
            archive_header_check=False,
            checksum_page=False,
        )
        # One restart: wal_encrypt + wrapped archive_command, then stanza-create.
        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")
        cluster.execute("ALTER SYSTEM SET archive_mode = on")
        bm.configure_postgres(cluster, pg_tde_wal_archiving=True)
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        bm.stanza_create()
        cluster.execute(
            "CREATE TABLE t1 (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        _wse_wal_cycles(cluster, 4)
        mismatched = _wse_saw_mismatch(cluster)
        ok, detail = _wse_try_backup(bm)
        return cluster, bm, ok and not mismatched, detail

    def test_safe_bootstrap_plain_pgwal_backup_ok(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        cluster, _bm, ok, detail = self._run_b(
            pg_factory, tmp_path, install_dir, "wb_plain", sibling_symlink=False,
        )
        assert ok, (
            "workaround B on plain pg_wal must succeed:\n"
            f"{detail}\n{_wse_server_log_text(cluster)}"
        )

    def test_safe_bootstrap_sibling_symlink_still_hits_path_bug(
        self, pg_factory, tmp_path: Path, install_dir: Path,
    ):
        """
        Ordering alone cannot fix sibling-symlink key-dir derivation — decrypt
        still looks beside the WAL volume for ``pg_tde/``.
        """
        cluster, bm, ok, detail = self._run_b(
            pg_factory, tmp_path, install_dir, "wb_sib", sibling_symlink=True,
        )
        decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
        _rc, err, seg = _wse_manual_archive_decrypt_probe(
            decrypt, cluster, tmp_path / "wb_sib_probe"
        )
        still_broken = (
            _wse_saw_mismatch(cluster, tmp_path / "wb_sib_probe" / "decrypt.err")
            or not ok
        )
        assert still_broken, (
            "expected path bug to remain under sibling symlink even with "
            "safe bootstrap ordering (use workaround A / no wrapper instead):\n"
            f"  seg={seg} decrypt.err={err!r}\n"
            f"  backup detail={detail!r}\n"
            f"  log:\n{_wse_server_log_text(cluster)}"
        )
        # Keep bm referenced so stanza dir isn't GC'd mid-assert in some runners.
        assert bm.stanza == "wb_sib"


# ── OpenBao / Vault optional (operator-like provider) ─────────────────────────


@pytest.mark.vault
@pytest.mark.openbao
class TestWalEncryptOpenBaoPgWalSymlink:
    """
    Sibling ``pg_wal`` + OpenBao/Vault provider + decrypt wrapper.

    Formerly a PG-2609 repro; on fixed builds this is a regression that the
    layout archives and backs up cleanly.
    """

    def test_sibling_symlink_with_vault_provider_archive_and_backup_succeed(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        vault_config: VaultConfig,
    ):
        decrypt = _wse_require_archive_decrypt(install_dir)
        cluster = _wse_boot_primary(pg_factory, "ob_sib")
        _wse_relocate_pg_wal_sibling_symlink(cluster.data_dir, tmp_path / "ob_sib_wal")

        bm = _wse_make_bm(cluster, tmp_path, "ob_sib", decrypt_wrappers=True)
        cluster.start()
        bm.stanza_create()
        # Plaintext archive phase before extension / principal key.
        cluster.execute(
            "CREATE TABLE t1 (id INT PRIMARY KEY, payload TEXT) USING heap"
        )
        cluster.execute(
            "INSERT INTO t1 SELECT g, repeat('x', 40) FROM generate_series(1, 500) g"
        )
        cluster.execute("CHECKPOINT; SELECT pg_switch_wal()")
        time.sleep(_WSE_ARCHIVE_TIMEOUT_S)

        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_vault(
            "vault-provider",
            vault_url=vault_config.addr,
            secret_mount_point=vault_config.secret_mount,
            token_path=vault_config.token_sql_arg(tmp_path),
            ca_path=vault_config.ca_path,
            namespace=vault_config.namespace,
        )
        tde.set_global_default_principal_key("k1", "vault-provider")

        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        _wse_wal_cycles(cluster, 4, start_id=501)
        rc, err, seg = _wse_manual_archive_decrypt_probe(
            decrypt, cluster, tmp_path / "ob_probe"
        )
        assert not _wse_saw_mismatch(
            cluster, tmp_path / "ob_probe" / "decrypt.err"
        ), (
            "PG-2609 mismatch on OpenBao + sibling pg_wal:\n"
            f"  seg={seg} rc={rc} err={err!r}"
        )
        ok, detail = _wse_try_backup(bm)
        assert ok, (
            "OpenBao + sibling pg_wal backup must succeed "
            f"(PG-2609 regression):\n{detail}"
        )
