"""
HashiCorp Vault **KMIP secrets engine** configuration for pytest.

Distinct from Vault KV v2 (``lib/vault.py``). pg_tde talks to Vault on the KMIP
listener (default TCP 5696) using TLS client certificates issued by the engine.

See ``docs/vault_kmip.md`` and ``scripts/setup_vault_kmip_for_pytest.sh``.
"""
from __future__ import annotations

import os
import re
from typing import Optional, Tuple

from lib.kmip import KmipConfig, kmip_config_from_options, kmip_runtime_ready

# Customer-reported repro (override via env for labs).
DEFAULT_VAULT_KMIP_PROVIDER = "kmip-provider-1"
DEFAULT_VAULT_KMIP_KEY_NAME = "kmip-key-12012025"

_VAULT_KMIP_REGISTER_ERR = re.compile(
    r"register symmetric key.*-2",
    re.IGNORECASE,
)


def vault_kmip_provider_name() -> str:
    return os.environ.get("VAULT_KMIP_TEST_PROVIDER_NAME", DEFAULT_VAULT_KMIP_PROVIDER)


def vault_kmip_key_name() -> str:
    return os.environ.get("VAULT_KMIP_TEST_KEY_NAME", DEFAULT_VAULT_KMIP_KEY_NAME)


def vault_kmip_config_from_env() -> Optional[KmipConfig]:
    """Build config from ``KMIP_VAULT_*`` (see ``config/kmip_profiles.example.env``)."""
    return kmip_config_from_options(
        host=os.environ.get("KMIP_VAULT_HOST", ""),
        port=os.environ.get("KMIP_VAULT_PORT", "5696"),
        client_cert=os.environ.get("KMIP_VAULT_CLIENT_CERT", ""),
        client_key=os.environ.get("KMIP_VAULT_CLIENT_KEY", ""),
        server_ca=os.environ.get("KMIP_VAULT_SERVER_CA", ""),
    )


def vault_kmip_runtime_ready() -> Tuple[bool, str]:
    cfg = vault_kmip_config_from_env()
    if cfg is None:
        return False, (
            "KMIP_VAULT_HOST not set — export KMIP_VAULT_* or run "
            "scripts/export_vault_kmip_certs_for_pytest.sh"
        )
    ready, reason = kmip_runtime_ready(cfg)
    if not ready and "missing" in reason.lower():
        return False, (
            f"{reason} — export KMIP_VAULT_CLIENT_CERT/KEY/SERVER_CA or run "
            "scripts/export_vault_kmip_certs_for_pytest.sh"
        )
    return ready, reason


def is_vault_kmip_register_minus_two_error(exc: BaseException) -> bool:
    """True when error matches customer report: register symmetric key: -2."""
    return bool(_VAULT_KMIP_REGISTER_ERR.search(str(exc)))


def vault_kmip_require_register_success() -> bool:
    """When set, create_key must succeed (use after engineering fix)."""
    return os.environ.get("VAULT_KMIP_REQUIRE_REGISTER_SUCCESS", "").lower() in (
        "1",
        "true",
        "yes",
    )
