"""HashiCorp Vault / OpenBao configuration helpers for pytest."""
from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Optional, Tuple


def _esc(value: str) -> str:
    return value.replace("'", "''")


@dataclass(frozen=True)
class VaultConfig:
    """
    Settings for ``pg_tde_add_*_key_provider_vault_v2``.

    The 4th SQL argument is a **token file path** in automation/bash; inline
    ``token`` is written to ``token_path`` when only a token string is given.
    """

    addr: str
    secret_mount: str = "secret"
    token: str = ""
    token_path: str = ""
    ca_path: str = ""
    namespace: str = ""

    def token_sql_arg(self, tmp_path: Optional[Path] = None) -> str:
        """Return token path for SQL (create temp file from inline token if needed)."""
        if self.token_path and Path(self.token_path).is_file():
            return self.token_path
        if self.token:
            if tmp_path is None:
                return self.token
            p = tmp_path / "vault_token_file"
            p.write_text(self.token.strip() + "\n", encoding="utf-8")
            return str(p)
        return ""

    def is_openbao(self) -> bool:
        return bool(self.namespace.strip())

    def with_token_path(self, token_path: str) -> VaultConfig:
        """Copy with a different on-disk token (PG-1959 restricted-policy tests)."""
        return replace(self, token_path=token_path, token="")


def create_openbao_kv_only_token(
    *,
    run_dir: Path,
    bao_bin: Path,
    root_token: str,
    namespace: str,
    secret_mount: str,
    vault_addr: str,
) -> Path:
    """
    Token that may read/write KV secrets but cannot list mount metadata.

    Port of ``pg_tde_openbao_vault_mount_permission_warning_test.sh`` /
    PG-1959 ([PR #492](https://github.com/percona/pg_tde/pull/492) parser fix).
    """
    run_dir.mkdir(parents=True, exist_ok=True)
    policy_path = run_dir / "policy_kv_only.hcl"
    token_path = run_dir / "token_kv_only"
    policy_path.write_text(
        f'''path "{secret_mount}/data/*" {{
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
''',
        encoding="utf-8",
    )
    ns = namespace.rstrip("/")
    env = os.environ.copy()
    env["VAULT_ADDR"] = vault_addr
    env["VAULT_TOKEN"] = root_token
    env["VAULT_NAMESPACE"] = ns
    subprocess.run(
        [str(bao_bin), "policy", "write", "kv_only", str(policy_path)],
        check=True,
        env=env,
        capture_output=True,
        text=True,
    )
    token_env = dict(env)
    proc = subprocess.run(
        [
            str(bao_bin),
            "token",
            "create",
            "-policy=kv_only",
            "-no-default-policy",
            "-format=json",
        ],
        check=True,
        env=token_env,
        capture_output=True,
        text=True,
    )
    token_path.write_text(
        json.loads(proc.stdout)["auth"]["client_token"] + "\n",
        encoding="utf-8",
    )
    return token_path


def vault_config_from_options(
    *,
    addr: str,
    token: str = "",
    token_path: str = "",
    secret_mount: str = "",
    ca_path: str = "",
    namespace: str = "",
) -> Optional[VaultConfig]:
    if not addr:
        return None
    return VaultConfig(
        addr=addr.rstrip("/"),
        secret_mount=secret_mount or "secret",
        token=token,
        token_path=token_path,
        ca_path=ca_path,
        namespace=namespace,
    )


def vault_runtime_ready(cfg: VaultConfig) -> Tuple[bool, str]:
    """HTTP health check (Vault and OpenBao expose ``/v1/sys/health``)."""
    if not cfg.addr:
        return False, "VAULT_ADDR / --vault-addr not set"

    token_arg = cfg.token_path or cfg.token
    if not token_arg:
        return False, "VAULT_TOKEN or --vault-token-file not set"

    if cfg.token_path and not Path(cfg.token_path).is_file():
        return False, f"vault token file missing: {cfg.token_path}"

    url = f"{cfg.addr}/v1/sys/health"
    req = urllib.request.Request(url)
    if cfg.token and not cfg.token_path:
        req.add_header("X-Vault-Token", cfg.token)
    elif cfg.token_path:
        tok = Path(cfg.token_path).read_text(encoding="utf-8").strip()
        req.add_header("X-Vault-Token", tok)
    # Cluster health is not namespace-scoped; OpenBao returns HTTP 400 if
    # X-Vault-Namespace is set on /v1/sys/health (pytest openbao skip).

    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            if resp.status not in (200, 429, 472, 473, 501, 503):
                return False, f"vault health HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        if e.code in (429, 472, 473, 501, 503):
            return True, ""
        return False, f"vault health check failed: {e}"
    except OSError as e:
        hint = (
            "run scripts/setup_openbao_for_pytest.sh (OpenBao) or "
            "scripts/setup_vault_for_pytest.sh / docker compose up vault"
        )
        if cfg.namespace.strip():
            hint = "run scripts/setup_openbao_for_pytest.sh (OpenBao namespace tests)"
        return False, f"cannot reach {cfg.addr} ({e}); {hint}"

    return True, ""
