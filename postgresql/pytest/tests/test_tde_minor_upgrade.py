"""
pg_tde extension minor-version upgrade tests.

Scope
─────
"Minor upgrade" here means swapping the **pg_tde extension** from one
minor release to the next on the same PostgreSQL major version,
e.g. pg_tde **2.1.2 → 2.2.0**. The PostgreSQL binary major version is
unchanged; the data dir is reused as-is; only the pg_tde ``.so`` (and
its bundled SQL upgrade script + control file) change.

The file has two layers:

1. **Procedural-safety tests (36 tests, single binary)** —
   ``TestTdeMinorUpgradePreConditions`` / ``TestAlterExtensionUpdate`` /
   ``TestRollingRestart`` / ``TestWalArchivingContinuity`` /
   ``TestPostUpgradeState``.

   These run against a single ``--install-dir`` and exercise the
   procedure independent of whether a real binary swap occurred:
   ``ALTER EXTENSION pg_tde UPDATE`` is idempotent, a rolling restart
   preserves WAL encryption and key providers, archiving stays
   continuous through the restart window, etc. These tests catch
   procedural regressions (e.g. ALTER EXTENSION dropping providers)
   without needing two pg_tde builds locally.

2. **Auto-swap tests (single pytest invocation, two install dirs)** —
   ``TestPgTdeMinorBinaryUpgrade`` (single-node, ≈9 tests) and
   ``TestPgTdeMinorBinaryUpgradeRollingHA`` (HA, ≈3 tests). These
   auto-skip unless ``--old-install-dir`` is provided.

   Mechanic when ``--old-install-dir`` is set:

       # 1. initdb under --old-install-dir (e.g. PG+pg_tde 2.1.2)
       old = PgCluster(data_dir, port, old_install_dir, ...)
       old.initdb(); old.write_default_config(...); old.start()
       TdeManager(old).create_extension()       # extversion = '2.1'
       # populate encrypted state...
       old.stop()

       # 2. SAME data dir, new binaries (--install-dir = pg_tde 2.2.0)
       new = PgCluster(old.data_dir, port, install_dir, ...)
       new.start()                              # newer .so loads
       new.execute("ALTER EXTENSION pg_tde UPDATE")   # 2.1 → 2.2
       # verify: extversion bumped, data readable, providers intact,
       #         WAL encryption still active, new writes work...

3. **Staged Setup / Verify tests (two pytest invocations around an
   operator-driven package upgrade)** —
   ``TestPgTdeMinorUpgradeSetup`` / ``TestPgTdeMinorUpgradeVerify``
   (single-node) and ``TestPgTdeMinorUpgradeSetupHA`` /
   ``TestPgTdeMinorUpgradeVerifyHA`` (HA). These auto-skip unless
   ``--upgrade-data-dir`` (or ``PG_TDE_UPGRADE_DATA_DIR`` env var) is
   provided.

   Workflow — pytest *never* swaps binaries itself:

       # Run 1: install OLD pg_tde, prepare persistent state
       pytest tests/test_tde_minor_upgrade.py \\
           --install-dir=/opt/percona/pg18-with-pg_tde-2.1.2 \\
           --upgrade-data-dir=/var/lib/pg_tde_upgrade_test \\
           -k Setup

       # Operator step: yum/apt upgrade the pg_tde package (2.1.2 → 2.2.0)

       # Run 2: validate persistent state under NEW pg_tde
       pytest tests/test_tde_minor_upgrade.py \\
           --install-dir=/opt/percona/pg18-with-pg_tde-2.2.0 \\
           --upgrade-data-dir=/var/lib/pg_tde_upgrade_test \\
           -k Verify

   A small ``upgrade_state.json`` in the persistent directory captures
   the pre-upgrade invariants (extversion, ``pg_tde_version()``,
   provider count, principal key name, row count, per-row digest) so
   the Verify run asserts exact preservation across the operator's
   real package upgrade.

Common cluster shape used throughout the file:
  - PostgreSQL major version: whatever ``--install-dir`` (and, when
    set, ``--old-install-dir``) provide; same major across both.
  - WAL encryption enabled (``pg_tde.wal_encrypt = on``)
  - File-based key provider
  - pgBackRest for backups (with pg_tde WAL wrappers where applicable)
  - ``archive_command`` / ``restore_command`` using
    ``pg_tde_archive_decrypt`` / ``pg_tde_restore_encrypt`` wrappers

Layout
──────
Phase 0  Pre-conditions             TestTdeMinorUpgradePreConditions
Phase 1  ALTER EXTENSION safety     TestAlterExtensionUpdate
Phase 2  Rolling restart            TestRollingRestart
Phase 3  WAL archiving              TestWalArchivingContinuity
Phase 4  Post-upgrade state         TestPostUpgradeState
Phase 5  Auto binary swap           TestPgTdeMinorBinaryUpgrade
Phase 6  Auto HA rolling swap       TestPgTdeMinorBinaryUpgradeRollingHA
Phase 7  Staged Setup / Verify      TestPgTdeMinorUpgradeSetup
                                    TestPgTdeMinorUpgradeVerify
Phase 8  Staged HA Setup / Verify   TestPgTdeMinorUpgradeSetupHA
                                    TestPgTdeMinorUpgradeVerifyHA

Answers embedded in docstrings
───────────────────────────────
Q1  ALTER EXTENSION required?        → TestAlterExtensionUpdate
Q2  Breaking changes / migrations?   → TestAlterExtensionUpdate / TestPgTdeMinorBinaryUpgrade
Q3  Install order vs restart order?  → TestRollingRestart / TestPgTdeMinorBinaryUpgradeRollingHA
Q4  WAL encryption precautions?      → TestWalArchivingContinuity
Q5  Post-upgrade backup needed?      → TestPostUpgradeState
"""

import json
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Generator, Optional, Tuple

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
from lib.cluster import initdb_args_no_data_checksums, postgres_major_version

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


