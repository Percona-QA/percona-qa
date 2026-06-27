"""
KMIP server revalidation matrix (post–PR #595 / libkmip C++ rewrite).

Run the same checklist against each Percona-supported KMIP backend. Configure
one or more profiles via ``KMIP_REVALIDATE_PROFILES`` or
``--kmip-revalidate-profiles`` (comma-separated, or ``all``).

See ``docs/kmip/vendor-signoff.md`` and ``config/kmip_profiles.example.env``.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib.kmip import KmipConfig
from lib.kmip_profiles import (
    KmipServerProfile,
    configure_kmip_profile_parametrize,
)
from lib.kmip_revalidation import run_kmip_revalidation_checklist

pytestmark = [pytest.mark.kmip, pytest.mark.kmip_revalidation]


def pytest_generate_tests(metafunc):
    configure_kmip_profile_parametrize(metafunc)


@pytest.fixture
def kmip_profile_config(kmip_server_profile: KmipServerProfile) -> KmipConfig:
    cfg = kmip_server_profile.load_config()
    if cfg is None:
        pytest.skip(
            f"{kmip_server_profile.name}: not configured "
            f"(set {kmip_server_profile.env_prefix}HOST and cert paths; "
            f"see config/kmip_profiles.example.env)"
        )
    ready, reason = kmip_server_profile.readiness()
    if not ready:
        pytest.skip(f"{kmip_server_profile.name}: {reason}")
    return cfg


class TestKmipServerRevalidation:
    """
    Standard revalidation checklist per supported KMIP server.

    Complements ``test_kmip.py`` (bash parity, delete, CLI) and
    ``TestKmipCppClientRegression`` (PG-2125 lifecycle).
    """

    def test_kmip_revalidation_checklist(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_server_profile: KmipServerProfile,
        kmip_profile_config: KmipConfig,
    ):
        result = run_kmip_revalidation_checklist(
            kmip_server_profile,
            kmip_profile_config,
            pg_factory,
            tmp_path,
        )
        detail = (
            f"profile={result.profile} vendor={result.vendor} "
            f"passed={result.steps_passed} failed={result.steps_failed}"
        )
        if result.error:
            detail += f" error={result.error}"
        assert result.ok, detail
