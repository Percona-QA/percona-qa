"""
Vault KV v2 server profiles for shared pytest matrix.

Production HashiCorp uses KV v2 (not the KMIP engine). OpenBao is API-compatible
with namespace + ``pg_tde`` mount. One lab typically exports a single ``VAULT_*``
set; select the profile explicitly or auto-detect from namespace/mount.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from lib.vault import VaultConfig, vault_config_from_options, vault_runtime_ready


@dataclass(frozen=True)
class VaultKvProfile:
    name: str
    vendor: str
    notes: str = ""
    requires_namespace: bool = False
    openbao: bool = False

    def load_config(self) -> Optional[VaultConfig]:
        return vault_config_from_options(
            addr=os.environ.get("VAULT_ADDR", ""),
            token=os.environ.get("VAULT_TOKEN", ""),
            token_path=os.environ.get("VAULT_TOKEN_FILE", ""),
            secret_mount=os.environ.get("VAULT_SECRET_MOUNT", ""),
            ca_path=os.environ.get("VAULT_CA_PATH", ""),
            namespace=os.environ.get("VAULT_NAMESPACE", ""),
        )

    def matches(self, cfg: VaultConfig) -> Tuple[bool, str]:
        if self.openbao and not cfg.is_openbao():
            return False, f"{self.name}: expected OpenBao-style namespace mount"
        if self.requires_namespace and not cfg.namespace.strip():
            return False, f"{self.name}: VAULT_NAMESPACE required"
        if not self.requires_namespace and cfg.namespace.strip() and not self.openbao:
            # hashicorp root — namespaced config still OK for enterprise profile
            if self.name == "hashicorp":
                return False, f"{self.name}: use hashicorp_enterprise when VAULT_NAMESPACE is set"
        return True, ""

    def readiness(self) -> Tuple[bool, str]:
        cfg = self.load_config()
        if cfg is None:
            return False, f"{self.name}: VAULT_ADDR not set"
        ok, reason = vault_runtime_ready(cfg)
        if not ok:
            return False, f"{self.name}: {reason}"
        match_ok, match_reason = self.matches(cfg)
        if not match_ok:
            return False, match_reason
        return True, ""


SUPPORTED_VAULT_KV_PROFILES: Dict[str, VaultKvProfile] = {
    "hashicorp": VaultKvProfile(
        name="hashicorp",
        vendor="HashiCorp Vault KV v2 (root)",
        notes="Non-namespaced dev / Docker vault",
    ),
    "hashicorp_enterprise": VaultKvProfile(
        name="hashicorp_enterprise",
        vendor="HashiCorp Vault Enterprise KV v2",
        notes="Namespaced mount (e.g. ns1/pg_tde)",
        requires_namespace=True,
    ),
    "openbao": VaultKvProfile(
        name="openbao",
        vendor="OpenBao KV v2",
        notes="Namespace + pg_tde mount (setup_openbao_for_pytest.sh)",
        requires_namespace=True,
        openbao=True,
    ),
}

ALL_VAULT_KV_PROFILE_NAMES: Tuple[str, ...] = tuple(SUPPORTED_VAULT_KV_PROFILES)


def default_vault_kv_profile() -> str:
    ns = os.environ.get("VAULT_NAMESPACE", "").strip()
    mount = os.environ.get("VAULT_SECRET_MOUNT", "").strip()
    if mount == "pg_tde" and "pg_tde_ns" in ns:
        return "openbao"
    if ns:
        return "hashicorp_enterprise"
    return "hashicorp"


def parse_vault_kv_profile_list(raw: str) -> List[str]:
    raw = (raw or "").strip()
    if not raw or raw.lower() == "auto":
        return [default_vault_kv_profile()]
    if raw.lower() == "all":
        return list(ALL_VAULT_KV_PROFILE_NAMES)
    return [p.strip().lower() for p in raw.replace(" ", ",").split(",") if p.strip()]


def resolve_vault_kv_profiles(raw: str) -> List[VaultKvProfile]:
    names = parse_vault_kv_profile_list(raw)
    out: List[VaultKvProfile] = []
    unknown: List[str] = []
    for name in names:
        if name not in SUPPORTED_VAULT_KV_PROFILES:
            unknown.append(name)
            continue
        prof = SUPPORTED_VAULT_KV_PROFILES[name]
        if prof not in out:
            out.append(prof)
    if unknown:
        raise ValueError(
            f"Unknown Vault KV profile(s): {', '.join(unknown)}. "
            f"Supported: {', '.join(ALL_VAULT_KV_PROFILE_NAMES)}, auto, all"
        )
    return out


def vault_kv_profiles_from_config(config) -> str:
    if config is not None:
        opt = config.getoption("--vault-kv-profile", default=None)
        if opt:
            return opt
    return os.environ.get("VAULT_KV_PROFILES") or os.environ.get("VAULT_KV_PROFILE") or "auto"


def configure_vault_kv_profile_parametrize(
    metafunc, *, fixture_name: str = "vault_kv_profile"
) -> None:
    if fixture_name not in metafunc.fixturenames:
        return
    import pytest

    raw = vault_kv_profiles_from_config(metafunc.config)
    try:
        profiles = resolve_vault_kv_profiles(raw)
    except ValueError as exc:
        raise pytest.UsageError(str(exc)) from exc
    metafunc.parametrize(fixture_name, profiles, ids=lambda p: p.name)
