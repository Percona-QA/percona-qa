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


def _provider_row(
    cluster: PgCluster,
    name: str,
    *,
    scope: str,
    dbname: str = "postgres",
) -> tuple[str, str]:
    listing_fn = (
        "pg_tde_list_all_global_key_providers"
        if scope == "global"
        else "pg_tde_list_all_database_key_providers"
    )
    row = cluster.execute(
        f"SELECT type || '|' || options::text "
        f"FROM {listing_fn}() WHERE name = '{name}'",
        dbname,
    ).strip()
    assert row, f"provider {name!r} not found in {scope} listing"
    typ, opts = row.split("|", 1)
    return typ.strip(), opts.strip()


def _assert_kmip_options(opts: str, kmip: KmipConfig) -> None:
    assert kmip.connect_host() in opts, (
        f"KMIP options {opts!r} missing host {kmip.connect_host()!r}"
    )
    assert str(kmip.port) in opts, (
        f"KMIP options {opts!r} missing port {kmip.port!r}"
    )
    assert kmip.client_cert in opts, (
        f"KMIP options {opts!r} missing client cert {kmip.client_cert!r}"
    )


def run_kmip_change_database_provider_updates_options(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """``pg_tde_change_database_key_provider_kmip`` overwrites catalog options."""
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgdb_{tag}")
    tde = TdeManager(cluster)
    ring = f"chgdb_{tag}_ring"
    tde.add_database_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    typ, before = _provider_row(cluster, ring, scope="database")
    assert typ == "kmip"
    _assert_kmip_options(before, kmip)

    tde.change_database_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    typ, after = _provider_row(cluster, ring, scope="database")
    assert typ == "kmip"
    _assert_kmip_options(after, kmip)


def run_kmip_change_global_provider_updates_options(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """``pg_tde_change_global_key_provider_kmip`` overwrites catalog options."""
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgg_{tag}")
    tde = TdeManager(cluster)
    ring = f"chgg_{tag}_ring"
    add_global_kmip(tde, kmip, ring)
    typ, before = _provider_row(cluster, ring, scope="global")
    assert typ == "kmip"
    _assert_kmip_options(before, kmip)

    tde.change_global_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    typ, after = _provider_row(cluster, ring, scope="global")
    assert typ == "kmip"
    _assert_kmip_options(after, kmip)


def run_kmip_change_database_provider_while_in_use(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """
    Online KMIP reconfiguration while encrypted data exists (port of
    ``t/069_change_database_key_provider_and_verify_data_integrity.pl`` KMIP step).
    """
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgdb_use_{tag}")
    tde = TdeManager(cluster)
    ring = f"chgdb_use_{tag}_ring"
    key = f"chgdb_use_{tag}_key"
    tde.add_database_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    tde.set_database_principal_key(key, ring)
    cluster.execute(
        "CREATE TABLE kmip_chg_db_t(id INT, payload TEXT) USING tde_heap; "
        "INSERT INTO kmip_chg_db_t SELECT i, md5(i::text) FROM generate_series(1, 50) i"
    )
    cluster.execute("CHECKPOINT")

    tde.change_database_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_chg_db_t") == "50"
    cluster.execute("SELECT pg_tde_verify_key()")

    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_chg_db_t") == "50"
    cluster.execute("SELECT pg_tde_verify_key()")


def run_kmip_change_global_provider_while_in_use(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    """Global KMIP provider reconfiguration with active principal key + encrypted table."""
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgg_use_{tag}")
    tde = TdeManager(cluster)
    ring = f"chgg_use_{tag}_ring"
    key = f"chgg_use_{tag}_key"
    add_global_kmip(tde, kmip, ring)
    tde.set_global_principal_key(key, ring)
    cluster.execute(
        "CREATE TABLE kmip_chg_g_t(id INT) USING tde_heap; "
        "INSERT INTO kmip_chg_g_t SELECT generate_series(1, 80)"
    )
    cluster.execute("CHECKPOINT")

    tde.change_global_key_provider_kmip(
        ring,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_chg_g_t") == "80"
    cluster.execute("SELECT pg_tde_verify_key()")

    cluster.restart()
    cluster.wait_ready(timeout=90)
    assert cluster.fetchone("SELECT COUNT(*) FROM kmip_chg_g_t") == "80"
    cluster.execute("SELECT pg_tde_verify_server_key()")


def run_kmip_change_nonexistent_database_provider_fails(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgdb_ghost_{tag}")
    tde = TdeManager(cluster)
    try:
        tde.change_database_key_provider_kmip(
            "ghost_kmip_ring",
            host=kmip.connect_host(),
            port=kmip.port,
            cert_path=kmip.client_cert,
            key_path=kmip.client_key,
            ca_path=kmip.server_ca,
        )
    except RuntimeError as exc:
        msg = str(exc).lower()
        assert (
            "ghost_kmip_ring" in msg
            or "does not exist" in msg
            or "not found" in msg
        ), f"expected missing-provider error; got: {exc!r}"
        return
    raise AssertionError(
        "pg_tde_change_database_key_provider_kmip should fail for unknown provider"
    )


def run_kmip_change_nonexistent_global_provider_fails(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> None:
    tag = _tag(profile)
    cluster = new_tde_cluster(pg_factory, tmp_path, f"chgg_ghost_{tag}")
    tde = TdeManager(cluster)
    try:
        tde.change_global_key_provider_kmip(
            "ghost_global_kmip",
            host=kmip.connect_host(),
            port=kmip.port,
            cert_path=kmip.client_cert,
            key_path=kmip.client_key,
            ca_path=kmip.server_ca,
        )
    except RuntimeError as exc:
        msg = str(exc).lower()
        assert (
            "ghost_global_kmip" in msg
            or "does not exist" in msg
            or "not found" in msg
        ), f"expected missing-provider error; got: {exc!r}"
        return
    raise AssertionError(
        "pg_tde_change_global_key_provider_kmip should fail for unknown provider"
    )
