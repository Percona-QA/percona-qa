"""Root conftest: CLI options, session-scoped paths, and shared helpers."""
import os
import shutil
import socket
import threading
from pathlib import Path

import pytest

# ── port allocator ──────────────────────────────────────────────────────────

_port_lock = threading.Lock()
_next_port = 15432


def allocate_port() -> int:
    """Return a port number that is currently free on localhost."""
    global _next_port
    with _port_lock:
        for _ in range(100):
            port = _next_port
            _next_port += 1
            with socket.socket() as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind(("127.0.0.1", port))
                    return port
                except OSError:
                    continue
    raise RuntimeError("Could not find a free port")


# ── CLI options ─────────────────────────────────────────────────────────────


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--install-dir",
        default=os.environ.get("INSTALL_DIR", "/usr/lib/postgresql/17"),
        help="Path to the PostgreSQL installation (e.g. /opt/percona/pg17)",
    )
    parser.addoption(
        "--run-dir",
        default=os.environ.get("RUN_DIR", "/tmp/pgtest_pytest"),
        help="Base directory for per-test cluster data directories",
    )
    parser.addoption(
        "--io-method",
        default=os.environ.get("IO_METHOD", "worker"),
        choices=["worker", "mmap", "posix"],
        help="PostgreSQL I/O method (only relevant for PG 18+)",
    )
    parser.addoption(
        "--vault-addr",
        default=os.environ.get("VAULT_ADDR", ""),
        help="HashiCorp Vault / OpenBao address (required for vault tests)",
    )
    parser.addoption(
        "--vault-token",
        default=os.environ.get("VAULT_TOKEN", ""),
        help="Vault root token",
    )
    parser.addoption(
        "--old-install-dir",
        default=os.environ.get("OLD_INSTALL_DIR", ""),
        help="Older PG installation used as the upgrade source",
    )


# ── session fixtures ─────────────────────────────────────────────────────────


@pytest.fixture(scope="session")
def install_dir(request) -> Path:
    return Path(request.config.getoption("--install-dir"))


@pytest.fixture(scope="session")
def run_dir(request) -> Path:
    p = Path(request.config.getoption("--run-dir"))
    p.mkdir(parents=True, exist_ok=True)
    return p


@pytest.fixture(scope="session")
def io_method(request) -> str:
    return request.config.getoption("--io-method")


@pytest.fixture(scope="session")
def vault_addr(request) -> str:
    return request.config.getoption("--vault-addr")


@pytest.fixture(scope="session")
def vault_token(request) -> str:
    return request.config.getoption("--vault-token")


@pytest.fixture(scope="session")
def old_install_dir(request) -> Path:
    v = request.config.getoption("--old-install-dir")
    return Path(v) if v else None


# ── port fixture ─────────────────────────────────────────────────────────────


@pytest.fixture
def free_port() -> int:
    """Return a single free TCP port."""
    return allocate_port()


@pytest.fixture
def two_free_ports():
    """Return two free TCP ports (primary, replica)."""
    return allocate_port(), allocate_port()


# ── skip helpers ─────────────────────────────────────────────────────────────


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """Attach the per-phase result to the item so fixtures can read it."""
    outcome = yield
    rep = outcome.get_result()
    setattr(item, f"rep_{call.when}", rep)


def pytest_collection_modifyitems(config, items):
    vault_addr = config.getoption("--vault-addr")
    old_dir = config.getoption("--old-install-dir")

    skip_vault = pytest.mark.skip(reason="--vault-addr not provided")
    skip_upgrade = pytest.mark.skip(reason="--old-install-dir not provided")
    skip_docker = pytest.mark.skip(reason="docker not found in PATH")

    docker_available = shutil.which("docker") is not None

    for item in items:
        if "vault" in item.keywords and not vault_addr:
            item.add_marker(skip_vault)
        if "upgrade" in item.keywords and not old_dir:
            item.add_marker(skip_upgrade)
        if "docker" in item.keywords and not docker_available:
            item.add_marker(skip_docker)
