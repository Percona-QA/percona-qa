"""Test-level fixtures: ready-to-use cluster objects for every test module."""
import shutil
import time
from pathlib import Path
from typing import Generator, List, Tuple

import pytest

from conftest import allocate_port
from lib import PgCluster, TdeManager, ReplicationManager


# ── internal helper ───────────────────────────────────────────────────────────

def _dump_logs_on_failure(request, clusters: List[PgCluster]) -> None:
    """Print server logs for every cluster when the test has failed or errored."""
    rep = getattr(request.node, "rep_call", None)
    if rep is None or rep.passed:
        return
    for c in clusters:
        log_text = c.read_log(last_n=40)
        if not log_text:
            continue
        sep = "─" * 70
        print(f"\n{sep}")
        print(f"  PostgreSQL server log │ {c.data_dir.name}  port={c.port}")
        print(sep)
        print(log_text)
        print(sep)


# ── factory fixture ───────────────────────────────────────────────────────────


@pytest.fixture
def pg_factory(install_dir: Path, tmp_path: Path, io_method: str, request):
    """
    Factory that creates isolated PgCluster instances for a test.
    All clusters are stopped and their data directories removed on teardown.
    Server logs for every cluster are printed automatically on failure.
    """
    clusters: List[PgCluster] = []

    def _make(
        name: str = "pg",
        port: int = None,
        socket_dir: Path = None,
    ) -> PgCluster:
        port = port or allocate_port()
        data_dir = tmp_path / name
        sock = socket_dir or tmp_path
        cluster = PgCluster(data_dir, port, install_dir, socket_dir=sock, io_method=io_method)
        clusters.append(cluster)
        return cluster

    yield _make

    _dump_logs_on_failure(request, clusters)

    for c in clusters:
        try:
            if c.is_ready():
                c.stop(check=False)
        except Exception:
            pass
        shutil.rmtree(c.data_dir, ignore_errors=True)


# ── single-cluster fixtures ───────────────────────────────────────────────────


@pytest.fixture
def primary_cluster(pg_factory) -> Generator[PgCluster, None, None]:
    """A started, plain PostgreSQL primary cluster."""
    cluster = pg_factory("primary")
    cluster.initdb()
    cluster.write_default_config("primary")
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.start()
    yield cluster


@pytest.fixture
def tde_primary(pg_factory) -> Generator[PgCluster, None, None]:
    """A primary cluster with pg_tde fully set up (file key provider)."""
    cluster = pg_factory("tde_primary")
    cluster.initdb(extra_args=["--no-data-checksums"])
    cluster.write_default_config("primary")
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")

    tde = TdeManager(cluster)
    tde.enable_preload()
    tde.enable_tde_heap()
    cluster.start()
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    yield cluster


# ── primary + replica pair ────────────────────────────────────────────────────


@pytest.fixture
def replica_pair(pg_factory) -> Generator[Tuple[PgCluster, PgCluster], None, None]:
    """Plain streaming replication pair (primary, standby)."""
    primary = pg_factory("primary")
    standby = pg_factory("standby")

    primary.initdb()
    primary.write_default_config("primary")
    primary.configure({"wal_level": "replica", "max_wal_senders": "5", "hot_standby": "on"})
    primary.add_hba_entry("local all all trust")
    primary.add_hba_entry("local replication all trust")
    primary.add_hba_entry("host  all all 127.0.0.1/32 trust")
    primary.add_hba_entry("host  replication all 127.0.0.1/32 trust")
    primary.start()

    repl = ReplicationManager(primary, standby)
    repl.create_standby_from_backup()
    standby.write_default_config("replica")
    standby.start()
    standby.wait_ready()

    # wait_ready() only checks TCP; also wait for WAL sender to appear
    deadline = time.time() + 30
    while time.time() < deadline:
        count = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        if count and int(count) >= 1:
            break
        time.sleep(1)

    yield primary, standby


@pytest.fixture
def tde_replica_pair(pg_factory) -> Generator[Tuple[PgCluster, PgCluster], None, None]:
    """Streaming replication pair with pg_tde enabled on both nodes."""
    primary = pg_factory("tde_primary")
    standby = pg_factory("tde_standby")

    primary.initdb(extra_args=["--no-data-checksums"])
    primary.write_default_config("primary")
    primary.configure({"wal_level": "replica", "max_wal_senders": "5", "hot_standby": "on"})
    primary.add_hba_entry("local all all trust")
    primary.add_hba_entry("local replication all trust")
    primary.add_hba_entry("host  all all 127.0.0.1/32 trust")
    primary.add_hba_entry("host  replication all 127.0.0.1/32 trust")

    tde = TdeManager(primary)
    tde.enable_preload()
    tde.enable_tde_heap()
    primary.start()
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()

    repl = ReplicationManager(primary, standby)
    repl.create_standby_from_backup(use_tde_basebackup=True)
    standby.write_default_config("replica")
    standby.start()
    standby.wait_ready()

    # wait_ready() only checks TCP; also wait for WAL sender to appear
    deadline = time.time() + 30
    while time.time() < deadline:
        count = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        if count and int(count) >= 1:
            break
        time.sleep(1)

    yield primary, standby
