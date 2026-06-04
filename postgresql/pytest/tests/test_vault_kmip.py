"""
HashiCorp Vault KMIP secrets engine — regression tests.

Customer report: ``pg_tde_create_key_using_global_key_provider`` fails with::

    ERROR:  KMIP server reported error on register symmetric key: -2

when pg_tde uses Vault as a KMIP server (not Vault KV v2).

Prerequisites: Vault with the **KMIP secrets engine** (Enterprise), configured via
``scripts/setup_vault_kmip_for_pytest.sh``. See ``docs/vault_kmip.md``.

For production HashiCorp integration, Percona documents **Vault KV v2**
(``tests/test_vault_providers.py``), not the KMIP engine.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig
from lib.vault_kmip import (
    is_vault_kmip_register_minus_two_error,
    vault_kmip_key_name,
    vault_kmip_provider_name,
    vault_kmip_require_register_success,
)

pytestmark = [
    pytest.mark.kmip,
    pytest.mark.vault_kmip,
    pytest.mark.bug,
]


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


def _add_global_vault_kmip(tde: TdeManager, kmip: KmipConfig, provider: str) -> None:
    tde.add_global_key_provider_kmip(
        provider,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )


class TestHashicorpVaultKmipRegisterSymmetricKey:
    """
    Reproduce Vault KMIP ``Register`` failures seen in the field (error code -2).

    When ``VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1``, the create_key step must pass
    (use after pg_tde / Vault KMIP integration is fixed).
    """

    def test_vault_kmip_add_global_provider_connects(
        self,
        pg_factory,
        tmp_path: Path,
        vault_kmip_config: KmipConfig,
    ):
        """TLS validate path must succeed before register is attempted."""
        provider = vault_kmip_provider_name()
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_kmip_add")
        tde = TdeManager(cluster)
        _add_global_vault_kmip(tde, vault_kmip_config, provider)
        names = [
            ln.strip()
            for ln in cluster.execute(
                "SELECT name FROM pg_tde_list_all_global_key_providers()"
            ).splitlines()
            if ln.strip()
        ]
        assert provider in names

    def test_vault_kmip_create_key_register_symmetric_key_customer_repro(
        self,
        pg_factory,
        tmp_path: Path,
        vault_kmip_config: KmipConfig,
    ):
        """
        Customer SQL::

            SELECT pg_tde_create_key_using_global_key_provider(
                'kmip-key-12012025', 'kmip-provider-1');
        """
        provider = vault_kmip_provider_name()
        key_name = vault_kmip_key_name()
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_kmip_reg")
        tde = TdeManager(cluster)
        _add_global_vault_kmip(tde, vault_kmip_config, provider)

        sql = (
            "SELECT pg_tde_create_key_using_global_key_provider("
            f"'{key_name}', '{provider}')"
        )
        if vault_kmip_require_register_success():
            cluster.execute(sql)
            cluster.execute(
                "CREATE TABLE vault_kmip_t(id INT) USING tde_heap; "
                "INSERT INTO vault_kmip_t VALUES (1);"
            )
            assert cluster.fetchone("SELECT * FROM vault_kmip_t").strip() == "1"
            return

        try:
            cluster.execute(sql)
        except RuntimeError as exc:
            if is_vault_kmip_register_minus_two_error(exc):
                pytest.xfail(
                    "Known Vault KMIP issue: register symmetric key returned -2 "
                    f"({exc!s}). Use Vault KV v2 for HashiCorp, or fix KMIP Register "
                    "compatibility in pg_tde/libkmip."
                )
            raise

        cluster.execute(
            "CREATE TABLE vault_kmip_t(id INT) USING tde_heap; "
            "INSERT INTO vault_kmip_t VALUES (1);"
        )
        assert cluster.fetchone("SELECT * FROM vault_kmip_t").strip() == "1"
