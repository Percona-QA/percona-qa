"""
pg_tde extension minor-version upgrade tests.

Scope
─────
"Minor upgrade" here means an operator-driven, **in-place** package
upgrade of the pg_tde extension on the **same** PostgreSQL major version
(e.g. pg_tde 2.1.2 → 2.2.0 at ``/usr/pgsql-18`` with the same data dir).

This is **not** a PG major upgrade (17 → 18). For that path see
``tests/test_tde_pg_upgrade.py``, which runs ``pg_upgrade`` and then
``ALTER EXTENSION pg_tde UPDATE`` on the new cluster when the source had
pg_tde 2.1.x and the target ships 2.2.x.

PG-2381 (empty smgr key files / slots after ``VACUUM FULL`` / ``DROP TABLE``)
is covered in ``TestPg2381EmptyKeyMigration`` and staged ``single_pg2381`` here.

Staged Verify tests here (``TestPgTdeMinorUpgradeVerify*``) run the same
``ALTER EXTENSION pg_tde UPDATE`` step after the operator replaces the
package — that is the 2.1 → 2.2 catalog migration for in-place minor upgrades.

Runbook: ``docs/minor_upgrade.md`` (Setup → package upgrade → Verify).
"""

import json
import shutil
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
from lib.cluster import initdb_args_no_data_checksums

# Do not use pytest.mark.upgrade here: conftest skips ``upgrade`` tests when
# ``--old-install-dir`` is unset (major pg_upgrade). Staged Setup/Verify classes
# use ``pytest.mark.minor_upgrade`` and require ``--upgrade-data-dir`` instead.
pytestmark = [pytest.mark.encryption, pytest.mark.slow]

# ── constants ─────────────────────────────────────────────────────────────────

_KEYFILE = "/tmp/tde_minor_upgrade_test.per"

