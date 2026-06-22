"""
Shared Vault KV v2 tests — same scenarios for each configured profile.

Set ``VAULT_*`` for your lab, then pick profile(s):

  export VAULT_KV_PROFILES=hashicorp_enterprise   # your ns1/pg_tde setup
  export VAULT_KV_PROFILES=auto                   # detect from VAULT_NAMESPACE

Server-specific (run separately):
  * ``tests/test_vault_hashicorp_parity.py`` — change provider, kv-only token (root)
  * ``tests/test_openbao_bash_parity.py`` — OpenBao scenarios 4–12
  * ``tests/test_vault_kmip.py`` — Vault **KMIP engine** (not KV)
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib.vault import VaultConfig
from lib.vault_kv_common_matrix import (
    run_vault_db_scoped_provider,
    run_vault_global_smoke,
    run_vault_key_rotation,
)
from lib.vault_kv_profiles import VaultKvProfile, configure_vault_kv_profile_parametrize

pytestmark = [pytest.mark.vault, pytest.mark.vault_kv_matrix]


def pytest_generate_tests(metafunc):
    configure_vault_kv_profile_parametrize(metafunc)


@pytest.fixture
def vault_kv_config(vault_kv_profile: VaultKvProfile) -> VaultConfig:
    cfg = vault_kv_profile.load_config()
    if cfg is None:
        pytest.skip(f"{vault_kv_profile.name}: VAULT_ADDR not set")
    ready, reason = vault_kv_profile.readiness()
    if not ready:
        pytest.skip(reason)
    return cfg


class TestVaultKvCommonMatrix:
    def test_global_smoke_restart(
        self,
        pg_factory,
        tmp_path: Path,
        vault_kv_profile: VaultKvProfile,
        vault_kv_config: VaultConfig,
    ):
        run_vault_global_smoke(vault_kv_profile, vault_kv_config, pg_factory, tmp_path)

    def test_key_rotation(
        self,
        pg_factory,
        tmp_path: Path,
        vault_kv_profile: VaultKvProfile,
        vault_kv_config: VaultConfig,
    ):
        run_vault_key_rotation(vault_kv_profile, vault_kv_config, pg_factory, tmp_path)

    def test_database_scoped_provider(
        self,
        pg_factory,
        tmp_path: Path,
        vault_kv_profile: VaultKvProfile,
        vault_kv_config: VaultConfig,
    ):
        run_vault_db_scoped_provider(
            vault_kv_profile, vault_kv_config, pg_factory, tmp_path
        )
