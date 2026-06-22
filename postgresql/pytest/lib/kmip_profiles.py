"""
Supported KMIP server profiles for post–PR-595 revalidation.

Percona documents KMIP-compatible providers (see
https://docs.percona.com/pg-tde/global-key-provider-configuration/overview.html):

  * Cosmian KMS (Percona CI — primary automated KMIP backend)
  * Fortanix DSM
  * Thales CipherTrust Manager
  * Cosmian KMS
  * Akeyless (KMIP endpoint)
  * HashiCorp Vault **KMIP secrets engine** (lab regression; see ``test_vault_kmip.py``)

For HashiCorp production deployments, use **Vault KV v2** (``test_vault_providers.py``),
not the KMIP engine.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from lib.kmip import KmipConfig, kmip_config_from_options, kmip_runtime_ready


@dataclass(frozen=True)
class KmipServerProfile:
    """Named KMIP backend for matrix revalidation."""

    name: str
    vendor: str
    docs_url: str
    env_prefix: str
    notes: str = ""
    ci_automated: bool = False

    def load_config(self) -> Optional[KmipConfig]:
        """Build ``KmipConfig`` from profile-specific or default env vars."""
        if self.name == DEFAULT_KMIP_PROFILE:
            # setup_cosmian_for_pytest.sh exports KMIP_SERVER_*; labs may use KMIP_COSMIAN_*.
            cfg = standard_kmip_env_config()
            if cfg is not None:
                return cfg
        prefix = self.env_prefix
        if prefix == "KMIP_":
            return standard_kmip_env_config()
        return kmip_config_from_options(
            host=os.environ.get(f"{prefix}HOST", ""),
            port=os.environ.get(f"{prefix}PORT", "5696"),
            client_cert=os.environ.get(f"{prefix}CLIENT_CERT", ""),
            client_key=os.environ.get(f"{prefix}CLIENT_KEY", ""),
            server_ca=os.environ.get(f"{prefix}SERVER_CA", ""),
        )

    def readiness(self) -> Tuple[bool, str]:
        cfg = self.load_config()
        if cfg is None:
            return False, f"{self.name}: host not configured (set {self.env_prefix}HOST)"
        return kmip_runtime_ready(cfg)


# Keys are CLI/env profile ids (``KMIP_REVALIDATE_PROFILES``).
SUPPORTED_KMIP_SERVER_PROFILES: Dict[str, KmipServerProfile] = {
    "fortanix": KmipServerProfile(
        name="fortanix",
        vendor="Fortanix DSM",
        docs_url="https://docs.percona.com/pg-tde/global-key-provider-configuration/fortanix.html",
        env_prefix="KMIP_FORTANIX_",
        notes="Revalidate after libkmip C++ client (PR #595)",
    ),
    "thales": KmipServerProfile(
        name="thales",
        vendor="Thales CipherTrust Manager",
        docs_url="https://docs.percona.com/pg-tde/global-key-provider-configuration/thales.html",
        env_prefix="KMIP_THALES_",
        notes="Also sold as CipherTrust; same KMIP SQL API",
    ),
    "cosmian": KmipServerProfile(
        name="cosmian",
        vendor="Cosmian KMS",
        docs_url="https://docs.cosmian.com/key_management_system/integrations/databases/percona/",
        env_prefix="KMIP_COSMIAN_",
        notes="Percona CI automated KMIP; ``scripts/setup_cosmian_for_pytest.sh``",
        ci_automated=True,
    ),
    "akeyless": KmipServerProfile(
        name="akeyless",
        vendor="Akeyless",
        docs_url="https://docs.percona.com/pg-tde/global-key-provider-configuration/akeyless.html",
        env_prefix="KMIP_AKEYLESS_",
    ),
    "vault_kmip": KmipServerProfile(
        name="vault_kmip",
        vendor="HashiCorp Vault KMIP engine",
        docs_url="https://developer.hashicorp.com/vault/docs/secrets/kmip",
        env_prefix="KMIP_VAULT_",
        notes=(
            "Enterprise KMIP listener; customer register -2 repro in "
            "tests/test_vault_kmip.py — prefer Vault KV v2 in production"
        ),
    ),
}

ALL_KMIP_PROFILE_NAMES: Tuple[str, ...] = tuple(SUPPORTED_KMIP_SERVER_PROFILES)

# Default KMIP backend for CI and local dev (no vendor license required).
DEFAULT_KMIP_PROFILE = "cosmian"


def standard_kmip_env_config() -> Optional[KmipConfig]:
    """``KMIP_SERVER_*`` exported by ``setup_cosmian_for_pytest.sh``."""
    return kmip_config_from_options(
        host=os.environ.get("KMIP_SERVER_ADDRESS", ""),
        port=os.environ.get("KMIP_SERVER_PORT", ""),
        client_cert=os.environ.get("KMIP_CLIENT_CA", ""),
        client_key=os.environ.get("KMIP_CLIENT_KEY", ""),
        server_ca=os.environ.get("KMIP_SERVER_CA", ""),
    )


def default_revalidate_profiles() -> str:
    """Percona CI default KMIP backend (Cosmian — no license)."""
    return DEFAULT_KMIP_PROFILE


def parse_revalidate_profile_list(raw: str) -> List[str]:
    """Parse ``KMIP_REVALIDATE_PROFILES`` (comma-separated or ``all``)."""
    raw = (raw or default_revalidate_profiles()).strip()
    if raw.lower() == "all":
        return list(ALL_KMIP_PROFILE_NAMES)
    return [p.strip().lower() for p in raw.replace(" ", ",").split(",") if p.strip()]


def resolve_kmip_profiles(raw: str) -> List[KmipServerProfile]:
    """Return profile objects; unknown names raise ``ValueError``."""
    names = parse_revalidate_profile_list(raw)
    out: List[KmipServerProfile] = []
    for name in names:
        key = name.lower()
        if key not in SUPPORTED_KMIP_SERVER_PROFILES:
            raise ValueError(
                f"Unknown KMIP profile {name!r}. "
                f"Supported: {', '.join(ALL_KMIP_PROFILE_NAMES)}"
            )
        prof = SUPPORTED_KMIP_SERVER_PROFILES[key]
        if prof not in out:
            out.append(prof)
    return out


def profiles_help_text() -> str:
    return "Profiles: " + ", ".join(ALL_KMIP_PROFILE_NAMES) + " (or 'all')"


def kmip_revalidate_profiles_from_config(config) -> str:
    """CLI/env string for ``KMIP_REVALIDATE_PROFILES`` (pytest ``config`` or None)."""
    if config is not None:
        for opt_name in ("--kmip-profile", "--kmip-revalidate-profiles"):
            opt = config.getoption(opt_name, default=None)
            if opt:
                return opt
    env_profile = os.environ.get("KMIP_PROFILE", "").strip()
    if env_profile:
        return env_profile
    return os.environ.get("KMIP_REVALIDATE_PROFILES") or default_revalidate_profiles()


def kmip_profile_explicitly_chosen(config) -> bool:
    """True when user chose a non-default KMIP server (not implicit cosmian)."""
    if config is not None:
        if config.getoption("--kmip-profile", default=""):
            return True
        cli_profiles = config.getoption("--kmip-revalidate-profiles", default="")
        if cli_profiles and cli_profiles.strip().lower() != DEFAULT_KMIP_PROFILE:
            return True
    if os.environ.get("KMIP_PROFILE", "").strip():
        prof = os.environ.get("KMIP_PROFILE", "").strip().lower()
        return prof != DEFAULT_KMIP_PROFILE
    raw = os.environ.get("KMIP_REVALIDATE_PROFILES", "").strip()
    return bool(raw) and raw.lower() != DEFAULT_KMIP_PROFILE


def resolve_kmip_profiles_for_pytest(config) -> List[KmipServerProfile]:
    """Parse profiles; raise ``pytest.UsageError`` on unknown names."""
    import pytest

    raw = kmip_revalidate_profiles_from_config(config)
    try:
        return resolve_kmip_profiles(raw)
    except ValueError as exc:
        raise pytest.UsageError(str(exc)) from exc


def ready_kmip_profiles(profiles: List[KmipServerProfile]) -> List[KmipServerProfile]:
    """Profiles with host + certs + TCP reachable."""
    out: List[KmipServerProfile] = []
    for prof in profiles:
        ok, _ = prof.readiness()
        if ok:
            out.append(prof)
    return out


def configure_kmip_profile_parametrize(metafunc, *, fixture_name: str = "kmip_server_profile") -> None:
    """Register ``KMIP_REVALIDATE_PROFILES`` parametrization on ``metafunc``."""
    if fixture_name not in metafunc.fixturenames:
        return
    profiles = resolve_kmip_profiles_for_pytest(metafunc.config)
    metafunc.parametrize(
        fixture_name,
        profiles,
        ids=lambda p: p.name,
    )


def resolve_session_kmip_config(config) -> Tuple[Optional[KmipConfig], str]:
    """
    KMIP config for ``test_kmip.py`` (``kmip_config`` fixture) and collection skips.

    Default profile is **Cosmian** (``KMIP_SERVER_*`` from ``setup_cosmian_for_pytest.sh``).

    Choose another backend explicitly::

        export KMIP_PROFILE=vault_kmip   # or KMIP_REVALIDATE_PROFILES=vault_kmip
        pytest tests/test_kmip.py -v

    Resolution:
    1. Single profile from ``KMIP_PROFILE`` / ``KMIP_REVALIDATE_PROFILES`` (default cosmian)
    2. Legacy ``--kmip-server-address`` only when profile was **not** explicitly overridden
    """
    explicit = kmip_profile_explicitly_chosen(config)

    try:
        profiles = resolve_kmip_profiles_for_pytest(config)
    except Exception:
        return None, (
            f"KMIP not configured — default is {DEFAULT_KMIP_PROFILE}; "
            "run: source scripts/setup_cosmian_for_pytest.sh"
        )

    if len(profiles) != 1:
        return None, (
            f"test_kmip.py requires one KMIP profile (default {DEFAULT_KMIP_PROFILE}); "
            f"use KMIP_PROFILE=vault_kmip or matrix tests for multiple profiles"
        )

    prof = profiles[0]
    cfg = prof.load_config()
    if cfg is None:
        return None, (
            f"{prof.name}: not configured (set {prof.env_prefix}* or "
            f"source scripts/setup_cosmian_for_pytest.sh for {DEFAULT_KMIP_PROFILE})"
        )
    ready, reason = prof.readiness()
    if ready:
        return cfg, ""

    # Legacy KMIP_SERVER_* override only for default Cosmian when not switching servers.
    if not explicit and prof.name == DEFAULT_KMIP_PROFILE and config is not None:
        legacy = kmip_config_from_options(
            host=config.getoption("--kmip-server-address"),
            port=config.getoption("--kmip-server-port"),
            client_cert=config.getoption("--kmip-client-ca"),
            client_key=config.getoption("--kmip-client-key"),
            server_ca=config.getoption("--kmip-server-ca"),
        )
        if legacy is not None:
            ready, reason = kmip_runtime_ready(legacy)
            if ready:
                return legacy, ""

    if prof.name == DEFAULT_KMIP_PROFILE:
        return None, (
            f"{reason} — start Cosmian: source scripts/setup_cosmian_for_pytest.sh "
            f"(default; no license). Or: export KMIP_PROFILE=vault_kmip"
        )
    return None, reason
