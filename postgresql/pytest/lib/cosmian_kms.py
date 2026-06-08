"""
Local Cosmian KMS for pytest — Python port of pg_tde ``t/CosmianKms.pm``.

Used for full ``t/kmip.pl`` parity (including restart with an empty KMIP DB).
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from lib.kmip import KmipConfig


def find_cosmian_binary() -> Optional[Path]:
    override = os.environ.get("COSMIAN_KMS_BIN", "").strip()
    if override:
        p = Path(override)
        return p if p.is_file() and os.access(p, os.X_OK) else None
    for name in ("cosmian_kms", "/usr/sbin/cosmian_kms", "/usr/local/bin/cosmian_kms"):
        if "/" in name:
            p = Path(name)
            if p.is_file() and os.access(p, os.X_OK):
                return p
            continue
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _run_openssl(args: list[str]) -> None:
    subprocess.run(args, check=True, capture_output=True)


def gen_certs(cert_dir: Path) -> None:
    """Mirror ``CosmianKms::gen_certs`` (CA, server, client PEMs + server.p12)."""
    cert_dir.mkdir(parents=True, exist_ok=True)
    ca_key = cert_dir / "ca.key"
    ca_pem = cert_dir / "ca.pem"
    _run_openssl([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-keyout", str(ca_key), "-out", str(ca_pem),
        "-subj", "/CN=pg_tde-test-ca",
    ])
    server_key = cert_dir / "server.key"
    server_csr = cert_dir / "server.csr"
    server_pem = cert_dir / "server.pem"
    _run_openssl([
        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(server_key), "-out", str(server_csr),
        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
    ])
    _run_openssl([
        "openssl", "x509", "-req", "-in", str(server_csr),
        "-CA", str(ca_pem), "-CAkey", str(ca_key), "-CAcreateserial",
        "-days", "1", "-out", str(server_pem), "-copy_extensions", "copy",
    ])
    _run_openssl([
        "openssl", "pkcs12", "-export", "-out", str(cert_dir / "server.p12"),
        "-inkey", str(server_key), "-in", str(server_pem),
        "-password", "pass:test",
    ])
    client_key = cert_dir / "client.key"
    client_csr = cert_dir / "client.csr"
    client_pem = cert_dir / "client.pem"
    _run_openssl([
        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(client_key), "-out", str(client_csr),
        "-subj", "/CN=pg_tde-client",
    ])
    _run_openssl([
        "openssl", "x509", "-req", "-in", str(client_csr),
        "-CA", str(ca_pem), "-CAkey", str(ca_key), "-CAcreateserial",
        "-days", "1", "-out", str(client_pem),
    ])


def _openssl_modules_env() -> dict[str, str]:
    env = {}
    if os.environ.get("OPENSSL_MODULES"):
        return env
    for d in (
        "/usr/local/cosmian/lib/ossl-modules",
        "/usr/lib64/ossl-modules",
        "/usr/lib/x86_64-linux-gnu/ossl-modules",
        "/usr/lib/aarch64-linux-gnu/ossl-modules",
    ):
        if Path(d).is_dir():
            env["OPENSSL_MODULES"] = d
            break
    return env


def _write_kms_toml(work_dir: Path, kmip_port: int, http_port: int) -> Path:
    toml = work_dir / "kms.toml"
    db_path = work_dir / "db"
    content = f"""default_username = "admin"

[db]
database_type = "sqlite"
sqlite_path   = "{db_path}"
clear_database = true

[tls]
tls_p12_file         = "{work_dir / 'server.p12'}"
tls_p12_password     = "test"
clients_ca_cert_file = "{work_dir / 'ca.pem'}"

[socket_server]
socket_server_start    = true
socket_server_port     = {kmip_port}
socket_server_hostname = "127.0.0.1"

[http]
port     = {http_port}
hostname = "127.0.0.1"

[logging]
rust_log = "info,cosmian_kms=info"
"""
    toml.write_text(content)
    return toml


def _wait_http_ready(http_port: int, proc: subprocess.Popen, stderr_path: Path) -> None:
    deadline = time.time() + 15
    while time.time() < deadline:
        if proc.poll() is not None:
            err = stderr_path.read_text() if stderr_path.is_file() else ""
            raise RuntimeError(f"cosmian_kms exited early:\n{err}")
        rc = subprocess.run(
            ["curl", "-fsSk", "-m", "1", f"https://127.0.0.1:{http_port}/version"],
            capture_output=True,
            check=False,
        )
        if rc.returncode == 0:
            return
        time.sleep(0.2)
    err = stderr_path.read_text() if stderr_path.is_file() else ""
    raise RuntimeError(
        f"cosmian_kms readiness timed out (http={http_port})\n{err}"
    )


@dataclass
class CosmianKmsServer:
    """Running ``cosmian_kms`` process with TLS material under ``work_dir``."""

    binary: Path
    work_dir: Path
    kmip_port: int
    http_port: int
    _proc: subprocess.Popen
    _stderr_path: Path

    @classmethod
    def start(cls, work_dir: Path) -> Optional[CosmianKmsServer]:
        binary = find_cosmian_binary()
        if binary is None:
            return None
        gen_certs(work_dir)
        kmip_port = _free_port()
        http_port = _free_port()
        return cls._spawn(binary, work_dir, kmip_port, http_port)

    @classmethod
    def _spawn(
        cls,
        binary: Path,
        work_dir: Path,
        kmip_port: int,
        http_port: int,
    ) -> CosmianKmsServer:
        _write_kms_toml(work_dir, kmip_port, http_port)
        stderr_path = work_dir / "kms.stderr"
        stderr_fh = stderr_path.open("w")
        env = os.environ.copy()
        env.update(_openssl_modules_env())
        proc = subprocess.Popen(
            [str(binary), "-c", str(work_dir / "kms.toml")],
            stdout=subprocess.DEVNULL,
            stderr=stderr_fh,
            env=env,
        )
        stderr_fh.close()
        _wait_http_ready(http_port, proc, stderr_path)
        return cls(
            binary=binary,
            work_dir=work_dir,
            kmip_port=kmip_port,
            http_port=http_port,
            _proc=proc,
            _stderr_path=stderr_path,
        )

    def stop(self) -> None:
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=5)

    def restart_fresh(self) -> None:
        """Stop and start on the same ports with ``clear_database = true`` (t/kmip.pl)."""
        self.stop()
        fresh = CosmianKmsServer._spawn(
            self.binary, self.work_dir, self.kmip_port, self.http_port
        )
        self._proc = fresh._proc
        self._stderr_path = fresh._stderr_path

    def to_kmip_config(self) -> KmipConfig:
        d = self.work_dir
        return KmipConfig(
            host="127.0.0.1",
            port=self.kmip_port,
            client_cert=str(d / "client.pem"),
            client_key=str(d / "client.key"),
            server_ca=str(d / "ca.pem"),
        )
