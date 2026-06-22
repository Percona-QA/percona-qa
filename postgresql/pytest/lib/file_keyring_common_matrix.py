"""Shared file keyring scenarios (no external server)."""
from __future__ import annotations

import uuid
from pathlib import Path

from lib import TdeManager
from lib.cluster import initdb_args_no_data_checksums


def _tde_cluster(pg_factory, tmp_path: Path, tag: str):
    from lib import PgCluster

    cluster = pg_factory(f"file_mx_{tag}")
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


def run_file_global_smoke(pg_factory, tmp_path: Path) -> None:
    tag = uuid.uuid4().hex[:8]
    keyfile = str(tmp_path / f"file_mx_{tag}.per")
    cluster = _tde_cluster(pg_factory, tmp_path, tag)
    tde = TdeManager(cluster)
    ring = f"file_mx_{tag}_ring"
    tde.add_global_key_provider_file(ring, keyfile=keyfile)
    tde.set_global_principal_key(f"file_mx_{tag}_key", ring)
    cluster.execute(
        "CREATE TABLE file_mx_t(id INT) USING tde_heap; "
        "INSERT INTO file_mx_t SELECT generate_series(1, 50);"
    )
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM file_mx_t") == "50"


def run_file_rotation(pg_factory, tmp_path: Path) -> None:
    tag = uuid.uuid4().hex[:8]
    keyfile = str(tmp_path / f"file_rot_{tag}.per")
    cluster = _tde_cluster(pg_factory, tmp_path, f"rot_{tag}")
    tde = TdeManager(cluster)
    ring = f"file_rot_{tag}_ring"
    tde.add_global_key_provider_file(ring, keyfile=keyfile)
    tde.set_global_principal_key(f"file_rot_{tag}_a", ring)
    cluster.execute(
        "CREATE TABLE file_rot_t(id INT) USING tde_heap; INSERT INTO file_rot_t VALUES (1);"
    )
    tde.rotate_principal_key(f"file_rot_{tag}_b", ring)
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM file_rot_t") == "1"