_TDE_PARAMS = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
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
    """
    nodeA = PgCluster(
        tmp_path / "nodeA", allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
    )
    nodeB = PgCluster(
        tmp_path / "nodeB", allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
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
        nodeB.configure({"restore_command": restore_cmd})

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
    # Guarantee WAL activity so pg_switch_wal() never returns NULL on an
    # otherwise idle cluster.
    node.execute(
        "CREATE TABLE IF NOT EXISTS _force_wal (id INT); "
        "INSERT INTO _force_wal VALUES (1);"
    )
    closed = (node.fetchone("SELECT pg_walfile_name(pg_switch_wal())") or "").strip()
    assert closed, "pg_switch_wal() did not return a segment name"

    deadline = time.time() + timeout
    while time.time() < deadline:
        if (archive_dir / closed).exists():
            return closed
        time.sleep(0.5)

    raise AssertionError(
        f"WAL segment {closed!r} was not archived to {archive_dir} within "
        f"{timeout}s."
    )


# ── Phase 0: pre-conditions ───────────────────────────────────────────────────


class TestTdeMinorUpgradePreConditions:

    def test_catalog_version_vs_binary_version(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            ext_ver = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            bin_ver = nodeA.fetchone("SELECT pg_tde_version()")
            assert ext_ver is not None, "pg_tde extension not installed"
            assert bin_ver is not None, "pg_tde_version() returned NULL"

            bin_ver_clean = bin_ver.strip().split()[-1]
            assert bin_ver_clean.startswith(ext_ver), (
                f"Catalog version '{ext_ver}' is not a prefix of binary "
                f"version '{bin_ver_clean}'."
            )
        finally:
            _teardown_pair(nodeA, nodeB)

    def test_wal_encryption_active_on_both_nodes(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            for node, _name in ((nodeA, "nodeA"), (nodeB, "nodeB")):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes")
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 1: ALTER EXTENSION safety ──────────────────────────────────────────


class TestAlterExtensionUpdate:

    def test_alter_extension_update_safety_and_idempotency(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Consolidated check ensuring ALTER EXTENSION pg_tde UPDATE is safe,
        idempotent, and preserves critical settings like key providers and
        WAL encryption.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            tde = TdeManager(nodeA)
            count_before = tde.list_key_providers(scope="global")
            key_before = tde.principal_key_name()
            ver_before = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )

            nodeA.execute(
                "CREATE TABLE app_data (id INT, secret TEXT) USING tde_heap; "
                "INSERT INTO app_data "
                "SELECT i, md5(i::text) FROM generate_series(1,500) i;"
            )

            # Execution 1
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")

            # Execution 2 (idempotency)
            nodeA.execute("ALTER EXTENSION pg_tde UPDATE")

            ver_after = nodeA.fetchone(
                "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
            )
            assert ver_before == ver_after, (
                "Extversion changed unexpectedly on same binary"
            )

            count_after = tde.list_key_providers(scope="global")
            key_after = tde.principal_key_name()
            assert count_after == count_before
            assert key_after == key_before

            val = nodeA.fetchone("SHOW pg_tde.wal_encrypt")
            assert val in ("on", "true", "1", "yes")

            row_count = nodeA.fetchone("SELECT COUNT(*) FROM app_data")
            assert row_count == "500", "Catalog migration broke decryption."

        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 2: rolling restart ──────────────────────────────────────────────────


class TestRollingRestart:

    def test_rolling_restart_preserves_cluster_state(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Validates Patroni-style rolling upgrade ordering keeps data intact.
        Replica restarts → leader restarts → encryption and replication
        verified.
        """
        nodeA, nodeB = _build_ha_cluster(tmp_path, install_dir, io_method)
        try:
            nodeA.execute(
                "CREATE TABLE rolling_test (id INT) USING tde_heap; "
                "INSERT INTO rolling_test SELECT generate_series(1,50);"
            )
            repl = ReplicationManager(nodeA, nodeB)
            repl.assert_catchup(timeout=30)

            # Step 1: restart nodeB (replica) first.
            nodeB.stop()
            nodeA.execute("INSERT INTO rolling_test SELECT generate_series(51, 100);")
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            repl.assert_catchup(timeout=60)

            # Step 2: restart nodeA (leader).
            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            nodeA.execute("INSERT INTO rolling_test SELECT generate_series(101, 150);")
            repl.assert_catchup(timeout=60)
            repl.assert_row_counts_match("rolling_test")

            for node in (nodeA, nodeB):
                val = node.fetchone("SHOW pg_tde.wal_encrypt")
                assert val in ("on", "true", "1", "yes")

        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 3: WAL archiving continuity ────────────────────────────────────────


class TestWalArchivingContinuity:

    def test_pitr_from_archive_works_after_rolling_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
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
            _force_switch_and_wait_archived(nodeA, archive_dir, timeout=30)

            nodeA.stop()
            restore_dir = tmp_path / "pitr_restore"
            shutil.copytree(str(nodeA.data_dir), str(restore_dir))
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            pitr_time = nodeA.fetchone("SELECT now()")
            time.sleep(1)

            nodeB.stop()
            nodeB.start()
            nodeB.wait_ready(timeout=60)

            nodeA.stop()
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            nodeA.execute("DELETE FROM pitr_target")
            _force_switch_and_wait_archived(nodeA, archive_dir, timeout=30)
            nodeA.stop()

            restored = PgCluster(
                restore_dir, allocate_port(), install_dir,
                socket_dir=tmp_path, io_method=io_method,
            )
            restored.write_default_config(extra_params=_TDE_PARAMS)
            auto_conf = restore_dir / "postgresql.auto.conf"
            with auto_conf.open("a") as f:
                f.write(f"recovery_target_time = '{pitr_time}'\n")
                f.write("recovery_target_action = 'promote'\n")
                f.write(restore_conf_line_raw(
                    archive_dir, install_dir, use_tde_wrappers=True
                ))

            (restore_dir / "recovery.signal").touch()
            restored.add_hba_entry("local all all trust")
            restored.start()
            restored.wait_ready(timeout=90)

            count = restored.fetchone("SELECT COUNT(*) FROM pitr_target")
            assert count == "1"
            restored.stop()
        finally:
            _teardown_pair(nodeA, nodeB)


