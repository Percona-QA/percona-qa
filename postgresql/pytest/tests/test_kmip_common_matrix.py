"""
Shared KMIP tests — same scenarios for every configured KMIP server profile.

Configure one or more backends via ``KMIP_REVALIDATE_PROFILES`` (or ``all``).
Each profile uses its own env prefix (``KMIP_COSMIAN_*``, ``KMIP_VAULT_*``, …).

Server-specific suites (run separately):
  * ``tests/test_vault_kmip.py`` — Vault KMIP Register -2 customer repro
  * ``tests/test_kmip.py`` — Cosmian advanced / bash parity / CLI negatives
  * ``tests/test_kmip_server_revalidation.py`` — full libkmip checklist (same matrix)

See ``docs/key_provider_matrix.md``.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib.kmip import KmipConfig
from lib.kmip_common_matrix import (
    run_kmip_file_and_kmip_multi_db,
    run_kmip_global_smoke,
    run_kmip_key_rotation,
)
from lib.kmip_profiles import KmipServerProfile, configure_kmip_profile_parametrize

pytestmark = [pytest.mark.kmip, pytest.mark.kmip_matrix]


def pytest_generate_tests(metafunc):
    configure_kmip_profile_parametrize(metafunc)


@pytest.fixture
def kmip_profile_config(kmip_server_profile: KmipServerProfile) -> KmipConfig:
    cfg = kmip_server_profile.load_config()
    if cfg is None:
        pytest.skip(
            f"{kmip_server_profile.name}: not configured "
            f"(set {kmip_server_profile.env_prefix}HOST and cert paths)"
        )
    ready, reason = kmip_server_profile.readiness()
    if not ready:
        pytest.skip(f"{kmip_server_profile.name}: {reason}")
    return cfg


class TestKmipCommonMatrix:
    """Core KMIP behaviour — identical SQL path for every KMS profile."""

    def test_global_smoke_restart(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_server_profile: KmipServerProfile,
        kmip_profile_config: KmipConfig,
    ):
        run_kmip_global_smoke(
            kmip_server_profile, kmip_profile_config, pg_factory, tmp_path
        )

    def test_key_rotation(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_server_profile: KmipServerProfile,
        kmip_profile_config: KmipConfig,
    ):
        run_kmip_key_rotation(
            kmip_server_profile, kmip_profile_config, pg_factory, tmp_path
        )

    def test_multi_db_file_and_kmip(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_server_profile: KmipServerProfile,
        kmip_profile_config: KmipConfig,
    ):
        run_kmip_file_and_kmip_multi_db(
            kmip_server_profile, kmip_profile_config, pg_factory, tmp_path
        )
