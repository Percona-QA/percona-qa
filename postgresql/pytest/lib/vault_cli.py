"""Vault/OpenBao CLI helpers for pytest (KV export/import, tokens)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import List, Optional

from lib.vault import VaultConfig, create_openbao_kv_only_token


def resolve_vault_bin() -> Optional[Path]:
    """``vault`` on PATH or automation helper binary."""
    explicit = os.environ.get("VAULT_BIN", "")
    if explicit and Path(explicit).is_file():
        return Path(explicit)
    found = shutil.which("vault")
    if found:
        return Path(found)
    helper = (
        Path(__file__).resolve().parents[2]
        / "automation/helper_scripts/vault/vault"
    )
    if helper.is_file():
        return helper
    return None


def _read_token(cfg: VaultConfig) -> str:
    if cfg.token_path and Path(cfg.token_path).is_file():
        return Path(cfg.token_path).read_text(encoding="utf-8").strip()
    return (cfg.token or "").strip()


def vault_cli_env(cfg: VaultConfig, *, token: Optional[str] = None) -> dict:
    env = os.environ.copy()
    env["VAULT_ADDR"] = cfg.addr
    env["VAULT_TOKEN"] = token if token is not None else _read_token(cfg)
    env["VAULT_SKIP_VERIFY"] = os.environ.get("VAULT_SKIP_VERIFY", "true")
    if cfg.namespace.strip():
        env["VAULT_NAMESPACE"] = cfg.namespace.rstrip("/")
    return env


def kv_only_policy_body(secret_mount: str, *, openbao_style: bool) -> str:
    """HCL for token without ``sys/mounts`` (PG-1959 / mount-metadata tests)."""
    if openbao_style:
        return f'''path "{secret_mount}/data/*" {{
  capabilities = ["create", "read"]
}}

path "{secret_mount}/metadata/*" {{
  capabilities = ["read", "list"]
}}

path "sys/internal/ui/mounts/*" {{
  capabilities = []
}}

path "sys/mounts/*" {{
  capabilities = []
}}
'''
    return f'''path "{secret_mount}/data/*" {{
  capabilities = ["create", "read"]
}}

path "{secret_mount}/metadata/*" {{
  capabilities = ["read", "list"]
}}

path "sys/internal/ui/mounts/*" {{
  capabilities = []
}}

path "sys/mounts/*" {{
  capabilities = []
}}
'''


def create_hashicorp_kv_only_token(
    *,
    run_dir: Path,
    vault_bin: Path,
    root_token: str,
    vault_addr: str,
    secret_mount: str,
) -> Path:
    """
    Port of ``pg_tde_hashicorp_vault_mount_permission_warning_test.sh`` token policy.
    """
    run_dir.mkdir(parents=True, exist_ok=True)
    policy_path = run_dir / "policy_kv_only.hcl"
    token_path = run_dir / "token_kv_only"
    policy_path.write_text(
        kv_only_policy_body(secret_mount, openbao_style=False),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["VAULT_ADDR"] = vault_addr
    env["VAULT_TOKEN"] = root_token
    env["VAULT_SKIP_VERIFY"] = "true"
    subprocess.run(
        [str(vault_bin), "policy", "write", "kv_only", str(policy_path)],
        check=True,
        env=env,
        capture_output=True,
        text=True,
    )
    proc = subprocess.run(
        [
            str(vault_bin),
            "token",
            "create",
            "-policy=kv_only",
            "-no-default-policy",
            "-format=json",
        ],
        check=True,
        env=env,
        capture_output=True,
        text=True,
    )
    token_path.write_text(
        json.loads(proc.stdout)["auth"]["client_token"] + "\n",
        encoding="utf-8",
    )
    return token_path


def create_kv_only_token(
    *,
    cfg: VaultConfig,
    run_dir: Path,
    vault_bin: Optional[Path] = None,
    openbao_bin: Optional[Path] = None,
) -> Path:
    """OpenBao (``bao``) or HashiCorp (``vault``) restricted token."""
    root = _read_token(cfg)
    if cfg.is_openbao():
        bao = openbao_bin or Path(os.environ.get("OPENBAO_BIN", "bao"))
        if not bao.is_file():
            raise FileNotFoundError(f"OpenBao binary not found: {bao}")
        return create_openbao_kv_only_token(
            run_dir=run_dir,
            bao_bin=bao,
            root_token=root,
            namespace=cfg.namespace,
            secret_mount=cfg.secret_mount,
            vault_addr=cfg.addr,
        )
    vbin = vault_bin or resolve_vault_bin()
    if vbin is None:
        raise FileNotFoundError("vault CLI not found")
    return create_hashicorp_kv_only_token(
        run_dir=run_dir,
        vault_bin=vbin,
        root_token=root,
        vault_addr=cfg.addr,
        secret_mount=cfg.secret_mount,
    )


def vault_kv_list_keys(cfg: VaultConfig, vault_bin: Path) -> List[str]:
    proc = subprocess.run(
        [
            str(vault_bin),
            "kv",
            "list",
            "-format=json",
            f"{cfg.secret_mount}/",
        ],
        check=True,
        env=vault_cli_env(cfg),
        capture_output=True,
        text=True,
    )
    data = json.loads(proc.stdout or "[]")
    return list(data) if isinstance(data, list) else []


def vault_kv_export(cfg: VaultConfig, export_dir: Path, vault_bin: Path) -> None:
    """Export all KV secrets under ``cfg.secret_mount`` (bash change-provider script)."""
    export_dir.mkdir(parents=True, exist_ok=True)
    for key in vault_kv_list_keys(cfg, vault_bin):
        out = export_dir / f"{key}.json"
        with out.open("w", encoding="utf-8") as fh:
            subprocess.run(
                [
                    str(vault_bin),
                    "kv",
                    "get",
                    "-format=json",
                    f"{cfg.secret_mount}/{key}",
                ],
                check=True,
                env=vault_cli_env(cfg),
                stdout=fh,
                text=True,
            )


def vault_kv_import(cfg: VaultConfig, export_dir: Path, vault_bin: Path) -> None:
    """Re-import secrets from ``vault_kv_export`` JSON files."""
    for path in sorted(export_dir.glob("*.json")):
        key_name = path.stem
        payload = json.loads(path.read_text(encoding="utf-8"))
        inner = payload.get("data", {}).get("data", {})
        if not inner:
            continue
        args = [str(vault_bin), "kv", "put", f"{cfg.secret_mount}/{key_name}"]
        for k, v in inner.items():
            args.append(f"{k}={v}")
        subprocess.run(args, check=True, env=vault_cli_env(cfg), capture_output=True)


def vault_kv_delete_exported(
    cfg: VaultConfig, export_dir: Path, vault_bin: Path
) -> None:
    """Remove KV secrets that were exported (simulates a fresh Vault)."""
    for path in export_dir.glob("*.json"):
        subprocess.run(
            [
                str(vault_bin),
                "kv",
                "metadata",
                "delete",
                f"{cfg.secret_mount}/{path.stem}",
            ],
            check=True,
            env=vault_cli_env(cfg),
            capture_output=True,
            text=True,
        )