# ── Phase 5 & 6: staged Setup / Verify flow ───────────────────────────────────

_STATE_FILENAME = "upgrade_state.json"
_PERSIST_KEYFILE = "keyfile.per"
_PERSIST_TEST_TABLE = "staged_minor_upgrade"
_PERSIST_ROW_COUNT = 500


def _skip_if_no_upgrade_dir(upgrade_data_dir: Optional[Path]) -> None:
    if upgrade_data_dir is None:
        pytest.skip("--upgrade-data-dir not provided")


def _scenario_root(upgrade_data_dir: Path, scenario: str) -> Path:
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
        pytest.skip(f"No staged Setup state at {path!s}")
    return json.loads(path.read_text())


def _reset_scenario_root(scenario_root: Path) -> None:
    if scenario_root.exists():
        shutil.rmtree(scenario_root)
    scenario_root.mkdir(parents=True, exist_ok=True)


def _persist_keyfile_path(scenario_root: Path) -> str:
    return str(scenario_root / _PERSIST_KEYFILE)


def _bind_cluster_to_persistent_data_dir(
    install_dir: Path,
    data_dir: Path,
    socket_dir: Path,
    io_method: str,
    *,
    extra_params: Optional[Dict[str, str]] = None,
) -> PgCluster:
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
    tde = TdeManager(cluster)
    extra = dict(extras)
    churn_table = extra.pop("churn_table", None)
    churn_expected_id = extra.pop("churn_expected_id", None)

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
    }
    if churn_table:
        payload["churn_table"] = churn_table
        payload["churn_expected_id"] = churn_expected_id or "2"
    else:
        payload["test_table"] = _PERSIST_TEST_TABLE
        payload["row_count"] = _PERSIST_ROW_COUNT
        payload["data_digest"] = cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {_PERSIST_TEST_TABLE}"
        )
    payload.update(extra)
    return payload


def _populate_encrypted_table(cluster: PgCluster) -> None:
    cluster.execute(f"DROP TABLE IF EXISTS {_PERSIST_TEST_TABLE}")
    cluster.execute(
        f"CREATE TABLE {_PERSIST_TEST_TABLE} (id INT PRIMARY KEY, payload TEXT) "
        f"USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO {_PERSIST_TEST_TABLE} "
        f"SELECT i, md5(i::text) FROM generate_series(1, {_PERSIST_ROW_COUNT}) i"
    )


def _populate_pg2381_churn_table(cluster: PgCluster) -> None:
    """
    PG-2381 repro churn on ``pg2381_churn_t`` (drop/recreate + ``VACUUM FULL``).

    https://github.com/percona/pg_tde/pull/582
    """
    table = "pg2381_churn_t"
    cluster.execute(f"DROP TABLE IF EXISTS {table}")
    cluster.execute(f"CREATE TABLE {table} (id INT PRIMARY KEY) USING tde_heap")
    cluster.execute(f"INSERT INTO {table} VALUES (1)")
    cluster.execute(f"DROP TABLE {table}")
    cluster.execute(f"CREATE TABLE {table} (id INT PRIMARY KEY) USING tde_heap")
    cluster.execute(f"INSERT INTO {table} VALUES (2)")
    cluster.execute("VACUUM FULL")


# ── Phase 7: single-node staged Setup / Verify ────────────────────────────────