def _force_switch_and_wait_archived(
    node: PgCluster, archive_dir: Path, *, timeout: int = 30
) -> str:
    """
    Force a WAL segment switch on ``node`` and block until the segment
    that was just closed lands in ``archive_dir``.

    Returns the closed segment name. Raises ``AssertionError`` if the
    archive_command didn't deliver within ``timeout`` seconds — that's a
    real failure (archive_command broken / archiver process stuck) and
    should NOT be swallowed by ``time.sleep`` heuristics elsewhere in
    the file.
    """
    closed = (node.fetchone("SELECT pg_walfile_name(pg_switch_wal())") or "").strip()
    assert closed, "pg_switch_wal() did not return a segment name"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (archive_dir / closed).exists():
            return closed
        time.sleep(0.5)
    raise AssertionError(
        f"WAL segment {closed!r} was not archived to {archive_dir} within "
        f"{timeout}s. archive_command may have failed; archive dir contains: "
        f"{[p.name for p in archive_dir.iterdir() if p.is_file()]}"
    )


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
        Q1 context: pg_tde's control file declares ``default_version =
        'X.Y'`` where ``X.Y`` is the major.minor of the shipped release.
        For example, the 2.1.x patch line ships with
        ``default_version='2.1'`` and ``pg_tde_version()`` may return
        ``'pg_tde 2.1.2'``; the 2.2.x patch line ships with
        ``default_version='2.2'`` and ``pg_tde_version()`` returns
        ``'pg_tde 2.2.0'``.

        This test documents (and asserts) the invariant:
          extversion == major.minor portion of binary version
        so that ``ALTER EXTENSION pg_tde UPDATE`` is always a safe
        no-op when the control file's ``default_version`` has not
        changed. A real migration only happens when the binary moves
        to a new ``X.Y`` line (e.g. 2.1.2 → 2.2.0); that case is
        exercised by ``TestPgTdeMinorBinaryUpgrade``.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            ext_ver = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            bin_ver = nodeA.fetchone("SELECT pg_tde_version()")
            assert ext_ver is not None, "pg_tde extension not installed"
            assert bin_ver is not None, "pg_tde_version() returned NULL"

            # e.g. ext_ver='2.2', bin_ver='pg_tde 2.2.0' or '2.2.0'.
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

        Must route ``archive_command`` through pgBackRest (otherwise
        pgBackRest exits 68: "archive_command ... must contain pgbackrest").
        On a WAL-encrypted cluster we MUST wrap with
        ``pg_tde_archive_decrypt`` so pgBackRest's repo holds plaintext
        WAL — the wrapper integration is what
        ``BackupManager.configure_postgres(..., pg_tde_wal_archiving=True)``
        does, and it requires ``pg_bin`` to be set on the manager.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        # Build a plain TDE HA pair WITHOUT a file-based archive_command.
        # pgBackRest will own ``archive_command`` end-to-end below.
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
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
                pg_bin=str(nodeA.bin),
            )
            bm.configure_postgres(nodeA, pg_tde_wal_archiving=True)
            nodeA.restart()
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

    Within a patch line (e.g. 2.1.0 → 2.1.1 → 2.1.2) the control file's
    ``default_version`` does not move ('2.1'), so ``ALTER EXTENSION
    pg_tde UPDATE`` is a no-op. Across a minor line (e.g. 2.1.2 →
    2.2.0) ``default_version`` advances to '2.2' and ``ALTER EXTENSION
    pg_tde UPDATE`` runs the bundled ``pg_tde--2.1--2.2.sql`` migration.
    Either way the command MUST NOT fail, corrupt key state, or
    disable WAL encryption.

    These tests verify the command is always safe to run (idempotent),
    regardless of whether it actually migrates anything. The
    "actually migrates anything" case is covered end-to-end in
    ``TestPgTdeMinorBinaryUpgrade`` (which requires ``--old-install-dir``).
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

        Correct PITR flow (same shape as test_pitr.py::test_pitr_encrypted_wal):

          1. INSERT the row we want to recover.
          2. Stop nodeA cleanly and take a *cold copy of PGDATA* — that's
             our pseudo base backup. The control-file checkpoint at this
             moment defines where recovery starts replaying from.
          3. Restart nodeA, capture ``pitr_time`` (T1), simulate the
             rolling restart, then do the DELETE (after T1).
          4. ``pg_switch_wal`` and **wait** for the closed segment to
             actually land in ``archive_dir`` — otherwise the segment
             holding the DELETE record never reaches the archive, and the
             restored cluster can't find any post-T1 record to anchor
             ``recovery_target_time`` to. That's the failure mode the
             original test hit: ``recovery ended before configured
             recovery target was reached``.
          5. Restore from the cold copy, set recovery_target_time = T1,
             promote. Recovery replays WAL from the cold-copy checkpoint
             forward, sees the DELETE commit record's timestamp is > T1,
             and stops just before it → row is recovered.
        """
        archive_dir = tmp_path / "wal_pitr"
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method,
            with_archive=True, archive_dir=archive_dir,
        )
        try:
            nodeA.execute(
                "CREATE TABLE pitr_target (id INT) USING tde_heap; "
                "INSERT INTO pitr_target VALUES (42);"
            )
            # Force the INSERT into a closed, archived segment.
            _force_switch_and_wait_archived(nodeA, archive_dir, timeout=30)

            # Cold copy = the recovery start point. Take it BEFORE the
            # destructive DELETE — copying afterwards puts the control
            # file's last-checkpoint past T1 and "redo is not required"
            # kills the test.
            nodeA.stop()
            restore_dir = tmp_path / "pitr_restore"
            shutil.copytree(str(nodeA.data_dir), str(restore_dir))
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            pitr_time = nodeA.fetchone("SELECT now()")
            time.sleep(1)   # ensure T1 < any subsequent commit timestamp

            # Rolling restart — the whole point of this test is that PITR
            # still works across the restart window.
            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            # Destructive write AFTER T1 — recovery must stop just before
            # this record.
            nodeA.execute("DELETE FROM pitr_target")
            # Synchronously archive the segment that contains the DELETE
            # (was time.sleep(2); 2s is not enough when the archiver is
            # busy or when archive_command is the pg_tde_archive_decrypt
            # wrapper). The helper raises if the segment doesn't land.
            _force_switch_and_wait_archived(nodeA, archive_dir, timeout=30)
            nodeA.stop()

            restore_port = allocate_port()
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

        Two things must be right for pgBackRest to succeed on a TDE +
        WAL-encryption cluster:

          a. ``archive_command`` must route WAL through pgBackRest
             (pgBackRest exit 68 otherwise).
          b. WAL must be **decrypted** by ``pg_tde_archive_decrypt`` before
             pgBackRest sees it — otherwise pgBackRest's prior-segment
             check times out (exit 82, "WAL segment ... was not archived
             before the 60000ms timeout") because it can't parse the
             encrypted bytes.

        Both are handled by ``configure_postgres(..., pg_tde_wal_archiving=True)``
        — but that requires ``pg_bin`` on the manager. The cluster MUST NOT
        be built with ``with_archive=True``, or pre-existing WAL would have
        landed in a non-pgBackRest archive dir and pgBackRest would fail
        the prior-segment check.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
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
                pg_bin=str(nodeA.bin),
            )
            bm.configure_postgres(nodeA, pg_tde_wal_archiving=True)
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

        Restore must also wire ``pg_tde_restore_encrypt`` into
        ``restore_command`` (``pg_tde_wal_restore=True``) — without it, the
        restored cluster fetches plaintext WAL from pgBackRest's repo,
        writes it into ``pg_wal/`` un-encrypted, and recovery FATALs
        because the WAL stream doesn't match what the WAL encryption
        layer expects.
        """
        if not pgbackrest_installed():
            pytest.skip("pgbackrest not installed")

        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
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
                pg_bin=str(nodeA.bin),
            )
            bm.configure_postgres(nodeA, pg_tde_wal_archiving=True)
            nodeA.restart()
            bm.stanza_create()
            bm.backup(backup_type="full")

            restore_dir = tmp_path / "post_upgrade_restore"
            restore_port = allocate_port()
            bm.restore(str(restore_dir), pg_tde_wal_restore=True)

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


# ── Phase 5: real pg_tde binary swap (single-node) ────────────────────────────


def _skip_if_no_old_install(old_install_dir: Optional[Path]) -> None:
    """Skip cleanly when --old-install-dir was not provided on the command line.

    The binary-swap tests need TWO distinct pg_tde builds; if the test
    runner only has one, there is nothing to verify and the right
    behaviour is a skip (not a failure).
    """
    if old_install_dir is None:
        pytest.skip(
            "--old-install-dir not provided; cannot exercise a real "
            "pg_tde binary swap (e.g. 2.1.2 → 2.2.0)."
        )


def _swap_install_dir(node: PgCluster, new_install_dir: Path) -> PgCluster:
    """Return a fresh ``PgCluster`` pointing at the same data dir but using
    binaries from ``new_install_dir``.

    The caller MUST have stopped ``node`` first. Port / socket_dir /
    io_method are carried over so the swapped cluster can be reached
    by the same connection parameters. The new cluster is returned
    *not yet started* — the caller must call ``.start()`` and
    ``.wait_ready()``.
    """
    return PgCluster(
        node.data_dir,
        node.port,
        new_install_dir,
        socket_dir=node.socket_dir,
        io_method=node.io_method,
    )


def _build_single_node_old(
    tmp_path: Path,
    old_install_dir: Path,
    io_method: str,
    *,
    subdir: str = "nodeA",
    wal_encrypt: bool = True,
) -> PgCluster:
    """Create and start a single-node TDE cluster on the OLD pg_tde binary.

    Mirrors the relevant subset of ``_build_ha_cluster``'s nodeA setup
    but takes the install dir explicitly so the caller can later swap
    binaries.
    """
    node = PgCluster(
        tmp_path / subdir,
        allocate_port(),
        old_install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    node.initdb(extra_args=initdb_args_no_data_checksums(old_install_dir))
    node.write_default_config(extra_params=dict(_TDE_PARAMS))
    node.add_hba_entry("local all all trust")
    node.add_hba_entry("local replication all trust")
    node.add_hba_entry("host  all all 127.0.0.1/32 trust")
    node.add_hba_entry("host  replication all 127.0.0.1/32 trust")
    node.start()

    tde = TdeManager(node)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=_KEYFILE)
    tde.set_global_principal_key()
    if wal_encrypt:
        tde.enable_wal_encryption()
        node.restart()
    return node


