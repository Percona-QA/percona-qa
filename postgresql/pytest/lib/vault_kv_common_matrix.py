"""Shared Vault KV v2 scenarios for every ``VaultKvProfile``."""
from __future__ import annotations

import uuid
from pathlib import Path

from lib import TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.vault import VaultConfig
from lib.vault_kv_profiles import VaultKvProfile


def _tde_cluster(pg_factory, tmp_path: Path, tag: str):
    from lib import PgCluster

    cluster = pg_factory(f"vault_mx_{tag}")
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


def _add_global_vault(
    tde: TdeManager,
    vault: VaultConfig,
    provider: str,
    tmp_path: Path,
) -> None:
    tde.add_global_key_provider_vault(
        provider,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
    )


def _tag(profile: VaultKvProfile) -> str:
    return f"{profile.name}_{uuid.uuid4().hex[:8]}"


def run_vault_global_smoke(
    profile: VaultKvProfile,
    vault: VaultConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    tag = _tag(profile)
    cluster = _tde_cluster(pg_factory, tmp_path, tag)
    tde = TdeManager(cluster)
    ring = f"vmx_{tag}_ring"
    _add_global_vault(tde, vault, ring, tmp_path)
    tde.set_global_principal_key(f"vmx_{tag}_key", ring)
    cluster.execute(
        "CREATE TABLE vault_mx_t(id INT) USING tde_heap; "
        "INSERT INTO vault_mx_t SELECT generate_series(1, 80);"
    )
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM vault_mx_t") == "80"


def run_vault_key_rotation(
    profile: VaultKvProfile,
    vault: VaultConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    tag = _tag(profile)
    cluster = _tde_cluster(pg_factory, tmp_path, f"vrot_{tag}")
    tde = TdeManager(cluster)
    ring = f"vmxrot_{tag}_ring"
    _add_global_vault(tde, vault, ring, tmp_path)
    tde.set_global_principal_key(f"vmxrot_{tag}_a", ring)
    cluster.execute(
        "CREATE TABLE vault_mx_rot(id INT) USING tde_heap; INSERT INTO vault_mx_rot VALUES (1);"
    )
    tde.rotate_principal_key(f"vmxrot_{tag}_b", ring)
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM vault_mx_rot") == "1"


def run_vault_db_scoped_provider(
    profile: VaultKvProfile,
    vault: VaultConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    tag = _tag(profile)
    cluster = _tde_cluster(pg_factory, tmp_path, f"vdb_{tag}")
    tde = TdeManager(cluster)
    cluster.execute("CREATE DATABASE sb_mx")
    cluster.execute("CREATE EXTENSION pg_tde", "sb_mx")
    ring = f"vmxdb_{tag}_ring"
    tde.add_database_key_provider_vault(
        ring,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
        dbname="sb_mx",
    )
    tde.set_database_principal_key(f"vmxdb_{tag}_key", ring, dbname="sb_mx")
    cluster.execute(
        "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (7)",
        "sb_mx",
    )
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT a FROM t1", "sb_mx").strip() == "7"
