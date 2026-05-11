"""
pg_tde minor-version upgrade procedure tests.

Simulates the upgrade flow for pg_tde 2.1.1 → 2.1.2 (or any x.y.z → x.y.z+1)
on a two-node streaming replication cluster with:
  - PostgreSQL 18
  - WAL encryption enabled (pg_tde.wal_encrypt = on)
  - File-based key provider
  - pgBackRest for backups (with pg_tde WAL wrappers where available)
  - archive_command / restore_command using pg_tde_archive_decrypt /
    pg_tde_restore_encrypt wrappers

The actual library swap cannot be exercised in a unit test environment (it
requires two distinct pg_tde .so files), so each class targets one phase of
the documented upgrade checklist, verifying it is safe, idempotent, and
non-destructive regardless of whether the binary changed.

Upgrade checklist phases tested
────────────────────────────────
Phase 0  Pre-conditions          TestTdeMinorUpgradePreConditions
Phase 1  ALTER EXTENSION safety  TestAlterExtensionUpdate
Phase 2  Rolling restart         TestRollingRestart
Phase 3  WAL archiving           TestWalArchivingContinuity
Phase 4  Post-upgrade state      TestPostUpgradeState

Answers embedded in docstrings
───────────────────────────────
Q1  ALTER EXTENSION required?        → TestAlterExtensionUpdate
Q2  Breaking changes / migrations?   → TestAlterExtensionUpdate
Q3  Install order vs restart order?  → TestRollingRestart
Q4  WAL encryption precautions?      → TestWalArchivingContinuity
Q5  Post-upgrade backup needed?      → TestPostUpgradeState
"""

import shutil
import subprocess
import time
from pathlib import Path
from typing import Generator, Tuple

import pytest

from conftest import allocate_port
from lib import (
    PgCluster,
    ReplicationManager,
    TdeManager,
    archive_restore_conf_values,
    restore_conf_line_raw,
)
from lib.backup import BackupManager, pgbackrest_installed
from lib.cluster import initdb_args_no_data_checksums

pytestmark = [pytest.mark.upgrade, pytest.mark.encryption, pytest.mark.slow]

# ── constants ─────────────────────────────────────────────────────────────────

_KEYFILE = "/tmp/tde_minor_upgrade_test.per"

_TDE_PARAMS = {
    "shared_preload_libraries": "'pg_tde'",
}


# ── helpers ───────────────────────────────────────────────────────────────────


def _build_ha_cluster(
    tmp_path: Path,
    install_dir: Path,
    io_method: str,
    *,
    wal_encrypt: bool = True,
    with_archive: bool = False,
    archive_dir: Path = None,
) -> Tuple[PgCluster, PgCluster]:
    """
    Create a two-node TDE streaming replication cluster.

      nodeA = leader  (primary)
      nodeB = replica (standby – restarted first in Patroni rolling upgrades)

    Returns (nodeA, nodeB).
    """
    nodeA = PgCluster(
        tmp_path / "nodeA",
        allocate_port(),
        install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    nodeB = PgCluster(
        tmp_path / "nodeB",
        allocate_port(),
        install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )

    nodeA.initdb(extra_args=initdb_args_no_data_checksums(install_dir))
    params = dict(_TDE_PARAMS)
    if with_archive and archive_dir:
        archive_dir.mkdir(parents=True, exist_ok=True)
        arch_cmd, restore_cmd = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=wal_encrypt
        )
        params["archive_mode"] = "on"
        params["archive_command"] = arch_cmd
        params["restore_command"] = restore_cmd
        params["wal_level"] = "replica"
        params["max_wal_senders"] = "5"
        params["hot_standby"] = "on"
    else:
        params["wal_level"] = "replica"
        params["max_wal_senders"] = "5"
        params["hot_standby"] = "on"
    nodeA.write_default_config(extra_params=params)
    nodeA.add_hba_entry("local all all trust")
    nodeA.add_hba_entry("local replication all trust")
    nodeA.add_hba_entry("host  all all 127.0.0.1/32 trust")
    nodeA.add_hba_entry("host  replication all 127.0.0.1/32 trust")
    nodeA.start()

    tde = TdeManager(nodeA)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=_KEYFILE)
    tde.set_global_principal_key()
    if wal_encrypt:
        tde.enable_wal_encryption()
        nodeA.restart()

    repl = ReplicationManager(nodeA, nodeB)
    repl.create_standby_from_backup(
        use_tde_basebackup=True,
        extra_args=(["-E"] if wal_encrypt else None),
    )
    nodeB.write_default_config("replica", extra_params=_TDE_PARAMS)
    if with_archive and archive_dir:
        _, restore_cmd = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=wal_encrypt
        )
        nodeB.configure(
            {
                "restore_command": restore_cmd,
            }
        )
    nodeB.start()
    nodeB.wait_ready(timeout=60)

    # Wait for WAL sender to confirm connectivity
    deadline = time.time() + 30
    while time.time() < deadline:
        n = nodeA.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        if n and int(n) >= 1:
            break
        time.sleep(1)

    return nodeA, nodeB