def _cleanup_swap_candidates(*candidates: Optional[PgCluster]) -> None:
    """Stop and remove the data dir of every non-None cluster.

    Used by binary-swap tests' ``finally`` blocks. Both the pre-swap
    ``node`` and the post-swap ``swapped`` reference the SAME data
    dir, so this function is robust to the failure mode where the
    swap never completed: only one of them is started, the other is
    None or already stopped. Errors are swallowed — the goal is best-
    effort cleanup, not to mask the test-body failure that triggered
    the ``finally`` in the first place.
    """
    for n in candidates:
        if n is None:
            continue
        try:
            if n.is_ready():
                n.stop(check=False)
        except Exception:
            pass
    # The data dir is shared between candidates; remove once based on
    # whichever cluster object still has the path attribute.
    for n in candidates:
        if n is None:
            continue
        try:
            shutil.rmtree(n.data_dir, ignore_errors=True)
        except Exception:
            pass
        break


def _binary_swap_node(node: PgCluster, new_install_dir: Path) -> PgCluster:
    """Stop *node*, return a new ``PgCluster`` started against
    ``new_install_dir`` using the same data dir.

    This is the central primitive of every binary-swap test: clean
    stop on the old binaries → new binaries pointed at the existing
    PGDATA → start. After this returns, the caller still needs to
    run ``ALTER EXTENSION pg_tde UPDATE`` if the catalog
    ``default_version`` moved between builds.
    """
    node.stop()
    swapped = _swap_install_dir(node, new_install_dir)
    swapped.start()
    swapped.wait_ready(timeout=90)
    return swapped


def _read_extversion(node: PgCluster) -> str:
    return node.fetchone(
        "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
    ) or ""


def _read_binary_version(node: PgCluster) -> str:
    raw = node.fetchone("SELECT pg_tde_version()") or ""
    # Outputs look like 'pg_tde 2.1.2' OR '2.1.2'; normalise to the bare X.Y.Z.
    return raw.strip().split()[-1] if raw.strip() else ""


