"""Root conftest: CLI options, session-scoped paths, and shared helpers."""
import os
import shutil
import socket
import threading
from pathlib import Path

import pytest

from lib.backup import pgbackrest_installed
from lib.cluster import (
    IO_METHOD_LEGACY_PLACEHOLDER,
    IO_METHOD_VALUES,
    PG_IO_METHOD_MIN_MAJOR,
    io_method_guc_supported,
    io_method_param_values,
)

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
        default=os.environ.get("INSTALL_DIR", "/usr/lib/postgresql/18"),
        help="Path to the PostgreSQL installation (e.g. /opt/percona/pg18)",
    )
    parser.addoption(
        "--run-dir",
        default=os.environ.get("RUN_DIR", "/tmp/pgtest_pytest"),
        help="Base directory for per-test cluster data directories",
    )
    parser.addoption(
        "--io-method",
        default=os.environ.get("IO_METHOD", "worker"),
        choices=list(IO_METHOD_VALUES),
        help=(
            f"PostgreSQL {PG_IO_METHOD_MIN_MAJOR}+ io_method GUC only "
            f"({', '.join(IO_METHOD_VALUES)}). Ignored on older majors and "
            "when --io-method-matrix is set."
        ),
    )
    parser.addoption(
        "--io-method-matrix",
        action="store_true",
        default=False,
        help=(
            f"PostgreSQL {PG_IO_METHOD_MIN_MAJOR}+ only: run each test that uses "
            "io_method once per "
            f"{', '.join(IO_METHOD_VALUES)}. No-op on PG 17 and below."
        ),
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
        "--vault-namespace",
        default=os.environ.get("VAULT_NAMESPACE", ""),
        help="Vault/OpenBao namespace (optional)",
    )
    parser.addoption(
        "--kmip-server-address",
        default=os.environ.get("KMIP_SERVER_ADDRESS", ""),
        help="KMIP server address (required for kmip tests)",
    )
    parser.addoption(
        "--kmip-server-port",
        default=os.environ.get("KMIP_SERVER_PORT", ""),
        help="KMIP server port (required for kmip tests)",
    )
    parser.addoption(
        "--kmip-client-ca",
        default=os.environ.get("KMIP_CLIENT_CA", ""),
        help="KMIP client certificate path",
    )
    parser.addoption(
        "--kmip-client-key",
        default=os.environ.get("KMIP_CLIENT_KEY", ""),
        help="KMIP client private key path",
    )
    parser.addoption(
        "--kmip-server-ca",
        default=os.environ.get("KMIP_SERVER_CA", ""),
        help="KMIP server CA certificate path",
    )
    parser.addoption(
        "--old-install-dir",
        default=os.environ.get("OLD_INSTALL_DIR", ""),
        help="Older PG installation used as the upgrade source",
    )
    parser.addoption(
        "--upgrade-data-dir",
        default=os.environ.get("PG_TDE_UPGRADE_DATA_DIR", ""),
        help=(
            "Persistent base directory for staged pg_tde minor-upgrade "
            "tests. Setup run writes PGDATA + state.json under this "
            "directory using --install-dir = OLD; the operator performs "
            "the package upgrade externally; the Verify run reads the "
            "same directory using --install-dir = NEW. CLI flag overrides "
            "the PG_TDE_UPGRADE_DATA_DIR env var."
        ),
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


def pytest_configure(config):
    """Reject non-default ``io_method`` when ``--install-dir`` is PG 17 or older."""
    install_dir = Path(config.getoption("--install-dir"))
    try:
        if io_method_guc_supported(install_dir):
            return
    except (OSError, ValueError, IndexError):
        return

    method = config.getoption("--io-method")
    if config.getoption("--io-method-matrix"):
        config._io_method_pg17_note = (  # noqa: SLF001 — pytest config bag
            f"--io-method-matrix ignored: {install_dir} is not PostgreSQL "
            f"{PG_IO_METHOD_MIN_MAJOR}+ (io_method GUC does not exist)"
        )
    if method != IO_METHOD_LEGACY_PLACEHOLDER:
        pytest.exit(
            f"--io-method={method!r} requires PostgreSQL {PG_IO_METHOD_MIN_MAJOR}+ "
            f"under --install-dir={install_dir}; on older versions omit the flag.",
            returncode=2,
        )


def pytest_report_header(config):
    note = getattr(config, "_io_method_pg17_note", None)
    if note:
        return [note]
    return []


def pytest_generate_tests(metafunc):
    """Parametrize ``io_method`` (PG 18+ matrix or single value; PG 17 → worker only)."""
    if "io_method" not in metafunc.fixturenames:
        return
    config = metafunc.config
    install_dir = Path(config.getoption("--install-dir"))
    try:
        values = io_method_param_values(
            install_dir,
            matrix=config.getoption("--io-method-matrix"),
            single=config.getoption("--io-method"),
        )
    except (OSError, ValueError, IndexError):
        # Install tree absent at collection time; defer major check to test run.
        values = (
            list(IO_METHOD_VALUES)
            if config.getoption("--io-method-matrix")
            else [config.getoption("--io-method")]
        )
    metafunc.parametrize(
        "io_method",
        values,
        ids=[f"io={v}" for v in values],
    )


@pytest.fixture(autouse=True)
def _skip_unsupported_io_method(request, install_dir):
    """Skip ``io_uring`` when the build lacks liburing; PG 17 never runs sync/io_uring."""
    if "io_method" not in request.fixturenames:
        return
    from lib.cluster import io_method_guc_supported, io_method_usable

    method = request.getfixturevalue("io_method")
    if not io_method_guc_supported(install_dir):
        if method != IO_METHOD_LEGACY_PLACEHOLDER:
            pytest.skip(
                f"io_method={method!r} applies only to PostgreSQL "
                f"{PG_IO_METHOD_MIN_MAJOR}+"
            )
        return
    if not io_method_usable(install_dir, method):
        pytest.skip(
            f"io_method={method!r} is not supported by {install_dir} "
            "(io_uring needs --with-liburing)"
        )


@pytest.fixture(scope="session")
def vault_addr(request) -> str:
    return request.config.getoption("--vault-addr")


@pytest.fixture(scope="session")
def vault_token(request) -> str:
    return request.config.getoption("--vault-token")


@pytest.fixture(scope="session")
def vault_namespace(request) -> str:
    return request.config.getoption("--vault-namespace")


@pytest.fixture(scope="session")
def kmip_server_address(request) -> str:
    return request.config.getoption("--kmip-server-address")


@pytest.fixture(scope="session")
def kmip_server_port(request) -> str:
    return request.config.getoption("--kmip-server-port")


@pytest.fixture(scope="session")
def kmip_client_ca(request) -> str:
    return request.config.getoption("--kmip-client-ca")


@pytest.fixture(scope="session")
def kmip_client_key(request) -> str:
    return request.config.getoption("--kmip-client-key")


@pytest.fixture(scope="session")
def kmip_server_ca(request) -> str:
    return request.config.getoption("--kmip-server-ca")


@pytest.fixture(scope="session")
def old_install_dir(request) -> Path:
    v = request.config.getoption("--old-install-dir")
    return Path(v) if v else None


@pytest.fixture(scope="session")
def upgrade_data_dir(request):
    """Persistent base directory for staged pg_tde minor-upgrade tests.

    The Setup run prepares ``<upgrade_data_dir>/single/`` (or
    ``<upgrade_data_dir>/ha/``); the operator performs the package
    upgrade externally; the Verify run reads the same directory back.

    Returns ``None`` if neither the ``--upgrade-data-dir`` CLI flag
    nor the ``PG_TDE_UPGRADE_DATA_DIR`` env var is set; staged tests
    skip in that case.
    """
    v = request.config.getoption("--upgrade-data-dir")
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
    kmip_addr = config.getoption("--kmip-server-address")
    old_dir = config.getoption("--old-install-dir")
    upgrade_data_dir = config.getoption("--upgrade-data-dir")

    skip_vault = pytest.mark.skip(reason="--vault-addr not provided")
    skip_kmip = pytest.mark.skip(reason="--kmip-server-address not provided")
    skip_upgrade = pytest.mark.skip(reason="--old-install-dir not provided")
    skip_minor_upgrade = pytest.mark.skip(
        reason="--upgrade-data-dir not provided (or set PG_TDE_UPGRADE_DATA_DIR)"
    )
    skip_docker = pytest.mark.skip(reason="docker not found in PATH")
    skip_pgbackrest = pytest.mark.skip(reason="pgbackrest not installed or not on PATH")
    io_matrix = config.getoption("--io-method-matrix")
    skip_io_matrix_staged = pytest.mark.skip(
        reason=(
            "--io-method-matrix is incompatible with staged minor_upgrade "
            "(PGDATA is tied to the io_method used during Setup)"
        )
    )

    docker_available = shutil.which("docker") is not None
    pgbr_ok = pgbackrest_installed()

    for item in items:
        if io_matrix and "minor_upgrade" in item.keywords:
            item.add_marker(skip_io_matrix_staged)
        if "vault" in item.keywords and not vault_addr:
            item.add_marker(skip_vault)
        if "kmip" in item.keywords and not kmip_addr:
            item.add_marker(skip_kmip)
        if "upgrade" in item.keywords and not old_dir:
            item.add_marker(skip_upgrade)
        if "minor_upgrade" in item.keywords and not upgrade_data_dir:
            item.add_marker(skip_minor_upgrade)
        if "docker" in item.keywords and not docker_available:
            item.add_marker(skip_docker)
        if "pgbackrest" in item.keywords and not pgbr_ok:
            item.add_marker(skip_pgbackrest)
