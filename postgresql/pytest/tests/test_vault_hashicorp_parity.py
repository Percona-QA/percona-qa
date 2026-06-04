"""
HashiCorp Vault automation script parity (pytest).

Ports:

  - ``pg_tde_hashicorp_vault_mount_permission_warning_test.sh``
  - ``pg_tde_change_database_key_provider_vault_v2.sh``
"""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.vault import VaultConfig
from lib.vault_cli import (
    create_hashicorp_kv_only_token,
    resolve_vault_bin,
    vault_kv_delete_exported,
    vault_kv_export,
    vault_kv_import,
)

pytestmark = [pytest.mark.vault, pytest.mark.encryption]


def _tde_cluster(pg_factory, tmp_path: Path, name: str) -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


def _add_db_vault(
    tde: TdeManager,
    vault: VaultConfig,
    name: str,
    tmp_path: Path,
    dbname: str = "postgres",
) -> None:
    tde.add_database_key_provider_vault(
        name,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
        dbname=dbname,
    )


@pytest.mark.vault
class TestHashicorpVaultMountPermissionWarning:
    """``pg_tde_hashicorp_vault_mount_permission_warning_test.sh``."""

    def test_hashicorp_kv_only_token_without_mount_metadata(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        vault_kv_only_token_file: str,
    ):
        if vault_config.namespace.strip():
            pytest.skip("HashiCorp mount-metadata test uses non-namespaced Vault")
        token_file = vault_kv_only_token_file
        if not token_file:
            vbin = resolve_vault_bin()
            if vbin is None:
                pytest.skip("vault CLI not found for kv-only token")
            root = vault_config.token_sql_arg(tmp_path)
            root_tok = Path(root).read_text(encoding="utf-8").strip()
            token_file = str(
                create_hashicorp_kv_only_token(
                    run_dir=tmp_path / "hc_kvonly",
                    vault_bin=vbin,
                    root_token=root_tok,
                    vault_addr=vault_config.addr,
                    secret_mount=vault_config.secret_mount,
                )
            )
        restricted = vault_config.with_token_path(token_file)
        cluster = _tde_cluster(pg_factory, tmp_path, "hc_kvonly")
        tde = TdeManager(cluster)
        _add_db_vault(tde, restricted, "vault_keyring", tmp_path)
        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'vault_key1', 'vault_keyring')"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'vault_key1', 'vault_keyring')"
        )
        cluster.execute(
            "CREATE TABLE hc_kv_t(a INT) USING tde_heap; "
            "INSERT INTO hc_kv_t VALUES (100),(200);"
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM hc_kv_t") == "2"


@pytest.mark.vault
class TestHashicorpVaultChangeDatabaseKeyProviderV2:
    """``pg_tde_change_database_key_provider_vault_v2.sh``."""

    def test_change_database_key_provider_vault_v2_after_kv_reseed(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
    ):
        if vault_config.namespace.strip():
            pytest.skip("HashiCorp change-provider bash uses non-namespaced Vault")
        vbin = resolve_vault_bin()
        if vbin is None:
            pytest.skip("vault CLI required for KV export/import parity")

        export_dir = tmp_path / "vault_export"
        cluster = _tde_cluster(pg_factory, tmp_path, "hc_chgdb")
        tde = TdeManager(cluster)
        token_path = vault_config.token_sql_arg(tmp_path)
        _add_db_vault(tde, vault_config, "local_vault_provider", tmp_path)
        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'local_key', 'local_vault_provider')"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'local_key', 'local_vault_provider')"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (100)"
        )
        assert cluster.fetchone("SELECT * FROM t1").strip() == "100"

        vault_kv_export(vault_config, export_dir, vbin)
        vault_kv_delete_exported(vault_config, export_dir, vbin)

        cluster.restart()
        cluster.wait_ready(timeout=90)
        with pytest.raises(RuntimeError, match="local_key|vault|key provider"):
            cluster.fetchone("SELECT * FROM t1")

        vault_kv_import(vault_config, export_dir, vbin)
        token_path2 = tmp_path / "token_file2"
        shutil.copy(token_path, token_path2)

        tde.change_database_key_provider_vault(
            "local_vault_provider",
            vault_url=vault_config.addr,
            secret_mount_point=vault_config.secret_mount,
            token_path=str(token_path2),
            ca_path=vault_config.ca_path,
            namespace=vault_config.namespace,
        )
        assert cluster.fetchone("SELECT * FROM t1").strip() == "100"