class TestPgTdeMinorBinaryUpgrade:
    """
    Real pg_tde extension minor upgrade — e.g. 2.1.2 → 2.2.0.

    Each test runs the full procedure end-to-end:

      1. initdb + configure pg_tde under ``--old-install-dir`` (the
         older pg_tde minor build, e.g. ships with pg_tde 2.1.2).
      2. Populate encrypted state: file key provider, principal key,
         WAL encryption on, ``tde_heap`` table with data, optionally
         a second database with the extension.
      3. Clean stop.
      4. Same data dir restarted against ``--install-dir`` (the newer
         pg_tde minor build, e.g. ships with pg_tde 2.2.0).
      5. ``ALTER EXTENSION pg_tde UPDATE`` (runs the bundled
         ``pg_tde--X.Y--A.B.sql`` migration when ``default_version``
         differs between builds).
      6. Verify the contract: catalog version advanced, on-disk data
         readable, key providers + principal key intact, WAL still
         encrypted, new writes succeed.

    All tests skip cleanly when ``--old-install-dir`` is not supplied.
    """

    def test_extension_extversion_advances_after_alter_update(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """``extversion`` must equal the new build's ``default_version``
        after the swap + ``ALTER EXTENSION pg_tde UPDATE``.

        This is the headline acceptance criterion: when 2.1.2 → 2.2.0,
        the catalog should advance from '2.1' to '2.2'. The exact
        before/after strings are not hard-coded so the test works for
        any pair of minor builds the user has installed.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            ext_before = _read_extversion(node)
            bin_before = _read_binary_version(node)
            assert ext_before, "pg_tde extversion empty on old build"

            swapped = _binary_swap_node(node, install_dir)
            ext_after_swap = _read_extversion(swapped)
            bin_after_swap = _read_binary_version(swapped)

            # Before ALTER EXTENSION UPDATE the catalog entry still
            # reflects the OLD build (catalog state lives in the data
            # dir, not the .so).
            assert ext_after_swap == ext_before, (
                f"extversion changed merely by swapping binaries: "
                f"{ext_before!r} → {ext_after_swap!r} (ALTER EXTENSION was not run yet)"
            )

            swapped.execute("ALTER EXTENSION pg_tde UPDATE")
            ext_after_alter = _read_extversion(swapped)

            # If the binary's default_version moved, extversion must
            # advance to it; if it did not move (same X.Y line), the
            # value must stay put. Both are valid outcomes — what the
            # test pins down is that extversion now matches the
            # NEW binary's reported major.minor.
            assert bin_after_swap.startswith(ext_after_alter), (
                f"After ALTER EXTENSION pg_tde UPDATE, extversion "
                f"({ext_after_alter!r}) is not a prefix of the new "
                f"binary version ({bin_after_swap!r}). Old binary "
                f"reported {bin_before!r}."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_encrypted_data_readable_immediately_after_binary_swap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Encrypted heap rows written under the OLD pg_tde binary must
        be readable under the NEW binary even BEFORE
        ``ALTER EXTENSION pg_tde UPDATE``.

        The on-disk encrypted format is the contract that survives a
        minor upgrade; ``ALTER EXTENSION`` migrates the catalog, not
        the encrypted blocks. Pinning the "readable immediately after
        swap" invariant catches regressions where a new minor build
        accidentally changes block format.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            node.execute(
                "CREATE TABLE minor_upgrade_data (id INT, payload TEXT) USING tde_heap; "
                "INSERT INTO minor_upgrade_data "
                "SELECT i, md5(i::text) FROM generate_series(1, 500) i;"
            )
            checksum_before = node.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) "
                "FROM minor_upgrade_data"
            )

            swapped = _binary_swap_node(node, install_dir)
            count = swapped.fetchone("SELECT COUNT(*) FROM minor_upgrade_data")
            assert count == "500", (
                f"Row count after binary swap: {count} (expected 500). "
                f"Encrypted heap is not readable on the new pg_tde binary."
            )
            checksum_after = swapped.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) "
                "FROM minor_upgrade_data"
            )
            assert checksum_before == checksum_after, (
                "Per-row payload digest changed across binary swap — "
                "encrypted heap decoded to different plaintext on the "
                "new build."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_encrypted_data_still_readable_after_alter_extension_update(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Even after the SQL migration (``pg_tde--X.Y--A.B.sql``)
        runs, the same encrypted rows must still come back unchanged.
        Catches catalog migrations that accidentally drop / rewrite
        the relation's key state.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            node.execute(
                "CREATE TABLE migrate_data (id INT, payload TEXT) USING tde_heap; "
                "INSERT INTO migrate_data "
                "SELECT i, md5(i::text) FROM generate_series(1, 250) i;"
            )
            digest_before = node.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM migrate_data"
            )

            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")

            count = swapped.fetchone("SELECT COUNT(*) FROM migrate_data")
            digest_after = swapped.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM migrate_data"
            )
            assert count == "250", f"Row count after ALTER EXTENSION UPDATE: {count}"
            assert digest_before == digest_after, (
                "Per-row payload digest changed across "
                "ALTER EXTENSION pg_tde UPDATE — the migration "
                "rewrote relation key state or broke decryption."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_key_providers_survive_minor_binary_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Global key providers + principal key name must be unchanged
        after the swap + ALTER EXTENSION UPDATE.

        A regression here would brick every encrypted table because
        the new build would have no way to derive the data keys.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            tde_old = TdeManager(node)
            providers_before = tde_old.list_key_providers(scope="global")
            key_before = tde_old.principal_key_name()
            assert providers_before >= 1, "No key providers before upgrade"
            assert key_before, "No principal key before upgrade"

            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")

            tde_new = TdeManager(swapped)
            providers_after = tde_new.list_key_providers(scope="global")
            key_after = tde_new.principal_key_name()

            assert providers_after == providers_before, (
                f"Key provider count changed across minor upgrade: "
                f"{providers_before} → {providers_after}"
            )
            assert key_after == key_before, (
                f"Principal key name changed across minor upgrade: "
                f"{key_before!r} → {key_after!r}"
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_wal_encryption_remains_active_after_minor_binary_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """``pg_tde.wal_encrypt`` was on under the OLD build; it must
        still be on after the swap + ALTER EXTENSION UPDATE. The
        encrypted WAL produced by the old build must still be readable
        by the new build's startup recovery.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(
            tmp_path, old_install_dir, io_method, wal_encrypt=True
        )
        swapped: Optional[PgCluster] = None
        try:
            wal_before = node.fetchone("SHOW pg_tde.wal_encrypt")
            assert wal_before in ("on", "true", "1", "yes"), (
                f"WAL encryption was not on before swap: {wal_before!r}"
            )

            # Generate some encrypted WAL so the new build has to
            # decode old-format WAL during startup recovery.
            node.execute("CREATE TABLE wal_check (id INT) USING tde_heap")
            node.execute("INSERT INTO wal_check SELECT generate_series(1, 200)")
            node.execute("SELECT pg_switch_wal()")
            node.execute("CHECKPOINT")

            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")

            wal_after = swapped.fetchone("SHOW pg_tde.wal_encrypt")
            assert wal_after in ("on", "true", "1", "yes"), (
                f"WAL encryption disabled by minor upgrade: {wal_after!r}"
            )
            # Sanity check: data inserted before the swap survives.
            assert swapped.fetchone("SELECT COUNT(*) FROM wal_check") == "200"
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_pg_tde_version_function_reflects_new_binary(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """After the swap, ``SELECT pg_tde_version()`` must report the
        NEW binary's version string (not the cached old one). The
        function is implemented in the C library, so its return value
        flips the moment the new ``.so`` is loaded — regardless of
        whether ``ALTER EXTENSION pg_tde UPDATE`` has run yet.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            bin_before = _read_binary_version(node)
            assert bin_before, "pg_tde_version() returned empty on old build"

            swapped = _binary_swap_node(node, install_dir)
            bin_after = _read_binary_version(swapped)
            assert bin_after, "pg_tde_version() returned empty on new build"

            # If the two install dirs ship the same pg_tde build,
            # there is no real upgrade to verify — skip rather than
            # pretend the test exercised the swap.
            if bin_before == bin_after:
                pytest.skip(
                    f"--old-install-dir and --install-dir both report "
                    f"pg_tde {bin_after!r}; there is no minor upgrade "
                    f"to test against."
                )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_new_writes_to_existing_tde_heap_work_after_minor_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """A ``tde_heap`` created under the OLD build must accept new
        INSERTs (and the new rows must be encrypted) under the NEW
        build after ALTER EXTENSION UPDATE.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            node.execute(
                "CREATE TABLE post_upgrade_write (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO post_upgrade_write "
                "SELECT i, md5(i::text) FROM generate_series(1, 100) i;"
            )

            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")

            swapped.execute(
                "INSERT INTO post_upgrade_write "
                "SELECT i, md5(i::text) FROM generate_series(101, 300) i;"
            )
            total = swapped.fetchone("SELECT COUNT(*) FROM post_upgrade_write")
            assert total == "300", (
                f"Post-upgrade INSERT lost rows: {total}/300"
            )
            tde_new = TdeManager(swapped)
            assert tde_new.is_table_encrypted("post_upgrade_write"), (
                "tde_heap created under old binary reports unencrypted "
                "after minor upgrade — relation key state lost."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_create_new_tde_heap_after_minor_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """The new build must allow creating fresh ``tde_heap`` relations
        and encrypt them correctly — the upgraded extension is fully
        functional, not just backward-compatible.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")

            swapped.execute(
                "CREATE TABLE fresh_post_upgrade (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO fresh_post_upgrade "
                "SELECT i, md5(i::text) FROM generate_series(1, 150) i;"
            )
            assert swapped.fetchone(
                "SELECT COUNT(*) FROM fresh_post_upgrade"
            ) == "150"
            tde_new = TdeManager(swapped)
            assert tde_new.is_table_encrypted("fresh_post_upgrade"), (
                "Newly-created tde_heap after minor upgrade is not encrypted."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)

    def test_alter_extension_update_idempotent_after_minor_swap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """After the swap, ``ALTER EXTENSION pg_tde UPDATE`` may do real
        work the first time; the second time it MUST be a clean no-op
        that leaves ``extversion`` unchanged.
        """
        _skip_if_no_old_install(old_install_dir)
        node = _build_single_node_old(tmp_path, old_install_dir, io_method)
        swapped: Optional[PgCluster] = None
        try:
            swapped = _binary_swap_node(node, install_dir)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")
            ext_after_first = _read_extversion(swapped)
            swapped.execute("ALTER EXTENSION pg_tde UPDATE")
            ext_after_second = _read_extversion(swapped)
            assert ext_after_first == ext_after_second, (
                f"ALTER EXTENSION pg_tde UPDATE is not idempotent after "
                f"minor swap: extversion {ext_after_first!r} → "
                f"{ext_after_second!r} on the second run."
            )
        finally:
            _cleanup_swap_candidates(swapped, node)


# ── Phase 6: HA rolling pg_tde binary swap ────────────────────────────────────


def _build_ha_cluster_explicit_install(
    tmp_path: Path,
    install_dir: Path,
    io_method: str,
    *,
    wal_encrypt: bool = True,
) -> Tuple[PgCluster, PgCluster]:
    """Variant of ``_build_ha_cluster`` that takes the install_dir
    explicitly (no implicit ``install_dir`` fixture). Used by the
    rolling-swap tests so caller-side code can pass ``old_install_dir``
    for the initial bring-up.

    Body is intentionally aligned with ``_build_ha_cluster`` to avoid
    drift: any future change to the bring-up should be applied here too.
    """
    return _build_ha_cluster(
        tmp_path,
        install_dir,
        io_method,
        wal_encrypt=wal_encrypt,
    )


def _rolling_swap_pair(
    nodeA: PgCluster,
    nodeB: PgCluster,
    new_install_dir: Path,
) -> Tuple[PgCluster, PgCluster]:
    """Patroni-style rolling swap: replica first, then primary.

    Steps (matching the documented procedure exercised by
    ``TestRollingRestart`` but with a real binary change):

      1. Stop nodeB (replica) on old binaries.
      2. Re-create nodeB against ``new_install_dir`` (same data dir);
         start it. It reconnects to nodeA (still on old binaries) and
         catches up via streaming replication. The replication
         protocol is stable across pg_tde minor versions, so this
         must succeed.
      3. Stop nodeA (primary) on old binaries.
      4. Re-create nodeA against ``new_install_dir``; start it.
      5. Run ``ALTER EXTENSION pg_tde UPDATE`` on the now-primary
         (nodeA). The standby will replay the catalog migration via
         WAL — no separate ALTER EXTENSION needed on the replica.

    Returns the new (nodeA, nodeB) cluster objects.
    """
    # Replica first.
    nodeB.stop()
    new_nodeB = _swap_install_dir(nodeB, new_install_dir)
    new_nodeB.start()
    new_nodeB.wait_ready(timeout=90)

    # Primary second.
    nodeA.stop()
    new_nodeA = _swap_install_dir(nodeA, new_install_dir)
    new_nodeA.start()
    new_nodeA.wait_ready(timeout=90)

    # Catalog migration on the primary; standby replays via WAL.
    new_nodeA.execute("ALTER EXTENSION pg_tde UPDATE")
    return new_nodeA, new_nodeB


class TestPgTdeMinorBinaryUpgradeRollingHA:
    """
    Two-node HA rolling pg_tde extension minor upgrade.

    Mirrors the documented Patroni rolling-upgrade procedure for a
    real pg_tde binary swap (e.g. 2.1.2 → 2.2.0):

      1. Bring up nodeA (primary) + nodeB (replica) under the OLD
         pg_tde build (``--old-install-dir``).
      2. Populate encrypted state, generate WAL traffic.
      3. Stop nodeB, swap to NEW binaries, restart against same PGDATA.
      4. Stop nodeA, swap to NEW binaries, restart against same PGDATA.
      5. ``ALTER EXTENSION pg_tde UPDATE`` on the primary; replica
         replays via WAL.
      6. Verify replication still works, data is intact, WAL is still
         encrypted on both nodes.

    Skips cleanly when ``--old-install-dir`` is not provided.
    """

    def test_rolling_minor_binary_swap_succeeds_on_both_nodes(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """End-to-end happy path: bring up under old binaries, do the
        rolling swap, verify both nodes are healthy under new binaries
        and replicating.
        """
        _skip_if_no_old_install(old_install_dir)
        nodeA, nodeB = _build_ha_cluster_explicit_install(
            tmp_path, old_install_dir, io_method
        )
        new_A = new_B = None
        try:
            nodeA.execute(
                "CREATE TABLE rolling_minor (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO rolling_minor "
                "SELECT i, md5(i::text) FROM generate_series(1, 200) i;"
            )
            ReplicationManager(nodeA, nodeB).assert_catchup(timeout=30)

            new_A, new_B = _rolling_swap_pair(nodeA, nodeB, install_dir)

            # Both nodes must be reachable and report a sensible state.
            assert new_A.is_ready(), "primary not ready after rolling swap"
            assert new_B.is_ready(), "replica not ready after rolling swap"
            assert new_A.fetchone("SELECT pg_is_in_recovery()") == "f", (
                "primary is in recovery after rolling swap"
            )
            assert new_B.fetchone("SELECT pg_is_in_recovery()") == "t", (
                "replica is not in recovery after rolling swap"
            )
        finally:
            for n in (new_B, new_A, nodeB, nodeA):
                if n is None:
                    continue
                try:
                    if n.is_ready():
                        n.stop(check=False)
                except Exception:
                    pass

    def test_data_continuity_through_rolling_minor_binary_swap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Rows written BEFORE and AFTER the rolling swap must appear
        on both nodes when the swap completes.

        This catches the most insidious failure mode: replication
        appears to work but a chunk of pre-swap WAL is silently
        skipped on the new binary.
        """
        _skip_if_no_old_install(old_install_dir)
        nodeA, nodeB = _build_ha_cluster_explicit_install(
            tmp_path, old_install_dir, io_method
        )
        new_A = new_B = None
        try:
            # Pre-swap workload.
            nodeA.execute(
                "CREATE TABLE pre_post (id INT, when_phase TEXT) USING tde_heap; "
                "INSERT INTO pre_post "
                "SELECT i, 'pre' FROM generate_series(1, 100) i;"
            )
            ReplicationManager(nodeA, nodeB).assert_catchup(timeout=30)

            new_A, new_B = _rolling_swap_pair(nodeA, nodeB, install_dir)

            # Post-swap workload on the (new) primary.
            new_A.execute(
                "INSERT INTO pre_post "
                "SELECT i, 'post' FROM generate_series(101, 250) i;"
            )

            repl = ReplicationManager(new_A, new_B)
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("pre_post")

            # Both phases present and accounted for.
            phases = new_B.fetchone(
                "SELECT string_agg(DISTINCT when_phase, ',' ORDER BY when_phase) "
                "FROM pre_post"
            )
            assert phases == "post,pre", (
                f"Pre/post phase mix on replica after rolling swap: {phases!r}"
            )
            total_primary = new_A.fetchone("SELECT COUNT(*) FROM pre_post")
            total_replica = new_B.fetchone("SELECT COUNT(*) FROM pre_post")
            assert total_primary == total_replica == "250", (
                f"Row counts diverge after rolling minor swap: "
                f"primary={total_primary} replica={total_replica}"
            )
        finally:
            for n in (new_B, new_A, nodeB, nodeA):
                if n is None:
                    continue
                try:
                    if n.is_ready():
                        n.stop(check=False)
                except Exception:
                    pass

    def test_wal_encryption_and_key_state_intact_after_rolling_minor_swap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """WAL encryption stays on, principal key name is preserved,
        and provider count is preserved on both nodes after the
        rolling minor binary upgrade.
        """
        _skip_if_no_old_install(old_install_dir)
        nodeA, nodeB = _build_ha_cluster_explicit_install(
            tmp_path, old_install_dir, io_method, wal_encrypt=True
        )
        new_A = new_B = None
        try:
            tde_old = TdeManager(nodeA)
            providers_before = tde_old.list_key_providers(scope="global")
            key_before = tde_old.principal_key_name()
            assert providers_before >= 1, "No providers under old build"
            assert key_before, "No principal key under old build"

            new_A, new_B = _rolling_swap_pair(nodeA, nodeB, install_dir)

            for node, label in ((new_A, "primary"), (new_B, "replica")):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes"), (
                    f"WAL encryption off on {label} after rolling swap: {val!r}"
                )

            tde_new = TdeManager(new_A)
            providers_after = tde_new.list_key_providers(scope="global")
            key_after = tde_new.principal_key_name()
            assert providers_after == providers_before, (
                f"Provider count changed across rolling swap: "
                f"{providers_before} → {providers_after}"
            )
            assert key_after == key_before, (
                f"Principal key changed across rolling swap: "
                f"{key_before!r} → {key_after!r}"
            )
        finally:
            for n in (new_B, new_A, nodeB, nodeA):
                if n is None:
                    continue
                try:
                    if n.is_ready():
                        n.stop(check=False)
                except Exception:
                    pass


# ── Phase 7 & 8: staged Setup / Verify flow ───────────────────────────────────
#
# These classes model the *real* operator-driven minor upgrade. pytest never
# swaps binaries itself: the Setup run prepares a persistent PGDATA under
# --install-dir = OLD, the operator (or CI step) performs the package upgrade
# externally, then the Verify run validates the same PGDATA under
# --install-dir = NEW.
#
#   pytest tests/test_tde_minor_upgrade.py \
#       --install-dir=/opt/percona/pg18-with-pg_tde-2.1.2 \
#       --upgrade-data-dir=/var/lib/pg_tde_upgrade_test \
#       -k Setup
#
#   <operator>: yum upgrade -y percona-postgresql-tde-extension      # 2.1.2 → 2.2.0
#
#   pytest tests/test_tde_minor_upgrade.py \
#       --install-dir=/opt/percona/pg18-with-pg_tde-2.2.0 \
#       --upgrade-data-dir=/var/lib/pg_tde_upgrade_test \
#       -k Verify
#
# A small JSON state file in --upgrade-data-dir captures the pre-upgrade
# invariants (extversion, pg_tde_version, provider count, principal key
# name, row count, data digest) so the Verify run can assert exact
# preservation across the binary upgrade.


_STATE_FILENAME = "upgrade_state.json"
_PERSIST_KEYFILE = "keyfile.per"
_PERSIST_TEST_TABLE = "staged_minor_upgrade"
_PERSIST_ROW_COUNT = 500


def _skip_if_no_upgrade_dir(upgrade_data_dir: Optional[Path]) -> None:
    """Skip cleanly when neither --upgrade-data-dir nor PG_TDE_UPGRADE_DATA_DIR
    was provided. Staged tests require a stable cross-run path.
    """
    if upgrade_data_dir is None:
        pytest.skip(
            "--upgrade-data-dir not provided (and PG_TDE_UPGRADE_DATA_DIR "
            "env var is unset); staged Setup/Verify cannot run."
        )


def _scenario_root(upgrade_data_dir: Path, scenario: str) -> Path:
    """Return the per-scenario persistent root, e.g. .../single or .../ha."""
    return upgrade_data_dir / scenario


def _state_path(scenario_root: Path) -> Path:
    return scenario_root / _STATE_FILENAME


def _write_state(scenario_root: Path, payload: Dict[str, Any]) -> None:
    scenario_root.mkdir(parents=True, exist_ok=True)
    path = _state_path(scenario_root)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True))
    tmp.replace(path)


