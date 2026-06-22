"""
Shared KMIP scenarios run against every ``KmipServerProfile``.

Server-specific regressions stay in ``tests/test_vault_kmip.py`` (Vault Register -2),
``tests/test_kmip.py`` (Cosmian advanced / bash parity), etc.
"""
from __future__ import annotations

import uuid
from pathlib import Path

from lib import PgCluster, TdeManager
from lib.kmip import KmipConfig
from lib.kmip_profiles import KmipServerProfile
from lib.kmip_revalidation import add_global_kmip, new_tde_cluster


def _tag(profile: KmipServerProfile) -> str:
    return f"{profile.name}_{uuid.uuid4().hex[:8]}"


def run_kmip_global_smoke(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """Add global KMIP provider, principal key, encrypted table, restart."""
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, tag)
    tde = TdeManager(cluster)
    ring = f"mx_{tag}_ring"
    add_global_kmip(tde, kmip, ring)
    tde.set_global_principal_key(f"mx_{tag}_key", ring)
    cluster.execute(
        "CREATE TABLE kmip_mx_t(id INT) USING tde_heap; "
        "INSERT INTO kmip_mx_t SELECT generate_series(1, 120);"
    )
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_mx_t") == "120"


def run_kmip_key_rotation(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """Rotate principal key on the same KMIP provider."""
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"rot_{tag}")
    tde = TdeManager(cluster)
    ring = f"mxrot_{tag}_ring"
    add_global_kmip(tde, kmip, ring)
    tde.set_global_principal_key(f"mxrot_{tag}_a", ring)
    cluster.execute(
        "CREATE TABLE kmip_mx_rot(id INT) USING tde_heap; INSERT INTO kmip_mx_rot VALUES (1);"
    )
    tde.rotate_principal_key(f"mxrot_{tag}_b", ring)
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_mx_rot") == "1"


def run_kmip_file_and_kmip_multi_db(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """db1 file principal key; db2 KMIP principal key (functions_test scenario 2 subset)."""
    tag = _tag(profile)
    keyfile = str(tmp_path / f"mx_{tag}.file")
    cluster = new_tde_cluster(pg_factory, tmp_path, f"mdb_{tag}")
    tde = TdeManager(cluster)
    tde.add_global_key_provider_file("file_ring_mx", keyfile=keyfile)
    add_global_kmip(tde, kmip, f"kmip_ring_mx_{tag}")

    for db in ("db1", "db2"):
        cluster.execute(f"CREATE DATABASE {db}")
        cluster.execute("CREATE EXTENSION pg_tde", db)

    cluster.execute(
        "SELECT pg_tde_create_key_using_global_key_provider('file_k', 'file_ring_mx')",
        "db1",
    )
    cluster.execute(
        "SELECT pg_tde_set_key_using_global_key_provider('file_k', 'file_ring_mx')",
        "db1",
    )
    tde.set_global_principal_key(f"kmip_k_{tag}", f"kmip_ring_mx_{tag}", dbname="db2")

    cluster.execute("CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (10)", "db1")
    cluster.execute("CREATE TABLE t2(a INT) USING tde_heap; INSERT INTO t2 VALUES (20)", "db2")
    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT a FROM t1", "db1").strip() == "10"
    assert cluster.fetchone("SELECT a FROM t2", "db2").strip() == "20"
