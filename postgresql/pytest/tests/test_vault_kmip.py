"""
HashiCorp Vault KMIP secrets engine — regression tests.

Customer report: ``pg_tde_create_key_using_global_key_provider`` fails with::

    ERROR:  KMIP server reported error on register symmetric key: -2

when pg_tde uses Vault as a KMIP server (not Vault KV v2).

Prerequisites: Vault with the **KMIP secrets engine** (Enterprise), configured via
``scripts/setup_vault_kmip_for_pytest.sh``. See ``docs/kmip/vault-kmip-engine.md``.

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


def _activate_global_kmip_key(
    cluster: PgCluster, key_name: str, provider: str
) -> None:
    """create_key alone does not configure the principal key; set server + DB keys."""
    cluster.execute(
        "SELECT pg_tde_set_server_key_using_global_key_provider("
        f"'{key_name}', '{provider}')"
    )
    cluster.execute(
        "SELECT pg_tde_set_key_using_global_key_provider("
        f"'{key_name}', '{provider}')"
    )


def _create_global_kmip_key_customer_repro(
    tde: TdeManager,
    *,
    key_name: str,
    provider: str,
    strict_register: bool,
) -> None:
    """
    Customer ``create_key`` SQL against a shared Vault KMIP server.

    Keys persist in Vault between pytest runs, so ``already exists`` is OK.
    Register ``-2`` still xfails when not in strict mode.
    """
    sql = (
        "SELECT pg_tde_create_key_using_global_key_provider("
        f"'{key_name}', '{provider}')"
    )
    if strict_register:
        tde._execute_create_global_key_allow_duplicate(sql)
        return
    try:
        tde._execute_create_global_key_allow_duplicate(sql)
    except RuntimeError as exc:
        if is_vault_kmip_register_minus_two_error(exc):
            pytest.xfail(
                "Known Vault KMIP issue: register symmetric key returned -2 "
                f"({exc!s}). Use Vault KV v2 for HashiCorp, or fix KMIP Register "
                "compatibility in pg_tde/libkmip."
            )
        raise


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
        Customer SQL (repro target — register may return -2)::

            SELECT pg_tde_create_key_using_global_key_provider(
                'kmip-key-12012025', 'kmip-provider-1');

        After create_key succeeds (or key already exists in Vault KMIP), server + DB
        principal keys must be set before ``tde_heap`` tables can be created.
        """
        provider = vault_kmip_provider_name()
        key_name = vault_kmip_key_name()
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_kmip_reg")
        tde = TdeManager(cluster)
        _add_global_vault_kmip(tde, vault_kmip_config, provider)

        _create_global_kmip_key_customer_repro(
            tde,
            key_name=key_name,
            provider=provider,
            strict_register=vault_kmip_require_register_success(),
        )
        _activate_global_kmip_key(cluster, key_name, provider)
        cluster.execute(
            "CREATE TABLE vault_kmip_t(id INT) USING tde_heap; "
            "INSERT INTO vault_kmip_t VALUES (1);"
        )
        assert cluster.fetchone("SELECT * FROM vault_kmip_t").strip() == "1"