def _read_state(scenario_root: Path) -> Dict[str, Any]:
    path = _state_path(scenario_root)
    if not path.exists():
        pytest.skip(
            f"No staged Setup state at {path!s}; run the matching "
            f"TestPgTdeMinorUpgrade*Setup class against the OLD "
            f"--install-dir first."
        )
    return json.loads(path.read_text())


def _reset_scenario_root(scenario_root: Path) -> None:
    """Wipe the persistent scenario directory so Setup starts fresh.

    Setup is destructive on purpose: re-running Setup re-initdb's. The
    operator should point ``--upgrade-data-dir`` at a directory whose
    contents are safe to discard.
    """
    if scenario_root.exists():
        shutil.rmtree(scenario_root)
    scenario_root.mkdir(parents=True, exist_ok=True)


def _persist_keyfile_path(scenario_root: Path) -> str:
    """Keyfile lives inside the persistent directory so the operator
    doesn't have to remember a separate /tmp path between the Setup
    and Verify runs.
    """
    return str(scenario_root / _PERSIST_KEYFILE)


def _bind_cluster_to_persistent_data_dir(
    install_dir: Path,
    data_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    extra_params: Optional[Dict[str, str]] = None,
) -> PgCluster:
    """Re-attach to an existing PGDATA under a new ``install_dir``.

    Rewrites ``postgresql.conf`` with a fresh port and ``socket_dir``
    (those are run-local: the OLD-build values don't apply to the new
    run). Leaves ``pg_hba.conf`` untouched. Returns the cluster
    *not yet started*.
    """
    port = allocate_port()
    cluster = PgCluster(
        data_dir, port, install_dir, socket_dir=socket_dir, io_method=io_method
    )
    params: Dict[str, str] = dict(_TDE_PARAMS)
    if extra_params:
        params.update(extra_params)
    cluster.write_default_config(extra_params=params)
    return cluster


