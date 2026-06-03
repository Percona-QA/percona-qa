"""
Standard KMIP revalidation checklist (post–PR #595 / libkmip C++ client).

Used to re-run the same operations against every supported KMIP server profile.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig
from lib.kmip_profiles import KmipServerProfile


@dataclass
class KmipChecklistResult:
    profile: str
    vendor: str
    steps_passed: List[str] = field(default_factory=list)
    steps_failed: List[str] = field(default_factory=list)
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        return not self.steps_failed and self.error is None


def add_global_kmip(tde: TdeManager, kmip: KmipConfig, provider_name: str) -> None:
    tde.add_global_key_provider_kmip(
        provider_name,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )


def new_tde_cluster(
    pg_factory,
    tmp_path: Path,
    tag: str,
) -> PgCluster:
    cluster = pg_factory(f"kmip_rev_{tag}")
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


def run_kmip_revalidation_checklist(
    profile: KmipServerProfile,
    kmip: KmipConfig,
    pg_factory,
    tmp_path: Path,
) -> KmipChecklistResult:
    """
    End-to-end checklist every supported KMIP server must pass after the
    libkmip rewrite:

    1. validate — ``add_global_key_provider_kmip`` (TLS + KMIP connect)
    2. register — create + set principal key
    3. locate + get — encrypted DML
    4. restart — decrypt after stop/start
    5. register — principal key rotation
    6. database scope — ``add_database_key_provider_kmip`` + DML + restart
    """
    result = KmipChecklistResult(profile=profile.name, vendor=profile.vendor)
    tag = profile.name.replace("-", "_")
    cluster: Optional[PgCluster] = None

    try:
        cluster = new_tde_cluster(pg_factory, tmp_path, tag)
        tde = TdeManager(cluster)
        ring = f"rev_{tag}_g"
        add_global_kmip(tde, kmip, ring)
        result.steps_passed.append("add_global_provider")

        tde.set_global_principal_key(f"rev_{tag}_key_a", ring)
        result.steps_passed.append("register_principal_key")

        cluster.execute(
            "CREATE TABLE kmip_rev_t(id INT) USING tde_heap; "
            "INSERT INTO kmip_rev_t SELECT generate_series(1, 100);"
        )
        if cluster.fetchone("SELECT COUNT(*) FROM kmip_rev_t") != "100":
            result.steps_failed.append("encrypted_dml")
        else:
            result.steps_passed.append("encrypted_dml")

        cluster.restart()
        cluster.wait_ready(timeout=90)
        if cluster.fetchone("SELECT COUNT(*) FROM kmip_rev_t") != "100":
            result.steps_failed.append("read_after_restart")
        else:
            result.steps_passed.append("read_after_restart")

        tde.rotate_principal_key(f"rev_{tag}_key_b", ring)
        cluster.execute("INSERT INTO kmip_rev_t VALUES (999);")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        if int(cluster.fetchone("SELECT COUNT(*) FROM kmip_rev_t")) < 101:
            result.steps_failed.append("read_after_rotation_restart")
        else:
            result.steps_passed.append("rotate_and_second_restart")

        dbname = f"kmiprev_{tag}"[:63]
        cluster.execute(f"CREATE DATABASE {dbname}")
        cluster.execute("CREATE EXTENSION pg_tde", dbname)
        tde.add_database_key_provider_kmip(
            f"rev_{tag}_db",
            host=kmip.connect_host(),
            port=kmip.port,
            cert_path=kmip.client_cert,
            key_path=kmip.client_key,
            ca_path=kmip.server_ca,
            dbname=dbname,
        )
        tde.set_database_principal_key(
            f"rev_{tag}_db_key", f"rev_{tag}_db", dbname=dbname
        )
        cluster.execute(
            "CREATE TABLE kmip_rev_db(id INT) USING tde_heap; "
            "INSERT INTO kmip_rev_db VALUES (42)",
            dbname,
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        if cluster.fetchone("SELECT * FROM kmip_rev_db", dbname).strip() != "42":
            result.steps_failed.append("database_scope_after_restart")
        else:
            result.steps_passed.append("database_scope_provider")

    except Exception as exc:
        result.error = str(exc)
        if not result.steps_failed:
            result.steps_failed.append("exception")
    finally:
        if cluster is not None:
            try:
                if cluster.is_ready():
                    cluster.stop(check=False)
            except Exception:
                pass

    return result
