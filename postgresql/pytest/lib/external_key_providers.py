"""
Auto-start Cosmian KMIP and OpenBao for pytest sessions.

Mirrors ``scripts/setup_cosmian_for_pytest.sh`` and
``scripts/setup_openbao_for_pytest.sh`` so ``pytest tests/`` works without
manually sourcing setup scripts in the same shell.

Opt out: ``PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS=1`` or
``--skip-sections=kmip,vault,openbao``.
"""
from __future__ import annotations

import atexit
import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

from lib.cosmian_kms import CosmianKmsServer, find_cosmian_binary
from lib.kmip import KmipConfig, kmip_runtime_ready
from lib.kmip_profiles import standard_kmip_env_config
from lib.vault import (
    VaultConfig,
    create_openbao_kv_only_token,
    vault_config_from_options,
    vault_runtime_ready,
)

OPENBAO_DEFAULT_ADDR = "http://127.0.0.1:8200"
OPENBAO_DEFAULT_MOUNT = "pg_tde"
OPENBAO_DEFAULT_NAMESPACE = "pg_tde_ns1"

_EXTERNAL_MARKERS = frozenset(
    {"vault", "openbao", "kmip", "kmip_revalidation", "kmip_matrix", "vault_kmip"}
)
_OPENBAO_MARKERS = frozenset({"vault", "openbao"})
_KMIP_MARKERS = frozenset({"kmip", "kmip_revalidation", "kmip_matrix", "vault_kmip"})

_session_servers: List[object] = []
_bootstrapped = False