def _capture_pre_upgrade_state(
    cluster: PgCluster, scenario: str, install_dir: Path, **extras: Any
) -> Dict[str, Any]:
    """Read the pg_tde invariants we want to assert preservation of."""
    tde = TdeManager(cluster)
    payload: Dict[str, Any] = {
        "scenario": scenario,
        "old_install_dir": str(install_dir),
        "old_pg_tde_binary_version": (
            cluster.fetchone("SELECT pg_tde_version()") or ""
        ).strip(),
        "old_extversion": (
            cluster.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            or ""
        ),
        "wal_encrypt_on": (
            cluster.fetchone("SHOW pg_tde.wal_encrypt") or ""
        ).lower() in ("on", "true", "1", "yes"),
        "key_provider_count": tde.list_key_providers(scope="global"),
        "principal_key_name": tde.principal_key_name() or "",
        "test_table": _PERSIST_TEST_TABLE,
        "row_count": _PERSIST_ROW_COUNT,
        "data_digest": cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {_PERSIST_TEST_TABLE}"
        ),
    }
    payload.update(extras)
    return payload


def _populate_encrypted_table(cluster: PgCluster) -> None:
    """Idempotent: drops + recreates the test table with a deterministic
    payload so Verify's digest comparison is reproducible.
    """
    cluster.execute(f"DROP TABLE IF EXISTS {_PERSIST_TEST_TABLE}")
    cluster.execute(
        f"CREATE TABLE {_PERSIST_TEST_TABLE} (id INT PRIMARY KEY, payload TEXT) "
        f"USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO {_PERSIST_TEST_TABLE} "
        f"SELECT i, md5(i::text) FROM generate_series(1, {_PERSIST_ROW_COUNT}) i"
    )


# ── Phase 7: single-node staged Setup / Verify ────────────────────────────────


class TestPgTdeMinorUpgradeSetup:
    """
    Stage 1 (single-node): prepare a persistent PGDATA under the OLD
    pg_tde binary so the operator can perform the package upgrade and
    a later ``TestPgTdeMinorUpgradeVerify`` run can validate the state.

    Skips cleanly when ``--upgrade-data-dir`` / ``PG_TDE_UPGRADE_DATA_DIR``
    is not provided.

    This stage runs ONE monolithic test rather than per-step tests
    because the prep is a single transaction (initdb → configure →
    encrypt → record state → shutdown) — splitting it across tests
    would either duplicate setup or couple tests via order dependence.
    """

    def test_prepare_persistent_state_for_minor_upgrade(
        self,
        upgrade_data_dir: Optional[Path],
        install_dir: Path,
        io_method: str,
    ):
        """Initdb at ``<upgrade_data_dir>/single/pgdata`` under the OLD
        binaries, set up pg_tde end-to-end (provider, principal key,
        WAL encryption), create + populate an encrypted table, record
        the pre-upgrade invariants to ``upgrade_state.json``, and
        shut down cleanly. The operator should now perform the package
        upgrade before running ``TestPgTdeMinorUpgradeVerify``.
        """
        _skip_if_no_upgrade_dir(upgrade_data_dir)
        scenario_root = _scenario_root(upgrade_data_dir, "single")
        _reset_scenario_root(scenario_root)

        data_dir = scenario_root / "pgdata"
        socket_dir = scenario_root / "sock"
        socket_dir.mkdir(parents=True, exist_ok=True)
        keyfile = _persist_keyfile_path(scenario_root)

        cluster = PgCluster(
            data_dir,
            allocate_port(),
            install_dir,
            socket_dir=socket_dir,
            io_method=io_method,
        )
        cluster.initdb(extra_args=initdb_args_no_data_checksums(install_dir))
        cluster.write_default_config(extra_params=dict(_TDE_PARAMS))
        cluster.add_hba_entry("local all all trust")
        cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
        cluster.start()

        try:
            tde = TdeManager(cluster)
            tde.create_extension()
            tde.add_global_key_provider_file(keyfile=keyfile)
            tde.set_global_principal_key()
            tde.enable_wal_encryption()
            cluster.restart()

            _populate_encrypted_table(cluster)
            cluster.execute("CHECKPOINT")

            payload = _capture_pre_upgrade_state(
                cluster,
                scenario="single_node",
                install_dir=install_dir,
                data_dir=str(data_dir),
                socket_dir=str(socket_dir),
                keyfile=keyfile,
            )
            _write_state(scenario_root, payload)
        finally:
            try:
                if cluster.is_ready():
                    cluster.stop(check=False)
            except Exception:
                pass

        # Self-check: the state file is the contract Verify will consume,
        # so fail loud now if it didn't make it to disk.
        state_path = _state_path(scenario_root)
        assert state_path.exists(), f"state file not written: {state_path}"
        assert json.loads(state_path.read_text())["row_count"] == _PERSIST_ROW_COUNT


@pytest.fixture(scope="class")
def _verify_single_cluster(
    upgrade_data_dir, install_dir, io_method
) -> Generator[Tuple[PgCluster, Dict[str, Any]], None, None]:
    """Class-scoped fixture: attach to the Setup-prepared single-node
    PGDATA under the NEW binaries, return ``(cluster, state)``.

    The cluster is started once for the whole verify class and stopped
    at teardown. Per-test independence is preserved because each test
    asserts a different invariant against the cluster — none of them
    mutate it in ways that would affect another test's outcome (the
    ALTER EXTENSION test asserts both first-run and second-run
    behaviour in one method, so order independence is not relied on).
    """
    _skip_if_no_upgrade_dir(upgrade_data_dir)
    scenario_root = _scenario_root(upgrade_data_dir, "single")
    state = _read_state(scenario_root)
    if state.get("scenario") != "single_node":
        pytest.skip(
            f"state at {scenario_root} is for "
            f"{state.get('scenario')!r}, not single_node"
        )

    data_dir = Path(state["data_dir"])
    socket_dir = Path(state["socket_dir"])
    socket_dir.mkdir(parents=True, exist_ok=True)
    cluster = _bind_cluster_to_persistent_data_dir(
        install_dir, data_dir, socket_dir, io_method
    )
    cluster.start()
    cluster.wait_ready(timeout=90)
    try:
        yield cluster, state
    finally:
        try:
            if cluster.is_ready():
                cluster.stop(check=False)
        except Exception:
            pass


