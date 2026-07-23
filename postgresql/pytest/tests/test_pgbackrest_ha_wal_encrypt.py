"""
Patroni-like 3-node HA + pg_tde.wal_encrypt + pgBackRest restore regression.

Approximates a Patroni 3-node cluster (no Patroni dependency) for the
customer failure mode:

  1. Bootstrap primary + 2 streaming replicas
  2. Enable pg_tde + pg_tde.wal_encrypt
  3. Create an encrypted database and write data
  4. CHECKPOINT; pg_switch_wal(); wait past archive_timeout
  5. pgBackRest full backup
  6. Restore the full backup (primary comes up)
  7. Replicas that keep pre-restore PGDATA fail with:
       - invalid magic number … in WAL segment …
       - requested WAL segment … has already been removed

The correct recovery path after restoring the primary is to reinitialize
replicas with ``pg_tde_basebackup`` (Patroni ``reinit``), not to restart
stale standby data directories against the restored primary.
"""
from __future__ import annotations

import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List

import pytest

from conftest import allocate_port
from lib import BackupManager, PgCluster, ReplicationManager, TdeManager
from lib.cluster import initdb_args_no_data_checksums

pytestmark = [pytest.mark.backup, pytest.mark.pgbackrest, pytest.mark.slow]

_ARCHIVE_TIMEOUT_S = 5

_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

# Standbys must not undercut primary hot-standby GUCs or recovery aborts
# ("max_wal_senders = 5 is a lower setting than on the primary … 10").
_HA_REPLICA_PARAMS: Dict[str, str] = {
    **_TDE_PARAMS,
    "max_wal_senders": "10",
    "max_replication_slots": "10",
}

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

_REPLICA_FAIL_MARKERS = (
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


def _strip_restored_auto_conf_socket_overrides(data_dir: Path) -> None:
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
        if key in _AUTO_CONF_OVERRIDE_KEYS:
            continue
        out_lines.append(line)
    auto.write_text("\n".join(out_lines) + ("\n" if out_lines else ""))


def _start_restored_primary_cluster(
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
    cluster.write_default_config("primary", extra_params=_TDE_PARAMS)
    _strip_restored_auto_conf_socket_overrides(restore_dir)
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


def _wait_for_n_streaming(primary: PgCluster, n: int, timeout: int = 90) -> None:
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


def _configure_replication_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _bootstrap_3node_wal_encrypt_pgbackrest(
    pg_factory,
    tmp_path: Path,
) -> HaClusterState:
    """Patroni-equivalent bootstrap used by both the positive and negative tests."""
    primary = pg_factory("ha_primary")
    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(
        "primary",
        extra_params={
            **_TDE_PARAMS,
            "wal_level": "replica",
            "max_wal_senders": "10",
            "hot_standby": "on",
            "wal_keep_size": "'64MB'",
        },
    )
    _configure_replication_hba(primary)
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
    primary.configure({"archive_timeout": f"'{_ARCHIVE_TIMEOUT_S}s'"})
    primary.restart()
    bm.stanza_create()

    replicas: List[PgCluster] = []
    for name in ("ha_replica1", "ha_replica2"):
        standby = pg_factory(name)
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_HA_REPLICA_PARAMS)
        standby.start()
        replicas.append(standby)

    _wait_for_n_streaming(primary, n=2)

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
    time.sleep(_ARCHIVE_TIMEOUT_S)
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


def _stop_ha_nodes(state: HaClusterState) -> None:
    for replica in state.replicas:
        replica.stop(check=False)
    state.primary.stop(check=False)


def _start_restored_primary(
    state: HaClusterState,
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
) -> PgCluster:
    state.backup.restore(str(restore_dir), pg_tde_wal_restore=True)
    restored = _start_restored_primary_cluster(
        restore_dir, install_dir, socket_dir, io_method,
    )
    _configure_replication_hba(restored)
    restored.configure(
        {
            "wal_level": "replica",
            "max_wal_senders": "10",
            "hot_standby": "on",
        }
    )
    _strip_restored_auto_conf_socket_overrides(restore_dir)
    restored.restart()
    restored.wait_ready(timeout=120)
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
        state = _bootstrap_3node_wal_encrypt_pgbackrest(pg_factory, tmp_path)
        _stop_ha_nodes(state)

        restored = _start_restored_primary(
            state, tmp_path / "restore_primary", install_dir, tmp_path, io_method,
        )
        try:
            fresh: List[PgCluster] = []
            for name in ("ha_reinit1", "ha_reinit2"):
                standby = pg_factory(name)
                repl = ReplicationManager(restored, standby)
                repl.create_standby_from_backup(use_tde_basebackup=True)
                standby.write_default_config("replica", extra_params=_HA_REPLICA_PARAMS)
                standby.start()
                fresh.append(standby)

            _wait_for_n_streaming(restored, n=2)
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
                for marker in _REPLICA_FAIL_MARKERS:
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
        state = _bootstrap_3node_wal_encrypt_pgbackrest(pg_factory, tmp_path)

        stale_copies: List[Path] = []
        for i, replica in enumerate(state.replicas):
            replica.stop(check=False)
            frozen = tmp_path / f"stale_replica{i + 1}"
            shutil.copytree(replica.data_dir, frozen)
            stale_copies.append(frozen)

        state.primary.stop(check=False)

        restored = _start_restored_primary(
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
                standby.write_default_config("replica", extra_params=_HA_REPLICA_PARAMS)
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
                if not any(m in log_l for m in _REPLICA_FAIL_MARKERS):
                    failures.append(
                        f"stale replica {standby.data_dir.name} did not log "
                        f"expected failure markers {_REPLICA_FAIL_MARKERS}; "
                        f"log was:\n{log_text}"
                    )
                standby.stop(check=False)
        finally:
            restored.stop(check=False)

        assert not failures, "\n\n".join(failures)