def find_openbao_binary() -> Optional[Path]:
    override = os.environ.get("OPENBAO_BIN", "").strip()
    if override:
        p = Path(override)
        return p if p.is_file() and os.access(p, os.X_OK) else None
    for name in ("bao", "/usr/bin/bao", "/usr/local/bin/bao"):
        if "/" in name:
            p = Path(name)
            if p.is_file() and os.access(p, os.X_OK):
                return p
            continue
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def openbao_kv_mount_ready(cfg: VaultConfig) -> bool:
    """POST probe to the namespaced KV v2 mount (``openbao_env.sh`` parity)."""
    if not cfg.namespace.strip():
        return False
    token = ""
    if cfg.token_path and Path(cfg.token_path).is_file():
        token = Path(cfg.token_path).read_text(encoding="utf-8").strip()
    elif cfg.token:
        token = cfg.token.strip()
    if not token:
        return False
    url = f"{cfg.addr}/v1/{cfg.secret_mount}/data/pytest_mount_probe"
    data = json.dumps({"data": {"key": "dGVzdA=="}}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "X-Vault-Token": token,
            "X-Vault-Namespace": cfg.namespace,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            return resp.status in (200, 204)
    except urllib.error.HTTPError as e:
        return e.code in (200, 204)
    except OSError:
        return False


def openbao_pytest_env_ready() -> bool:
    cfg = vault_config_from_options(
        addr=os.environ.get("VAULT_ADDR", ""),
        token=os.environ.get("VAULT_TOKEN", ""),
        token_path=os.environ.get("VAULT_TOKEN_FILE", ""),
        secret_mount=os.environ.get("VAULT_SECRET_MOUNT", ""),
        namespace=os.environ.get("VAULT_NAMESPACE", ""),
        ca_path=os.environ.get("VAULT_CA_PATH", ""),
    )
    if cfg is None:
        return False
    ready, _ = vault_runtime_ready(cfg)
    return ready and bool(cfg.namespace.strip()) and openbao_kv_mount_ready(cfg)


def kmip_pytest_env_ready() -> bool:
    cfg = standard_kmip_env_config()
    if cfg is None:
        return False
    ready, _ = kmip_runtime_ready(cfg)
    return ready


def _should_auto_start(config) -> Tuple[bool, bool]:
    """Return ``(need_openbao, need_kmip)``."""
    if os.environ.get("PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS", "").strip().lower() in (
        "1",
        "yes",
        "true",
    ):
        return False, False

    skip_markers = getattr(config, "_skip_section_markers", frozenset())
    if _EXTERNAL_MARKERS <= skip_markers:
        return False, False

    need_openbao = not bool(_OPENBAO_MARKERS & skip_markers)
    need_kmip = not bool(_KMIP_MARKERS & skip_markers)
    return need_openbao, need_kmip


def _export_kmip_config(kmip: KmipConfig) -> None:
    os.environ["KMIP_SERVER_ADDRESS"] = kmip.host
    os.environ["KMIP_SERVER_PORT"] = str(kmip.port)
    os.environ["KMIP_CLIENT_CA"] = kmip.client_cert
    os.environ["KMIP_CLIENT_KEY"] = kmip.client_key
    os.environ["KMIP_SERVER_CA"] = kmip.server_ca
    os.environ.setdefault("KMIP_COSMIAN_HOST", kmip.host)
    os.environ.setdefault("KMIP_COSMIAN_PORT", str(kmip.port))
    os.environ.setdefault("KMIP_COSMIAN_CLIENT_CERT", kmip.client_cert)
    os.environ.setdefault("KMIP_COSMIAN_CLIENT_KEY", kmip.client_key)
    os.environ.setdefault("KMIP_COSMIAN_SERVER_CA", kmip.server_ca)
    os.environ.setdefault("KMIP_REVALIDATE_PROFILES", "cosmian")


def _bao_at_root(bao: Path, token: str, addr: str, *args: str) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.pop("VAULT_NAMESPACE", None)
    env["VAULT_ADDR"] = addr
    env["VAULT_TOKEN"] = token
    return subprocess.run(
        [str(bao), *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _bao_at_ns(
    bao: Path, token: str, addr: str, namespace: str, *args: str
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.pop("VAULT_NAMESPACE", None)
    env["VAULT_ADDR"] = addr
    env["VAULT_TOKEN"] = token
    env["VAULT_NAMESPACE"] = namespace
    return subprocess.run(
        [str(bao), *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _bootstrap_openbao_namespace(
    bao: Path,
    root_token: str,
    addr: str,
    namespace: str,
    mount: str,
) -> bool:
    if _bao_at_root(bao, root_token, addr, "namespace", "read", namespace).returncode != 0:
        proc = _bao_at_root(bao, root_token, addr, "namespace", "create", namespace)
        if proc.returncode != 0:
            listed = _bao_at_root(bao, root_token, addr, "namespace", "list", "-format=json")
            if f'"{namespace}/"' not in (listed.stdout or ""):
                return False

    listed = _bao_at_ns(bao, root_token, addr, namespace, "secrets", "list", "-format=json")
    if f'"{mount}/"' not in (listed.stdout or ""):
        proc = _bao_at_ns(
            bao,
            root_token,
            addr,
            namespace,
            "secrets",
            "enable",
            "-version=2",
            f"-path={mount}",
            "kv",
        )
        if proc.returncode != 0:
            return False
    return True


@dataclass
class OpenBaoDevServer:
    """Local ``bao server -dev`` with namespace + KV mount (pytest session scope)."""

    binary: Path
    run_dir: Path
    _proc: subprocess.Popen
    root_token: str
    token_file: Path
    log_path: Path

    @property
    def pid(self) -> int:
        return self._proc.pid

    @classmethod
    def start(cls, run_dir: Path) -> Optional[OpenBaoDevServer]:
        bao = find_openbao_binary()
        if bao is None:
            return None

        run_dir.mkdir(parents=True, exist_ok=True)
        log_path = run_dir / "bao_server.log"
        log_fh = log_path.open("w", encoding="utf-8")

        proc = subprocess.Popen(
            [str(bao), "server", "-dev", "-dev-listen-address=127.0.0.1:8200"],
            stdout=log_fh,
            stderr=subprocess.STDOUT,
        )

        root_token = ""
        deadline = time.time() + 20
        token_re = re.compile(r"Root Token:\s*(\S+)")
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"bao server exited early:\n{log_path.read_text(encoding='utf-8')}"
                )
            text = log_path.read_text(encoding="utf-8")
            match = token_re.search(text)
            if match:
                root_token = match.group(1)
                break
            time.sleep(0.3)

        if not root_token:
            proc.terminate()
            raise RuntimeError(f"could not read Root Token from {log_path}")

        token_file = run_dir / "bao_root_token"
        token_file.write_text(root_token + "\n", encoding="utf-8")

        if not _bootstrap_openbao_namespace(
            bao,
            root_token,
            OPENBAO_DEFAULT_ADDR,
            OPENBAO_DEFAULT_NAMESPACE,
            OPENBAO_DEFAULT_MOUNT,
        ):
            proc.terminate()
            raise RuntimeError("OpenBao namespace/mount bootstrap failed")

        os.environ["VAULT_ADDR"] = OPENBAO_DEFAULT_ADDR
        os.environ["VAULT_TOKEN_FILE"] = str(token_file)
        os.environ.pop("VAULT_TOKEN", None)
        os.environ["VAULT_SECRET_MOUNT"] = OPENBAO_DEFAULT_MOUNT
        os.environ["VAULT_NAMESPACE"] = f"{OPENBAO_DEFAULT_NAMESPACE}/"
        os.environ["OPENBAO_BIN"] = str(bao)

        cfg = vault_config_from_options(
            addr=OPENBAO_DEFAULT_ADDR,
            token_path=str(token_file),
            secret_mount=OPENBAO_DEFAULT_MOUNT,
            namespace=f"{OPENBAO_DEFAULT_NAMESPACE}/",
        )
        if cfg is None or not openbao_kv_mount_ready(cfg):
            proc.terminate()
            raise RuntimeError("OpenBao KV mount probe failed after bootstrap")

        try:
            kv_only = create_openbao_kv_only_token(
                run_dir=run_dir,
                bao_bin=bao,
                root_token=root_token,
                namespace=OPENBAO_DEFAULT_NAMESPACE,
                secret_mount=OPENBAO_DEFAULT_MOUNT,
                vault_addr=OPENBAO_DEFAULT_ADDR,
            )
            os.environ["VAULT_KV_ONLY_TOKEN_FILE"] = str(kv_only)
        except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError):
            os.environ.pop("VAULT_KV_ONLY_TOKEN_FILE", None)

        return cls(
            binary=bao,
            run_dir=run_dir,
            _proc=proc,
            root_token=root_token,
            token_file=token_file,
            log_path=log_path,
        )

    def stop(self) -> None:
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=5)


def _cleanup_session_servers() -> None:
    for server in _session_servers:
        stop = getattr(server, "stop", None)
        if callable(stop):
            try:
                stop()
            except OSError:
                pass
    _session_servers.clear()


def _start_cosmian_if_needed(run_dir: Path) -> Optional[str]:
    if kmip_pytest_env_ready():
        return None
    if find_cosmian_binary() is None:
        return "cosmian_kms not installed (run scripts/install_cosmian_kms.sh)"
    work = run_dir / "cosmian_session"
    server = CosmianKmsServer.start(work)
    if server is None:
        return "failed to start cosmian_kms"
    _export_kmip_config(server.to_kmip_config())
    _session_servers.append(server)
    return None


def _start_openbao_if_needed(run_dir: Path) -> Optional[str]:
    if openbao_pytest_env_ready():
        return None
    if find_openbao_binary() is None:
        return "bao not installed (run scripts/install_openbao.sh)"
    try:
        server = OpenBaoDevServer.start(run_dir / "openbao_session")
    except RuntimeError as exc:
        return str(exc)
    if server is None:
        return "failed to start OpenBao dev server"
    _session_servers.append(server)
    return None


def sync_external_key_provider_cli_options(config) -> None:
    """Push bootstrapped env vars into pytest ``config.option`` (post-parse)."""
    opt = config.option
    pairs = (
        ("vault_addr", "VAULT_ADDR"),
        ("vault_token", "VAULT_TOKEN"),
        ("vault_namespace", "VAULT_NAMESPACE"),
        ("vault_secret_mount", "VAULT_SECRET_MOUNT"),
        ("vault_token_file", "VAULT_TOKEN_FILE"),
        ("vault_ca_path", "VAULT_CA_PATH"),
        ("vault_kv_only_token_file", "VAULT_KV_ONLY_TOKEN_FILE"),
        ("openbao_bin", "OPENBAO_BIN"),
        ("kmip_server_address", "KMIP_SERVER_ADDRESS"),
        ("kmip_server_port", "KMIP_SERVER_PORT"),
        ("kmip_client_ca", "KMIP_CLIENT_CA"),
        ("kmip_client_key", "KMIP_CLIENT_KEY"),
        ("kmip_server_ca", "KMIP_SERVER_CA"),
    )
    for attr, env_name in pairs:
        if hasattr(opt, attr) and os.environ.get(env_name):
            setattr(opt, attr, os.environ[env_name])


def ensure_external_key_providers(config) -> List[str]:
    """
    Start Cosmian KMIP and/or OpenBao when needed for the current pytest run.

    Returns human-readable warnings (empty when everything requested is ready).
    """
    global _bootstrapped
    if _bootstrapped:
        return []
    _bootstrapped = True
    atexit.register(_cleanup_session_servers)

    need_openbao, need_kmip = _should_auto_start(config)
    if not need_openbao and not need_kmip:
        return []

    run_dir = Path(config.getoption("--run-dir"))
    warnings: List[str] = []

    if need_kmip:
        err = _start_cosmian_if_needed(run_dir)
        if err:
            warnings.append(f"KMIP (Cosmian): {err}")

    if need_openbao:
        err = _start_openbao_if_needed(run_dir)
        if err:
            warnings.append(f"OpenBao: {err}")

    sync_external_key_provider_cli_options(config)
    return warnings