class TestPgTdeMinorUpgradeVerify:
    """
    Stage 2 (single-node): re-attach to the Setup-prepared PGDATA under
    the NEW pg_tde binary and validate every invariant captured in
    ``upgrade_state.json``.

    Skips cleanly when no Setup state is present at the persistent
    location.

    Each test pins down one specific contract:
      - the data dir + state file are well-formed
      - the cluster boots under the new binaries
      - encrypted rows decode before and after ALTER EXTENSION UPDATE
      - extversion advances (or stays put) consistently with the new
        binary's default_version
      - providers / principal key / WAL encryption are preserved
      - new writes work
      - the SQL migration is idempotent
    """

    def test_state_file_present_and_well_formed(
        self,
        upgrade_data_dir: Optional[Path],
        _verify_single_cluster,
    ):
        """``upgrade_state.json`` must exist with the schema Verify expects."""
        cluster, state = _verify_single_cluster
        required = {
            "scenario", "old_install_dir", "old_pg_tde_binary_version",
            "old_extversion", "wal_encrypt_on", "key_provider_count",
            "principal_key_name", "test_table", "row_count", "data_digest",
            "data_dir", "socket_dir", "keyfile",
        }
        missing = required - set(state.keys())
        assert not missing, f"state file is missing keys: {sorted(missing)}"

    def test_cluster_boots_under_new_binary(self, _verify_single_cluster):
        """The fixture already started the cluster; this test pins down
        that ``is_ready()`` returns True and the new binary reports a
        live ``pg_tde_version()``.
        """
        cluster, _state = _verify_single_cluster
        assert cluster.is_ready(), "cluster failed to start under NEW binary"
        bin_ver = (cluster.fetchone("SELECT pg_tde_version()") or "").strip()
        assert bin_ver, "pg_tde_version() returned empty on new binary"

    def test_encrypted_data_readable_before_alter_extension(
        self, _verify_single_cluster
    ):
        """Row count + digest match Setup's recorded values BEFORE
        ``ALTER EXTENSION pg_tde UPDATE`` runs — the on-disk encrypted
        heap is wire-compatible across the minor binary swap.
        """
        cluster, state = _verify_single_cluster
        count = cluster.fetchone(
            f"SELECT COUNT(*) FROM {state['test_table']}"
        )
        assert count == str(state["row_count"]), (
            f"row count under new binary: {count} (expected {state['row_count']})"
        )
        digest = cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {state['test_table']}"
        )
        assert digest == state["data_digest"], (
            "per-row digest changed across the binary upgrade — "
            "encrypted heap decoded to different plaintext on the "
            "new build (BEFORE ALTER EXTENSION UPDATE)."
        )

    def test_alter_extension_update_runs_cleanly(
        self, _verify_single_cluster
    ):
        """``ALTER EXTENSION pg_tde UPDATE`` must succeed under the new
        binary and the resulting ``extversion`` must be a prefix of
        ``pg_tde_version()``. The exact before/after string isn't
        hardcoded so any X.Y → A.B jump works.
        """
        cluster, state = _verify_single_cluster
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        ext_after = cluster.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        ) or ""
        bin_after = (cluster.fetchone("SELECT pg_tde_version()") or "").strip().split()[-1]
        assert bin_after.startswith(ext_after), (
            f"After ALTER EXTENSION pg_tde UPDATE, extversion ({ext_after!r}) "
            f"is not a prefix of binary version ({bin_after!r}). "
            f"Old binary reported {state['old_pg_tde_binary_version']!r}."
        )

    def test_encrypted_data_readable_after_alter_extension(
        self, _verify_single_cluster
    ):
        """Run ALTER EXTENSION UPDATE then re-check digest. The catalog
        migration must not rewrite relation key state or break decryption.
        """
        cluster, state = _verify_single_cluster
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        digest = cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {state['test_table']}"
        )
        assert digest == state["data_digest"], (
            "per-row digest changed AFTER ALTER EXTENSION pg_tde UPDATE — "
            "the catalog migration broke decryption."
        )

    def test_key_providers_preserved(self, _verify_single_cluster):
        """Global provider count and principal key name must equal the
        Setup-recorded values after ALTER EXTENSION UPDATE.
        """
        cluster, state = _verify_single_cluster
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        tde = TdeManager(cluster)
        providers_after = tde.list_key_providers(scope="global")
        key_after = tde.principal_key_name() or ""
        assert providers_after == state["key_provider_count"], (
            f"provider count diverged across minor upgrade: "
            f"{state['key_provider_count']} → {providers_after}"
        )
        assert key_after == state["principal_key_name"], (
            f"principal key name diverged across minor upgrade: "
            f"{state['principal_key_name']!r} → {key_after!r}"
        )

    def test_wal_encryption_still_active(self, _verify_single_cluster):
        """If Setup recorded WAL encryption as on, the new binary must
        keep it on after ALTER EXTENSION UPDATE.
        """
        cluster, state = _verify_single_cluster
        if not state.get("wal_encrypt_on"):
            pytest.skip("Setup did not enable WAL encryption; nothing to verify")
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        val = (cluster.fetchone("SHOW pg_tde.wal_encrypt") or "").lower()
        assert val in ("on", "true", "1", "yes"), (
            f"WAL encryption is off under new binary: {val!r}"
        )

    def test_new_writes_succeed_on_pre_upgrade_table(
        self, _verify_single_cluster
    ):
        """An INSERT into the pre-upgrade ``tde_heap`` table must succeed
        under the new binary and the rows must be encrypted.
        """
        cluster, state = _verify_single_cluster
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        cluster.execute(
            f"INSERT INTO {state['test_table']} "
            f"SELECT i, md5(i::text) FROM generate_series("
            f"{state['row_count'] + 1}, {state['row_count'] + 100}) i"
        )
        new_count = cluster.fetchone(
            f"SELECT COUNT(*) FROM {state['test_table']}"
        )
        assert new_count == str(state["row_count"] + 100), (
            f"post-upgrade INSERT lost rows: got {new_count}, "
            f"expected {state['row_count'] + 100}"
        )
        assert TdeManager(cluster).is_table_encrypted(state["test_table"]), (
            "tde_heap from pre-upgrade is no longer encrypted under new binary"
        )

    def test_alter_extension_update_idempotent(self, _verify_single_cluster):
        """A second ``ALTER EXTENSION pg_tde UPDATE`` must be a clean no-op
        that leaves ``extversion`` unchanged.
        """
        cluster, _state = _verify_single_cluster
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        ext_first = cluster.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        ext_second = cluster.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_first == ext_second, (
            f"ALTER EXTENSION pg_tde UPDATE not idempotent under new binary: "
            f"extversion {ext_first!r} → {ext_second!r} on second run"
        )


# ── Phase 8: HA staged Setup / Verify ─────────────────────────────────────────


def _ha_primary_dir(scenario_root: Path) -> Path:
    return scenario_root / "nodeA"


def _ha_replica_dir(scenario_root: Path) -> Path:
    return scenario_root / "nodeB"


