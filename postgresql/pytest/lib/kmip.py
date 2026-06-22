"""KMIP test-server configuration helpers (pytest + bash parity)."""
from __future__ import annotations

import os
import socket
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass(frozen=True)
class KmipConfig:
    """
    Connection parameters for ``pg_tde_add_*_key_provider_kmip``.

    Names match ``conftest.py`` CLI flags / env vars.  ``client_cert`` is the
    client certificate PEM (bash: ``kmip_client_ca``); ``server_ca`` is the
    CA used to verify the KMIP server (bash: ``kmip_server_ca``).
    """

    host: str
    port: int
    client_cert: str
    client_key: str
    server_ca: str = ""

    def connect_host(self) -> str:
        """Host string passed to pg_tde (map Docker ``0.0.0.0`` → ``127.0.0.1``)."""
        if self.host in ("0.0.0.0", ""):
            return "127.0.0.1"
        return self.host

    def sql_literal_paths(self) -> Tuple[str, str, str]:
        """(cert_path, key_path, ca_path) with single quotes escaped."""
        def esc(p: str) -> str:
            return p.replace("'", "''")

        return esc(self.client_cert), esc(self.client_key), esc(self.server_ca or "")


def kmip_config_from_options(
    *,
    host: str,
    port: str,
    client_cert: str,
    client_key: str,
    server_ca: str = "",
) -> Optional[KmipConfig]:
    if not host:
        return None
    try:
        port_i = int(port or "5696")
    except ValueError:
        return None
    return KmipConfig(
        host=host,
        port=port_i,
        client_cert=client_cert,
        client_key=client_key,
        server_ca=server_ca,
    )


def kmip_runtime_ready(config: KmipConfig) -> Tuple[bool, str]:
    """
    Return (ready, reason).  Checks cert files and TCP reachability on
    ``connect_host():port`` (best-effort; KMIP may still be starting).
    """
    for label, path in (
        ("client cert", config.client_cert),
        ("client key", config.client_key),
    ):
        if not path:
            return False, f"KMIP {label} path not set"
        p = Path(path)
        if not p.is_file():
            return False, f"KMIP {label} missing: {path}"

    if config.server_ca:
        if not Path(config.server_ca).is_file():
            return False, f"KMIP server CA missing: {config.server_ca}"

    try:
        with socket.create_connection(
            (config.connect_host(), config.port), timeout=3.0
        ):
            pass
    except OSError as e:
        if os.environ.get("KMIP_VAULT_HOST"):
            hint = "source scripts/setup_vault_kmip_for_pytest.sh (Vault KMIP engine)"
        else:
            hint = "source scripts/setup_cosmian_for_pytest.sh"
        return False, (
            f"cannot reach KMIP at {config.connect_host()}:{config.port} ({e}); {hint}"
        )

    return True, ""