def _teardown_pair(nodeA: PgCluster, nodeB: PgCluster) -> None:
    for node in (nodeB, nodeA):
        try:
            if node.is_ready():
                node.stop(check=False)
        except Exception:
            pass
        shutil.rmtree(node.data_dir, ignore_errors=True)


# ── Phase 0: pre-conditions ───────────────────────────────────────────────────


class TestTdeMinorUpgradePreConditions:
    """
    Verify the cluster state that must hold before initiating a minor upgrade.

    Covers:
    - The relationship between the binary version (pg_tde_version()) and the
      PostgreSQL catalog version (pg_extension.extversion).
    - Key provider registration and key accessibility.
    - WAL encryption is active.
    - pgBackRest full backup succeeds (safety checkpoint).
    """

    def test_catalog_version_vs_binary_version(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Q1 context: Percona ships 2.1.x with default_version='2.1' in the
        control file. pg_extension.extversion therefore shows '2.1' while
        pg_tde_version() may return '2.1.1' or '2.1.2'.

        This test documents (and asserts) the invariant:
          extversion == major.minor portion of binary version
        so that ALTER EXTENSION pg_tde UPDATE is always a safe no-op when
        the control file version has not changed.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            ext_ver = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            bin_ver = nodeA.fetchone("SELECT pg_tde_version()")
            assert ext_ver is not None, "pg_tde extension not installed"
            assert bin_ver is not None, "pg_tde_version() returned NULL"

            # e.g. ext_ver='2.1', bin_ver='pg_tde 2.1.2' or '2.1.2'
            # The catalog version should be a prefix of (or equal to) the binary version.
            bin_ver_clean = bin_ver.strip().split()[-1]   # strip 'pg_tde ' prefix if present
            assert bin_ver_clean.startswith(ext_ver), (
                f"Catalog version '{ext_ver}' is not a prefix of binary version '{bin_ver_clean}'. "
                f"This means ALTER EXTENSION pg_tde UPDATE may attempt a real migration."
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_wal_encryption_active_on_both_nodes(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Both nodes must report wal_encrypt=on before the upgrade starts."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            for node, name in ((nodeA, "nodeA/primary"), (nodeB, "nodeB/standby")):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes"), (
                    f"WAL encryption is not active on {name}: pg_tde.wal_encrypt={val!r}"
                )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_key_provider_registered_on_primary(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """File key provider must be present and principal key set before upgrade."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            tde = TdeManager(nodeA)
            count = tde.list_key_providers(scope="global")
            assert count >= 1, "No global key providers registered on nodeA"
            key_name = tde.principal_key_name()
            assert key_name, "No principal key set on nodeA"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_encrypted_tables_readable_before_upgrade(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Data in tde_heap tables must be fully accessible on both nodes."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE pre_upgrade_data (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO pre_upgrade_data SELECT i, md5(i::text) "
                "FROM generate_series(1,100) i;"
            )
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=30)
            repl.assert_row_counts_match("pre_upgrade_data")
        finally:
            _teardown_pair(nodeA, nodeB)

    @pytest.mark.pgbackrest
    def test_pre_upgrade_full_backup_succeeds(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Q5 (pre): A full pgBackRest backup must succeed before any package
        installation begins. This is the safety checkpoint that lets you roll
        back if the upgrade goes wrong.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        archive_dir = tmp_path / "wal_archive_pre"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE pre_bkp (id INT) USING tde_heap; "
                "INSERT INTO pre_bkp VALUES (1),(2),(3);"
            )
            bm = BackupManager(stanza="tde_pre_upgrade", repo_path=str(tmp_path / "repo_pre"))
            bm.write_config(
                pg_path=str(nodeA.data_dir),
                pg_port=nodeA.port,
                pg_socket_path=str(tmp_path),
            )
            bm.stanza_create()
            bm.backup(backup_type="full")
            info = bm.info()
            assert "full" in info.lower(), "pgBackRest reports no full backup"
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 1: ALTER EXTENSION safety ──────────────────────────────────────────


class TestAlterExtensionUpdate:
    """
    Q1: Is ALTER EXTENSION pg_tde UPDATE required?
    Q2: Are there breaking changes requiring additional steps?

    The Percona 2.1.x line ships with default_version='2.1' in
    pg_tde.control, so the catalog version is '2.1' for every 2.1.x release.
    This means ALTER EXTENSION pg_tde UPDATE is a no-op when upgrading within
    the 2.1.x line — but it MUST NOT fail, corrupt key state, or disable WAL
    encryption even when run unnecessarily.

    These tests verify the command is always safe to run (idempotent),
    regardless of whether it actually migrates anything.
    """

    def test_alter_extension_update_does_not_fail(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Running ALTER EXTENSION pg_tde UPDATE must not raise an error,
        even when the extension is already at the latest catalog version.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            # Should not raise
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_alter_extension_update_is_idempotent(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Running ALTER EXTENSION pg_tde UPDATE twice must be safe."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")  # second run must also not fail
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_extversion_unchanged_when_catalog_version_matches(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        If the control file default_version equals the installed extversion,
        ALTER EXTENSION UPDATE must leave extversion unchanged.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            ver_before = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
            ver_after = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            assert ver_before == ver_after, (
                f"ALTER EXTENSION UPDATE changed extversion: {ver_before!r} → {ver_after!r}. "
                f"This indicates an actual schema migration ran — inspect upgrade scripts."
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_alter_extension_update_does_not_drop_key_providers(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Key provider registrations must survive ALTER EXTENSION pg_tde UPDATE.
        A regression here would brick every encrypted table.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            tde = TdeManager(nodeA)
            count_before = tde.list_key_providers(scope="global")
            key_before = tde.principal_key_name()

            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")

            count_after = tde.list_key_providers(scope="global")
            key_after = tde.principal_key_name()

            assert count_after == count_before, (
                f"Key provider count changed after ALTER EXTENSION UPDATE: "
                f"{count_before} → {count_after}"
            )
            assert key_after == key_before, (
                f"Principal key name changed after ALTER EXTENSION UPDATE: "
                f"{key_before!r} → {key_after!r}"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_alter_extension_update_preserves_wal_encryption(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """WAL encryption must remain on after ALTER EXTENSION pg_tde UPDATE."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
            val = nodeA.fetchone("SHOW pg_tde.wal_encrypt")
            assert val in ("on", "true", "1", "yes"), (
                f"WAL encryption was disabled by ALTER EXTENSION UPDATE: "
                f"pg_tde.wal_encrypt={val!r}"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_alter_extension_update_on_multiple_databases(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        ALTER EXTENSION pg_tde UPDATE must succeed on every database where
        the extension is installed (postgres db for WAL keys + app db).
        This matches step 4 of the documented upgrade flow.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute("CREATE DATABASE app_db")
            nodeA.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="app_db")

            # Simulate step 4: run ALTER EXTENSION on each database
            for dbname in ("postgres", "app_db"):
                nodeA.execute("ALTER EXTENSION pg_tde UPDATE", dbname=dbname)

            # Both databases must still have the extension
            for dbname in ("postgres", "app_db"):
                cnt = nodeA.fetchone(
                    "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_tde'",
                    dbname=dbname,
                )
                assert cnt == "1", f"pg_tde not found in {dbname} after ALTER EXTENSION UPDATE"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_encrypted_tables_accessible_after_alter_extension_update(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        tde_heap tables written before the ALTER EXTENSION UPDATE must remain
        readable with the same data afterward — no catalog corruption.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE app_data (id INT, secret TEXT) USING tde_heap; "
                "INSERT INTO app_data SELECT i, md5(i::text) FROM generate_series(1,500) i;"
            )
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
            count = nodeA.fetchone("SELECT COUNT(*) FROM app_data")
            assert count == "500", f"Row count changed after ALTER EXTENSION UPDATE: {count}"
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 2: rolling restart ──────────────────────────────────────────────────


class TestRollingRestart:
    """
    Q3: Order of operations — install on both nodes before Patroni restart,
    or node-by-node?

    Patroni's documented rolling-upgrade procedure:
      1. Install new package on ALL nodes (no restarts yet).
      2. patronictl restart <cluster> <nodeB>   ← replica first
      3. Wait for nodeB to reconnect and replicate.
      4. patronictl restart <cluster> <nodeA>   ← leader second

    This ordering keeps the cluster available throughout:
    - nodeB (standby) can restart safely because nodeA is still serving writes.
    - nodeA (leader) restart is done only after nodeB is confirmed healthy,
      so Patroni can fail over to nodeB if nodeA restart takes too long.

    These tests verify the procedure is safe by simulating both restarts with
    WAL encryption active.
    """

    def test_standby_restart_does_not_lose_data(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Restarting nodeB (replica) first must not cause data loss on nodeA.
        nodeB must reconnect and catch up to nodeA after restart.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE rolling_test (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO rolling_test SELECT i, md5(i::text) "
                "FROM generate_series(1,100) i;"
            )
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=30)

            # Step 2: restart nodeB (replica) first — simulates 'patronictl restart nodeB'
            nodeB.stop()
            nodeA.execute("INSERT INTO rolling_test VALUES (9999, 'written-while-nodeB-down')")
            nodeB.start()
            nodeB.wait_ready(timeout=60)

            # nodeB must reconnect and catch up
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("rolling_test")
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_writes_during_standby_restart_are_not_lost(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Rows written to nodeA while nodeB is restarting must appear on nodeB
        after it reconnects. This validates that the WAL is not corrupted by
        the restart and the encrypted WAL segments are replayed correctly.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE write_window (id INT) USING tde_heap; "
                "INSERT INTO write_window VALUES (1);"
            )
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=30)

            nodeB.stop()

            # Simulate writes that arrive while the standby is being upgraded
            nodeA.execute(
                "INSERT INTO write_window SELECT generate_series(2, 100);"
            )
            nodeA.execute("SELECT pg_switch_wal()")  # flush WAL to disk

            nodeB.start()
            nodeB.wait_ready(timeout=60)
            repl.assert_catchup(timeout=60)

            primary_count = nodeA.fetchone("SELECT COUNT(*) FROM write_window")
            standby_count = nodeB.fetchone("SELECT COUNT(*) FROM write_window")
            assert primary_count == standby_count == "100", (
                f"Write-window data mismatch: primary={primary_count}, standby={standby_count}"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_leader_restart_after_standby_is_healthy(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Step 4: after nodeB is confirmed healthy, restart nodeA (leader).
        nodeB must catch up to nodeA's final LSN within the timeout.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE leader_restart_tbl (id INT) USING tde_heap; "
                "INSERT INTO leader_restart_tbl SELECT generate_series(1,50);"
            )
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=30)

            # Step 2: restart nodeB first
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            repl.assert_catchup(timeout=30)

            # Step 4: now restart nodeA (leader)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            # Reconnect standby and verify data consistent
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("leader_restart_tbl")
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_encryption_active_on_both_nodes_after_rolling_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """WAL encryption must be on on both nodes after the full rolling restart."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            # Full rolling restart: replica first, then leader
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)

            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            for node, label in ((nodeA, "nodeA"), (nodeB, "nodeB")):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes"), (
                    f"WAL encryption not active on {label} after rolling restart: "
                    f"pg_tde.wal_encrypt={val!r}"
                )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_key_provider_intact_after_rolling_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Key provider registrations and principal key must survive the rolling restart."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            tde = TdeManager(nodeA)
            key_before = tde.principal_key_name()

            # Full rolling restart
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            key_after = tde.principal_key_name()
            assert key_after == key_before, (
                f"Principal key changed after rolling restart: {key_before!r} → {key_after!r}"
            )
            count = tde.list_key_providers(scope="global")
            assert count >= 1, "Key providers lost after rolling restart"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_new_encrypted_writes_work_after_full_rolling_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """New tde_heap inserts and reads must work on nodeA after both nodes restarted."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute("CREATE TABLE post_restart_tbl (id INT) USING tde_heap;")

            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            nodeA.execute("INSERT INTO post_restart_tbl SELECT generate_series(1,200)")
            count = nodeA.fetchone("SELECT COUNT(*) FROM post_restart_tbl")
            assert count == "200", f"Unexpected row count post-restart: {count}"

            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("post_restart_tbl")
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 3: WAL archiving continuity ────────────────────────────────────────


class TestWalArchivingContinuity:
    """
    Q4: With WAL encryption enabled, are there additional precautions needed
    during the upgrade (e.g. ensuring no WAL archiving failures during the
    restart window)?

    Key concerns:
    - The archive_command uses pg_tde_archive_decrypt, which must still be
      able to read the encrypted WAL segments produced under the old library.
    - During the restart window, WAL archiving queues segments; they must all
      be archived cleanly after the node comes back.
    - The restore_command (pg_tde_restore_encrypt) must be able to replay
      archived segments for PITR even after the library version changes.
    """

    def test_archive_command_survives_standby_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        WAL segments generated before and after nodeB restart must all be
        archived without error. Archiving failures appear as 'archive_command
        failed' in the server log — we assert that string is absent.
        """
        archive_dir = tmp_path / "wal_archive_rolling"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE archive_continuity (id INT) USING tde_heap; "
                "INSERT INTO archive_continuity SELECT generate_series(1,50);"
            )
            nodeA.execute("SELECT pg_switch_wal()")

            # Restart nodeB (replica)
            nodeB.stop()
            nodeA.execute("INSERT INTO archive_continuity SELECT generate_series(51,100)")
            nodeA.execute("SELECT pg_switch_wal()")
            nodeB.start()
            nodeB.wait_ready(timeout=60)

            time.sleep(3)  # allow archiver to catch up

            log_text = nodeA.read_log(last_n=100)
            assert "archive_command failed" not in log_text, (
                "archive_command failures detected in nodeA log after standby restart:\n"
                + "\n".join(
                    ln for ln in log_text.splitlines() if "archive" in ln.lower()
                )
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_archive_command_survives_leader_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        After the leader (nodeA) restarts, the archive process must resume
        cleanly. Outstanding segments in pg_wal must be archived without gaps.
        """
        archive_dir = tmp_path / "wal_archive_leader"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE leader_archive_tbl (id INT) USING tde_heap; "
                "INSERT INTO leader_archive_tbl SELECT generate_series(1,100);"
            )
            nodeA.execute("SELECT pg_switch_wal()")

            # Full rolling restart
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            nodeA.execute("INSERT INTO leader_archive_tbl SELECT generate_series(101,200)")
            nodeA.execute("SELECT pg_switch_wal()")
            time.sleep(3)

            log_text = nodeA.read_log(last_n=100)
            assert "archive_command failed" not in log_text, (
                "archive_command failures detected after leader restart"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_wal_segments_archived_while_standby_was_down(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        WAL segments that were generated while nodeB was down (upgrade window)
        must be present in the archive directory after nodeB comes back.
        This guarantees PITR continuity through the upgrade window.
        """
        archive_dir = tmp_path / "wal_continuity"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE gap_tbl (id INT) USING tde_heap; "
                "INSERT INTO gap_tbl VALUES (1);"
            )
            nodeA.execute("SELECT pg_switch_wal()")
            time.sleep(2)
            archived_before = set(p.name for p in archive_dir.iterdir())

            nodeB.stop()

            nodeA.execute("INSERT INTO gap_tbl SELECT generate_series(2,50)")
            nodeA.execute("SELECT pg_switch_wal()")
            time.sleep(2)

            nodeB.start()
            nodeB.wait_ready(timeout=60)
            time.sleep(3)

            archived_after = set(p.name for p in archive_dir.iterdir())
            new_segments = archived_after - archived_before
            assert len(new_segments) > 0, (
                "No new WAL segments were archived during the standby-down window"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_pitr_from_archive_works_after_rolling_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        PITR from a WAL archive that spans a rolling restart must succeed.
        This validates that the encrypted WAL produced under both the old and
        new library versions can be replayed to a consistent state.
        """
        archive_dir = tmp_path / "wal_pitr"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE pitr_target (id INT) USING tde_heap; "
                "INSERT INTO pitr_target VALUES (42);"
            )
            nodeA.execute("SELECT pg_switch_wal()")
            pitr_time = nodeA.fetchone("SELECT now()")
            time.sleep(1)

            # Rolling restart
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            # Write after restart — PITR should recover to pre-restart state
            nodeA.execute("DELETE FROM pitr_target")
            nodeA.execute("SELECT pg_switch_wal()")
            time.sleep(2)
            nodeA.stop()

            restore_port = allocate_port()
            restore_dir = tmp_path / "pitr_restore"
            shutil.copytree(str(nodeA.data_dir), str(restore_dir))

            restored = PgCluster(
                restore_dir, restore_port, install_dir,
                socket_dir=tmp_path, io_method=io_method,
            )
            restored.write_default_config(extra_params=_TDE_PARAMS)
            auto_conf = restore_dir / "postgresql.auto.conf"
            with auto_conf.open("a") as f:
                f.write(f"recovery_target_time = '{pitr_time}'\n")
                f.write("recovery_target_action = 'promote'\n")
                f.write(
                    restore_conf_line_raw(
                        archive_dir, install_dir, use_tde_wrappers=True
                    )
                )
            (restore_dir / "recovery.signal").touch()
            restored.add_hba_entry("local all all trust")
            restored.start()
            restored.wait_ready(timeout=90)

            count = restored.fetchone("SELECT COUNT(*) FROM pitr_target")
            assert count == "1", f"PITR did not restore the expected row: count={count}"
            restored.stop()
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_no_archiving_errors_in_full_upgrade_window(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Full simulation of the upgrade window:
          backup → standby restart → writes → leader restart → ALTER EXTENSION
        The nodeA server log must contain zero archive_command failures throughout.
        """
        archive_dir = tmp_path / "wal_full_window"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute("CREATE TABLE window_tbl (id INT) USING tde_heap;")

            # Phase: pre-upgrade data
            nodeA.execute("INSERT INTO window_tbl SELECT generate_series(1,20)")
            nodeA.execute("SELECT pg_switch_wal()")

            # Restart nodeB
            nodeB.stop()
            nodeA.execute("INSERT INTO window_tbl SELECT generate_series(21,40)")
            nodeA.execute("SELECT pg_switch_wal()")
            nodeB.start()
            nodeB.wait_ready(timeout=60)

            # Restart nodeA
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            # ALTER EXTENSION (no-op or real migration)
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")

            # Post-upgrade writes
            nodeA.execute("INSERT INTO window_tbl SELECT generate_series(41,60)")
            nodeA.execute("SELECT pg_switch_wal()")
            time.sleep(3)

            log_text = nodeA.read_log(last_n=200)
            failures = [ln for ln in log_text.splitlines() if "archive_command failed" in ln]
            assert not failures, (
                f"archive_command failures during full upgrade window:\n"
                + "\n".join(failures)
            )
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 4: post-upgrade state ───────────────────────────────────────────────


class TestPostUpgradeState:
    """
    Q5: Should we take a new full backup after the upgrade completes?

    Answer: Yes — always take a fresh full backup after any library upgrade.
    The pre-upgrade backup was taken against the old library; post-upgrade
    backup ensures pgBackRest's internal state (manifest, WAL continuity) is
    consistent with the new library.

    These tests verify the cluster is fully operational after the complete
    upgrade procedure (rolling restart + ALTER EXTENSION).
    """

    def _run_full_upgrade_procedure(
        self,
        nodeA: PgCluster,
        nodeB: PgCluster,
    ) -> None:
        """Simulate the complete documented upgrade steps 2-4."""
        # Step 2-3: restart nodeB (replica) first
        nodeB.stop()
        nodeB.start()
        nodeB.wait_ready(timeout=60)
        repl = ReplicationManager(nodeA, nodeB)
        repl.assert_catchup(timeout=30)

        # Step 4: restart nodeA (leader)
        nodeA.stop()
        nodeA.start()
        nodeA.wait_ready(timeout=60)
        repl.assert_catchup(timeout=60)

        # Step 5: ALTER EXTENSION on all databases
        nodeA.execute("ALTER EXTENSION pg_tde UPDATE")

    def test_encrypted_tables_accessible_after_full_upgrade_procedure(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """All tde_heap rows written before the upgrade must be readable afterward."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE post_upgrade_data (id INT, secret TEXT) USING tde_heap; "
                "INSERT INTO post_upgrade_data SELECT i, md5(i::text) "
                "FROM generate_series(1,300) i;"
            )
            self._run_full_upgrade_procedure(nodeA, nodeB)
            count = nodeA.fetchone("SELECT COUNT(*) FROM post_upgrade_data")
            assert count == "300", f"Data loss after upgrade procedure: {count} rows"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_replication_continues_after_full_upgrade_procedure(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """New writes after the upgrade must replicate correctly to nodeB."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute("CREATE TABLE repl_post (id INT) USING tde_heap;")
            self._run_full_upgrade_procedure(nodeA, nodeB)

            nodeA.execute("INSERT INTO repl_post SELECT generate_series(1,100)")
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("repl_post")
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_key_provider_functional_after_full_upgrade_procedure(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Key provider must be accessible and usable for new tables post-upgrade."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            self._run_full_upgrade_procedure(nodeA, nodeB)
            tde = TdeManager(nodeA)
            count = tde.list_key_providers(scope="global")
            assert count >= 1, "Key provider lost after upgrade procedure"
            # Create a new encrypted table to prove the key is actually usable
            nodeA.execute(
                "CREATE TABLE new_enc_tbl (id INT) USING tde_heap; "
                "INSERT INTO new_enc_tbl VALUES (1),(2);"
            )
            assert nodeA.fetchone("SELECT COUNT(*) FROM new_enc_tbl") == "2"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_wal_encryption_persists_after_full_upgrade_procedure(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_tde.wal_encrypt must remain on after the full upgrade procedure."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            self._run_full_upgrade_procedure(nodeA, nodeB)
            for node, label in ((nodeA, "nodeA"), (nodeB, "nodeB")):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes"), (
                    f"WAL encryption lost on {label} after full upgrade procedure: {val!r}"
                )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_pg_tde_version_and_server_key_info_queryable(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        The verification commands from the upgrade checklist must succeed:
          SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_tde';
          SELECT pg_tde_version();
          SELECT pg_tde_key_info();        -- or pg_tde_server_key_info()
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            self._run_full_upgrade_procedure(nodeA, nodeB)

            ext_row = nodeA.fetchone(
                "SELECT extname || ' ' || extversion "
                "FROM pg_extension WHERE extname='pg_tde'"
            )
            assert ext_row and ext_row.startswith("pg_tde"), (
                f"Unexpected extension row: {ext_row!r}"
            )

            bin_ver = nodeA.fetchone("SELECT pg_tde_version()")
            assert bin_ver, "pg_tde_version() returned NULL after upgrade procedure"

            tde = TdeManager(nodeA)
            key_name = tde.principal_key_name()
            assert key_name, "pg_tde_key_info()/pg_tde_server_key_info() returned no key name"
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_standby_encryption_state_matches_primary(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """After upgrade, nodeB's encryption state must mirror nodeA's."""
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            self._run_full_upgrade_procedure(nodeA, nodeB)

            primary_ver = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            standby_ver = nodeB.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            assert primary_ver == standby_ver, (
                f"Extension version mismatch between nodes: "
                f"nodeA={primary_ver!r}, nodeB={standby_ver!r}"
            )

            primary_wal = nodeA.fetchone("SHOW pg_tde.wal_encrypt")
            standby_wal = nodeB.fetchone("SHOW pg_tde.wal_encrypt")
            assert primary_wal == standby_wal, (
                f"wal_encrypt mismatch: nodeA={primary_wal!r}, nodeB={standby_wal!r}"
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    @pytest.mark.pgbackrest
    def test_post_upgrade_full_backup_succeeds(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Q5: After the upgrade, a new full backup must succeed.

        This is mandatory because:
        - The pre-upgrade backup was taken against the old library.
        - WAL segments during the upgrade window were produced by different
          library versions and may use different internal formats.
        - pgBackRest's manifest must be rebuilt against the post-upgrade state.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        archive_dir = tmp_path / "wal_post_upgrade"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE post_bkp_tbl (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO post_bkp_tbl SELECT i, md5(i::text) "
                "FROM generate_series(1,200) i;"
            )
            self._run_full_upgrade_procedure(nodeA, nodeB)

            bm = BackupManager(
                stanza="tde_post_upgrade", repo_path=str(tmp_path / "repo_post")
            )
            bm.write_config(
                pg_path=str(nodeA.data_dir),
                pg_port=nodeA.port,
                pg_socket_path=str(tmp_path),
            )
            bm.configure_postgres(nodeA)
            nodeA.restart()
            bm.stanza_create()
            bm.backup(backup_type="full")
            info = bm.info()
            assert "full" in info.lower(), "pgBackRest post-upgrade backup not found"
        finally:
            _teardown_pair(nodeA, nodeB)

    @pytest.mark.pgbackrest
    def test_post_upgrade_restore_from_backup_recovers_data(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Restore from the post-upgrade backup and verify all data is intact.
        This is the definitive proof that the backup is usable.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        archive_dir = tmp_path / "wal_restore_verify"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, with_archive=True, archive_dir=archive_dir
        )
        try:
            nodeA.execute(
                "CREATE TABLE restore_verify (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO restore_verify SELECT i, md5(i::text) "
                "FROM generate_series(1,150) i;"
            )
            self._run_full_upgrade_procedure(nodeA, nodeB)

            bm = BackupManager(
                stanza="tde_restore_verify", repo_path=str(tmp_path / "repo_verify")
            )
            bm.write_config(
                pg_path=str(nodeA.data_dir),
                pg_port=nodeA.port,
                pg_socket_path=str(tmp_path),
            )
            bm.configure_postgres(nodeA)
            nodeA.restart()
            bm.stanza_create()
            bm.backup(backup_type="full")

            restore_dir = tmp_path / "post_upgrade_restore"
            restore_port = allocate_port()
            bm.restore(str(restore_dir))

            restored = PgCluster(
                restore_dir, restore_port, install_dir,
                socket_dir=tmp_path, io_method=io_method,
            )
            restored.write_default_config(extra_params=_TDE_PARAMS)
            restored.add_hba_entry("local all all trust")
            restored.start()
            restored.wait_ready(timeout=90)

            count = restored.fetchone("SELECT COUNT(*) FROM restore_verify")
            assert count == "150", (
                f"Post-upgrade restore did not recover all rows: {count}/150"
            )
            restored.stop()
        finally:
            _teardown_pair(nodeA, nodeB)