class TestPgTdeMinorUpgradeSetupHA:
    """
    Stage 1 (HA): prepare a persistent two-node cluster under OLD
    pg_tde binaries. Both ``<upgrade_data_dir>/ha/nodeA`` (primary)
    and ``<upgrade_data_dir>/ha/nodeB`` (replica) are populated with
    streaming replication active and the same encrypted workload as
    the single-node case.
    """

    def test_prepare_persistent_ha_state_for_minor_upgrade(
        self,
        upgrade_data_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Bring up a TDE HA pair pointed at persistent nodeA/nodeB
        directories, populate, record per-node state into
        ``upgrade_state.json``, and shut both down cleanly.

        ``_build_ha_cluster`` is reused for the bring-up to share its
        battle-tested replica-from-basebackup logic; only the data
        dirs are then captured for persistence. Both nodes use the
        same persistent keyfile to mirror a real package upgrade
        where both hosts share the on-disk keyfile via storage or
        config management.
        """
        _skip_if_no_upgrade_dir(upgrade_data_dir)
        scenario_root = _scenario_root(upgrade_data_dir, "ha")
        _reset_scenario_root(scenario_root)

        # Real HA bring-up uses _build_ha_cluster which insists on
        # creating nodeA/nodeB under the caller-supplied tmp_path. We
        # let it do its thing in tmp_path and then move the prepared
        # data dirs (with the cluster stopped) into the persistent
        # location. This is cheaper than reimplementing the replica
        # basebackup logic from scratch.
        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, wal_encrypt=True
        )
        try:
            _populate_encrypted_table(nodeA)
            nodeA.execute("CHECKPOINT")
            ReplicationManager(nodeA, nodeB).assert_catchup(timeout=60)
            payload = _capture_pre_upgrade_state(
                nodeA,
                scenario="ha",
                install_dir=install_dir,
                primary_data_dir=str(_ha_primary_dir(scenario_root)),
                replica_data_dir=str(_ha_replica_dir(scenario_root)),
                socket_dir=str(scenario_root / "sock"),
                keyfile=str(scenario_root / _PERSIST_KEYFILE),
            )
        finally:
            for n in (nodeB, nodeA):
                try:
                    if n.is_ready():
                        n.stop(check=False)
                except Exception:
                    pass

        # Migrate the prepared data dirs (and the keyfile) into the
        # persistent location now that postgres is stopped on both nodes.
        (scenario_root / "sock").mkdir(parents=True, exist_ok=True)
        shutil.copytree(str(nodeA.data_dir), str(_ha_primary_dir(scenario_root)))
        shutil.copytree(str(nodeB.data_dir), str(_ha_replica_dir(scenario_root)))
        # _KEYFILE is at /tmp by default; copy the actual file too so the
        # operator can move the whole upgrade_data_dir around between hosts.
        src_keyfile = Path(_KEYFILE)
        if src_keyfile.exists():
            shutil.copy(str(src_keyfile), payload["keyfile"])

        _write_state(scenario_root, payload)
        assert _state_path(scenario_root).exists()


@pytest.fixture(scope="class")
def _verify_ha_pair(
    upgrade_data_dir, install_dir, io_method
) -> Generator[Tuple[PgCluster, PgCluster, Dict[str, Any]], None, None]:
    """Class-scoped fixture: attach the persistent nodeA / nodeB data
    dirs to NEW binaries, start both, wait for replication to be
    active, yield ``(primary, replica, state)``.
    """
    _skip_if_no_upgrade_dir(upgrade_data_dir)
    scenario_root = _scenario_root(upgrade_data_dir, "ha")
    state = _read_state(scenario_root)
    if state.get("scenario") != "ha":
        pytest.skip(
            f"state at {scenario_root} is for "
            f"{state.get('scenario')!r}, not ha"
        )

    socket_dir = Path(state["socket_dir"])
    socket_dir.mkdir(parents=True, exist_ok=True)

    primary = _bind_cluster_to_persistent_data_dir(
        install_dir,
        Path(state["primary_data_dir"]),
        socket_dir,
        io_method,
    )
    replica = _bind_cluster_to_persistent_data_dir(
        install_dir,
        Path(state["replica_data_dir"]),
        socket_dir,
        io_method,
        extra_params={"hot_standby": "on"},
    )
    # primary first so the replica can connect on start.
    primary.start()
    primary.wait_ready(timeout=90)
    replica.start()
    replica.wait_ready(timeout=90)

    # Give the wal sender a moment to register before tests hit it.
    deadline = time.time() + 30
    while time.time() < deadline:
        n = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        if n and int(n) >= 1:
            break
        time.sleep(1)

    try:
        yield primary, replica, state
    finally:
        for n in (replica, primary):
            try:
                if n.is_ready():
                    n.stop(check=False)
            except Exception:
                pass


class TestPgTdeMinorUpgradeVerifyHA:
    """
    Stage 2 (HA): re-attach both persistent nodes to NEW binaries,
    validate encrypted-data continuity, replication health, and that
    ``ALTER EXTENSION pg_tde UPDATE`` on the primary is replayed by
    the replica via WAL.
    """

    def test_ha_pair_boots_under_new_binary(self, _verify_ha_pair):
        """Both nodes must be live; primary is read-write, replica is
        in recovery and accepting connections.
        """
        primary, replica, _state = _verify_ha_pair
        assert primary.is_ready(), "primary failed to start under NEW binary"
        assert replica.is_ready(), "replica failed to start under NEW binary"
        assert primary.fetchone("SELECT pg_is_in_recovery()") == "f"
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "t"

    def test_replica_still_streams_from_primary_under_new_binary(
        self, _verify_ha_pair
    ):
        """``pg_stat_replication`` must show at least one connected
        standby — proves the wire protocol still works after the
        minor binary swap.
        """
        primary, _replica, _state = _verify_ha_pair
        n = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        assert n and int(n) >= 1, (
            f"replica not visible in pg_stat_replication: count={n!r}"
        )

    def test_encrypted_data_matches_setup_state_on_both_nodes(
        self, _verify_ha_pair
    ):
        """Row count + per-row digest captured by Setup must match
        BOTH the primary and the replica.
        """
        primary, replica, state = _verify_ha_pair
        for node, label in ((primary, "primary"), (replica, "replica")):
            count = node.fetchone(
                f"SELECT COUNT(*) FROM {state['test_table']}"
            )
            digest = node.fetchone(
                f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
                f"FROM {state['test_table']}"
            )
            assert count == str(state["row_count"]), (
                f"{label} row count diverged: {count} vs {state['row_count']}"
            )
            assert digest == state["data_digest"], (
                f"{label} per-row digest diverged after minor upgrade"
            )

    def test_alter_extension_update_on_primary_replays_to_replica(
        self, _verify_ha_pair
    ):
        """``ALTER EXTENSION pg_tde UPDATE`` on the primary advances
        ``extversion``; the standby replays the catalog change via
        WAL and ends up at the same ``extversion`` without ALTER
        being run on it directly.
        """
        primary, replica, _state = _verify_ha_pair
        primary.execute("ALTER EXTENSION pg_tde UPDATE")
        # Force the change into a flushed segment so the replica can
        # replay it before we read.
        primary.execute("SELECT pg_switch_wal()")
        ReplicationManager(primary, replica).assert_catchup(timeout=30)

        ext_primary = primary.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        ext_replica = replica.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_primary == ext_replica, (
            f"extversion divergence after ALTER EXTENSION on primary: "
            f"primary={ext_primary!r}, replica={ext_replica!r}"
        )

    def test_wal_encryption_and_provider_state_intact_on_ha(
        self, _verify_ha_pair
    ):
        """WAL encryption stays on on BOTH nodes; provider count and
        principal key name on the primary still match Setup's record.
        """
        primary, replica, state = _verify_ha_pair
        primary.execute("ALTER EXTENSION pg_tde UPDATE")

        if state.get("wal_encrypt_on"):
            for node, label in ((primary, "primary"), (replica, "replica")):
                val = (node.fetchone("SHOW pg_tde.wal_encrypt") or "").lower()
                assert val in ("on", "true", "1", "yes"), (
                    f"WAL encryption is off on {label} after minor upgrade"
                )

        tde = TdeManager(primary)
        assert tde.list_key_providers(scope="global") == state["key_provider_count"]
        assert (tde.principal_key_name() or "") == state["principal_key_name"]