@pytest.mark.minor_upgrade
class TestPgTdeMinorUpgradeSetup:

    def test_prepare_persistent_state_for_minor_upgrade(
        self,
        upgrade_data_dir: Optional[Path],
        install_dir: Path,
        io_method: str,
    ):
        _skip_if_no_upgrade_dir(upgrade_data_dir)
        scenario_root = _scenario_root(upgrade_data_dir, "single")
        _reset_scenario_root(scenario_root)

        data_dir = scenario_root / "pgdata"
        socket_dir = scenario_root / "sock"
        socket_dir.mkdir(parents=True, exist_ok=True)
        keyfile = _persist_keyfile_path(scenario_root)

        cluster = PgCluster(
            data_dir, allocate_port(), install_dir,
            socket_dir=socket_dir, io_method=io_method,
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
                cluster, scenario="single_node", install_dir=install_dir,
                data_dir=str(data_dir), socket_dir=str(socket_dir),
                keyfile=keyfile,
            )
            _write_state(scenario_root, payload)
        finally:
            try:
                if cluster.is_ready():
                    cluster.stop(check=False)
            except Exception:
                pass


@pytest.mark.minor_upgrade
class TestPg2381MinorUpgradeSetup:
    """Staged Setup for PG-2381 churn; opt-in via ``--with-pg2381`` / explicit pytest path."""

    def test_prepare_pg2381_churn_for_minor_upgrade(
        self,
        upgrade_data_dir: Optional[Path],
        install_dir: Path,
        io_method: str,
    ):
        """
        Staged Setup: PG-2381 churn (``VACUUM FULL`` + drop/recreate) on pg_tde 2.1.

        Run Verify after swapping to pg_tde 2.2 packages on the **same** PG major
        (``--upgrade-data-dir`` + ``test_verify_pg2381_churn_after_minor_upgrade``).
        """
        _skip_if_no_upgrade_dir(upgrade_data_dir)
        scenario_root = _scenario_root(upgrade_data_dir, "single_pg2381")
        _reset_scenario_root(scenario_root)

        data_dir = scenario_root / "pgdata"
        socket_dir = scenario_root / "sock"
        socket_dir.mkdir(parents=True, exist_ok=True)
        keyfile = _persist_keyfile_path(scenario_root)

        cluster = PgCluster(
            data_dir, allocate_port(), install_dir,
            socket_dir=socket_dir, io_method=io_method,
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
            _populate_pg2381_churn_table(cluster)
            assert cluster.fetchone("SELECT id FROM pg2381_churn_t") == "2"

            payload = _capture_pre_upgrade_state(
                cluster,
                scenario="single_pg2381",
                install_dir=install_dir,
                data_dir=str(data_dir),
                socket_dir=str(socket_dir),
                keyfile=keyfile,
                churn_table="pg2381_churn_t",
                churn_expected_id="2",
            )
            _write_state(scenario_root, payload)
        finally:
            try:
                if cluster.is_ready():
                    cluster.stop(check=False)
            except Exception:
                pass


@pytest.fixture(scope="class")
def _verify_single_cluster(
    upgrade_data_dir, install_dir, io_method
) -> Generator[Tuple[PgCluster, Dict[str, Any]], None, None]:
    _skip_if_no_upgrade_dir(upgrade_data_dir)
    scenario_root = _scenario_root(upgrade_data_dir, "single")
    state = _read_state(scenario_root)
    if state.get("scenario") != "single_node":
        pytest.skip("State is not for single_node")

    socket_dir = Path(state["socket_dir"])
    socket_dir.mkdir(parents=True, exist_ok=True)
    cluster = _bind_cluster_to_persistent_data_dir(
        install_dir, Path(state["data_dir"]), socket_dir, io_method
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


@pytest.mark.minor_upgrade
class TestPgTdeMinorUpgradeVerify:

    def test_minor_upgrade_verification_flow(self, _verify_single_cluster):
        """
        Consolidated sequential execution guarantees pytest doesn't break
        dependencies.
        Validates: boot → data check → ALTER EXTENSION → post-alter check
        → new data.
        """
        cluster, state = _verify_single_cluster

        # 1. Boot verification.
        assert cluster.is_ready()
        bin_ver = (cluster.fetchone("SELECT pg_tde_version()") or "").strip()
        assert bin_ver

        # 2. Data is readable BEFORE ALTER EXTENSION UPDATE.
        count = cluster.fetchone(f"SELECT COUNT(*) FROM {state['test_table']}")
        assert count == str(state["row_count"])

        digest = cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {state['test_table']}"
        )
        assert digest == state["data_digest"]

        # 3. Perform the upgrade migration.
        cluster.execute("ALTER EXTENSION pg_tde UPDATE")

        # 4. Check migration state.
        ext_after = cluster.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        ) or ""
        bin_after = bin_ver.split()[-1]
        assert bin_after.startswith(ext_after)

        # 5. Data remains readable AFTER migration.
        digest_after = cluster.fetchone(
            f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
            f"FROM {state['test_table']}"
        )
        assert digest_after == state["data_digest"]

        # 6. Global state preserved.
        tde = TdeManager(cluster)
        assert tde.list_key_providers(scope="global") == state["key_provider_count"]
        assert tde.principal_key_name() == state["principal_key_name"]

        if state.get("wal_encrypt_on"):
            val = (cluster.fetchone("SHOW pg_tde.wal_encrypt") or "").lower()
            assert val in ("on", "true", "1", "yes")

        # 7. New writes succeed.
        cluster.execute(
            f"INSERT INTO {state['test_table']} "
            f"SELECT i, md5(i::text) FROM generate_series("
            f"{state['row_count'] + 1}, {state['row_count'] + 100}) i"
        )
        new_count = cluster.fetchone(
            f"SELECT COUNT(*) FROM {state['test_table']}"
        )
        assert new_count == str(state["row_count"] + 100)


@pytest.fixture(scope="class")
def _verify_pg2381_cluster(
    upgrade_data_dir, install_dir, io_method
) -> Generator[Tuple[PgCluster, Dict[str, Any]], None, None]:
    _skip_if_no_upgrade_dir(upgrade_data_dir)
    scenario_root = _scenario_root(upgrade_data_dir, "single_pg2381")
    state = _read_state(scenario_root)
    if state.get("scenario") != "single_pg2381":
        pytest.skip("State is not for single_pg2381 (run Setup PG-2381 test first)")

    socket_dir = Path(state["socket_dir"])
    socket_dir.mkdir(parents=True, exist_ok=True)
    cluster = _bind_cluster_to_persistent_data_dir(
        install_dir, Path(state["data_dir"]), socket_dir, io_method
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


@pytest.mark.minor_upgrade
class TestPg2381MinorUpgradeVerify:
    """Staged Verify for PG-2381 after in-place pg_tde 2.1→2.2 package swap."""

    def test_verify_pg2381_churn_after_minor_upgrade(self, _verify_pg2381_cluster):
        cluster, state = _verify_pg2381_cluster
        churn_table = state.get("churn_table", "pg2381_churn_t")
        expected_id = state.get("churn_expected_id", "2")

        assert cluster.fetchone(f"SELECT id FROM {churn_table}") == expected_id

        cluster.execute("ALTER EXTENSION pg_tde UPDATE")

        assert cluster.fetchone(f"SELECT id FROM {churn_table}") == expected_id

        cluster.execute(
            f"INSERT INTO {churn_table} (id) VALUES (99) ON CONFLICT (id) DO NOTHING"
        )
        assert cluster.fetchone(f"SELECT id FROM {churn_table} WHERE id = 99") == "99"


# ── Phase 8: HA staged Setup / Verify ─────────────────────────────────────────


def _ha_primary_dir(scenario_root: Path) -> Path:
    return scenario_root / "nodeA"


def _ha_replica_dir(scenario_root: Path) -> Path:
    return scenario_root / "nodeB"


@pytest.mark.minor_upgrade
class TestPgTdeMinorUpgradeSetupHA:

    def test_prepare_persistent_ha_state_for_minor_upgrade(
        self,
        upgrade_data_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        _skip_if_no_upgrade_dir(upgrade_data_dir)
        scenario_root = _scenario_root(upgrade_data_dir, "ha")
        _reset_scenario_root(scenario_root)

        nodeA, nodeB = _build_ha_cluster(
            tmp_path, install_dir, io_method, wal_encrypt=True
        )
        try:
            _populate_encrypted_table(nodeA)
            nodeA.execute("CHECKPOINT")
            ReplicationManager(nodeA, nodeB).assert_catchup(timeout=60)

            payload = _capture_pre_upgrade_state(
                nodeA, scenario="ha", install_dir=install_dir,
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

        (scenario_root / "sock").mkdir(parents=True, exist_ok=True)
        shutil.copytree(str(nodeA.data_dir), str(_ha_primary_dir(scenario_root)))
        shutil.copytree(str(nodeB.data_dir), str(_ha_replica_dir(scenario_root)))

        src_keyfile = Path(_KEYFILE)
        if src_keyfile.exists():
            shutil.copy(str(src_keyfile), payload["keyfile"])

        _write_state(scenario_root, payload)


@pytest.fixture(scope="class")
def _verify_ha_pair(
    upgrade_data_dir, install_dir, io_method
) -> Generator[Tuple[PgCluster, PgCluster, Dict[str, Any]], None, None]:
    _skip_if_no_upgrade_dir(upgrade_data_dir)
    scenario_root = _scenario_root(upgrade_data_dir, "ha")
    state = _read_state(scenario_root)
    if state.get("scenario") != "ha":
        pytest.skip("State is not for HA")

    socket_dir = Path(state["socket_dir"])
    socket_dir.mkdir(parents=True, exist_ok=True)

    primary = _bind_cluster_to_persistent_data_dir(
        install_dir, Path(state["primary_data_dir"]), socket_dir, io_method,
    )
    replica = _bind_cluster_to_persistent_data_dir(
        install_dir, Path(state["replica_data_dir"]), socket_dir, io_method,
        extra_params={"hot_standby": "on"},
    )

    primary.start()
    primary.wait_ready(timeout=90)
    replica.start()
    replica.wait_ready(timeout=90)

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


@pytest.mark.minor_upgrade
class TestPgTdeMinorUpgradeVerifyHA:

    def test_ha_minor_upgrade_verification_flow(self, _verify_ha_pair):
        """
        Consolidated sequential execution for HA testing to prevent
        dependency breaking.
        """
        primary, replica, state = _verify_ha_pair

        # 1. Role state.
        assert primary.is_ready() and replica.is_ready()
        assert primary.fetchone("SELECT pg_is_in_recovery()") == "f"
        assert replica.fetchone("SELECT pg_is_in_recovery()") == "t"

        n = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        assert n and int(n) >= 1

        # 2. Data verification BEFORE update.
        for node in (primary, replica):
            count = node.fetchone(f"SELECT COUNT(*) FROM {state['test_table']}")
            digest = node.fetchone(
                f"SELECT md5(string_agg(payload, ',' ORDER BY id)) "
                f"FROM {state['test_table']}"
            )
            assert count == str(state["row_count"])
            assert digest == state["data_digest"]

        # 3. Perform migration and replicate.
        primary.execute("ALTER EXTENSION pg_tde UPDATE")
        primary.execute("SELECT pg_switch_wal()")
        ReplicationManager(primary, replica).assert_catchup(timeout=30)

        # 4. Extension synced via WAL.
        ext_primary = primary.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        ext_replica = replica.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_primary == ext_replica

        # 5. Encryption params verification.
        if state.get("wal_encrypt_on"):
            for node in (primary, replica):
                val = (node.fetchone("SHOW pg_tde.wal_encrypt") or "").lower()
                assert val in ("on", "true", "1", "yes")

        tde = TdeManager(primary)
        assert tde.list_key_providers(scope="global") == state["key_provider_count"]
        assert tde.principal_key_name() == state["principal_key_name"]
