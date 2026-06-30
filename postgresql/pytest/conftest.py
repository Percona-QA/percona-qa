"""Root conftest: CLI options, session-scoped paths, and shared helpers."""
import os
import shutil
import socket
import threading
from pathlib import Path

import pytest

from lib.backup import pgbackrest_installed
from lib.test_sections import (
    resolve_skip_sections,
    sections_help_text,
    markers_for_sections,
    item_matches_skipped_section,
)
from lib.kmip import kmip_config_from_options, kmip_runtime_ready
from lib.kmip_profiles import resolve_session_kmip_config
from lib.vault import vault_config_from_options, vault_runtime_ready
from lib.vault_kmip import vault_kmip_config_from_env, vault_kmip_runtime_ready
from lib.cluster import (
    IO_METHOD_LEGACY_PLACEHOLDER,
    IO_METHOD_VALUES,
    PG_IO_METHOD_MIN_MAJOR,
    install_version_summary_lines,
    io_method_guc_supported,
    io_method_param_values,
    io_methods_available,
    io_method_usable,
    io_uring_build_supported,
    io_uring_runtime_ready,
    io_uring_status_lines,
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
        help="Vault/OpenBao namespace (optional; required for @pytest.mark.openbao)",
    )
    parser.addoption(
        "--vault-secret-mount",
        default=os.environ.get("VAULT_SECRET_MOUNT", ""),
        help="KV mount point (default: secret; OpenBao setup uses pg_tde)",
    )
    parser.addoption(
        "--vault-token-file",
        default=os.environ.get("VAULT_TOKEN_FILE", ""),
        help="Path to Vault token file (preferred over inline --vault-token)",
    )
    parser.addoption(
        "--vault-ca-path",
        default=os.environ.get("VAULT_CA_PATH", ""),
        help="CA bundle for HTTPS Vault (optional)",
    )
    parser.addoption(
        "--vault-kv-only-token-file",
        default=os.environ.get("VAULT_KV_ONLY_TOKEN_FILE", ""),
        help="Restricted OpenBao token (PG-1959 mount-metadata test)",
    )
    parser.addoption(
        "--openbao-bin",
        default=os.environ.get("OPENBAO_BIN", ""),
        help="Path to ``bao`` CLI (for creating PG-1959 kv-only token in tests)",
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
        "--kmip-profile",
        default=os.environ.get("KMIP_PROFILE", ""),
        help=(
            "Single KMIP server profile (default: cosmian — no license). "
            "Overrides KMIP_REVALIDATE_PROFILES for one backend, e.g. vault_kmip, fortanix"
        ),
    )
    parser.addoption(
        "--kmip-revalidate-profiles",
        default=os.environ.get("KMIP_REVALIDATE_PROFILES", ""),
        help=(
            "KMIP server revalidation profiles (comma-separated or 'all'); "
            "default cosmian when unset — see docs/kmip/README.md"
        ),
    )
    parser.addoption(
        "--vault-kv-profile",
        default=os.environ.get("VAULT_KV_PROFILES", "")
        or os.environ.get("VAULT_KV_PROFILE", ""),
        help=(
            "Vault KV profile(s): hashicorp, hashicorp_enterprise, openbao, "
            "auto, all — see docs/key_provider_matrix.md"
        ),
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
    parser.addoption(
        "--skip-sections",
        default=os.environ.get("SKIP_SECTIONS", ""),
        metavar="LIST",
        help=(
            "Comma-separated test sections to skip (user-controlled). "
            f"{sections_help_text()}. "
            "Aliases: pg_rewind, pg_tde_rewind → rewind. "
            "Env: SKIP_SECTIONS. See docs/test_sections.md."
        ),
    )
    parser.addoption(
        "--list-test-sections",
        action="store_true",
        default=False,
        help="Print available section names and exit.",
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
    if config.getoption("--list-test-sections"):
        from lib.test_sections import TEST_SECTIONS, section_names

        print("Available test sections (--skip-sections):\n")
        for name in section_names():
            print(
                f"  {name:16}  markers: {', '.join(sorted(TEST_SECTIONS[name]))}"
            )
        pytest.exit("", returncode=0)

    resolved, unknown = resolve_skip_sections(config.getoption("--skip-sections"))
    if unknown:
        pytest.exit(
            f"Unknown --skip-sections: {', '.join(unknown)}. "
            f"{sections_help_text()}",
            returncode=2,
        )
    config._skip_sections = resolved  # noqa: SLF001
    config._skip_section_markers = markers_for_sections(resolved)

    _configure_io_method_for_install(config)


def pytest_report_header(config):
    """Show PostgreSQL + pg_tde install versions at pytest startup."""
    headers: list[str] = []
    install = config.getoption("--install-dir")
    if install:
        headers.extend(
            install_version_summary_lines(Path(install), prefix="INSTALL")
        )
    old = config.getoption("--old-install-dir")
    if old:
        headers.extend(
            install_version_summary_lines(Path(old), prefix="OLD")
        )
    upgrade_dir = config.getoption("--upgrade-data-dir")
    if upgrade_dir:
        headers.append(f"upgrade-data-dir: {upgrade_dir}")
    return headers


def _configure_io_method_for_install(config) -> None:
    install_dir = Path(config.getoption("--install-dir"))
    method = config.getoption("--io-method")
    matrix = config.getoption("--io-method-matrix")

    try:
        available = io_methods_available(install_dir)
    except (OSError, ValueError, IndexError):
        config._io_methods_available = list(IO_METHOD_VALUES)  # noqa: SLF001
        return

    config._io_methods_available = available  # noqa: SLF001

    if not io_method_guc_supported(install_dir):
        if matrix:
            config._io_method_pg17_note = (  # noqa: SLF001
                f"--io-method-matrix ignored: {install_dir} is not PostgreSQL "
                f"{PG_IO_METHOD_MIN_MAJOR}+ (io_method GUC does not exist)"
            )
        if method != IO_METHOD_LEGACY_PLACEHOLDER:
            pytest.exit(
                f"--io-method={method!r} requires PostgreSQL {PG_IO_METHOD_MIN_MAJOR}+ "
                f"under --install-dir={install_dir}; on older versions omit the flag.",
                returncode=2,
            )
        return

    config._io_uring_status = io_uring_status_lines(install_dir)  # noqa: SLF001

    if matrix:
        omitted = [m for m in IO_METHOD_VALUES if m not in available]
        if omitted:
            parts = [f"io-method-matrix uses {', '.join(available)} only"]
            if "io_uring" in omitted:
                _ready, issues = io_uring_runtime_ready(install_dir)
                if io_uring_build_supported(install_dir) and issues:
                    parts.append(
                        "io_uring needs system setup: " + "; ".join(issues)
                    )
                    parts.append("see postgresql/pytest/docs/io_uring_system_setup.md")
                else:
                    parts.append(
                        "io_uring not in PostgreSQL build at " + str(install_dir)
                    )
            else:
                parts.append(f"omitted: {', '.join(omitted)}")
            config._io_method_install_note = "; ".join(parts)  # noqa: SLF001
        return

    if method not in available:
        detail = (
            " See postgresql/pytest/docs/io_uring_system_setup.md."
            if method == "io_uring"
            else ""
        )
        if method == "io_uring" and io_uring_build_supported(install_dir):
            _r, issues = io_uring_runtime_ready(install_dir)
            hint = "; ".join(issues) if issues else "unknown system block"
            pytest.exit(
                f"--io-method=io_uring is not ready on this host ({hint}).{detail}",
                returncode=2,
            )
        pytest.exit(
            f"--io-method={method!r} is not available (supported: "
            f"{', '.join(available)}).{detail}",
            returncode=2,
        )


def pytest_report_header(config):
    lines = []
    for attr in ("_io_method_pg17_note", "_io_method_install_note"):
        note = getattr(config, attr, None)
        if note:
            lines.append(note)
    for line in getattr(config, "_io_uring_status", []):
        lines.append(line)
    skipped = getattr(config, "_skip_sections", None)
    if skipped:
        lines.append(f"skip-sections: {', '.join(skipped)}")
    return lines or None


def pytest_generate_tests(metafunc):
    """Parametrize ``io_method`` from install + system capabilities (see ``pytest_configure``)."""
    if "io_method" not in metafunc.fixturenames:
        return
    config = metafunc.config
    cached = getattr(config, "_io_methods_available", None)
    if cached is not None:
        values = (
            list(cached)
            if config.getoption("--io-method-matrix")
            else [config.getoption("--io-method")]
        )
    else:
        install_dir = Path(config.getoption("--install-dir"))
        try:
            values = io_method_param_values(
                install_dir,
                matrix=config.getoption("--io-method-matrix"),
                single=config.getoption("--io-method"),
            )
        except (OSError, ValueError, IndexError):
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
    """Safety net when parametrization and runtime environment diverge."""
    if "io_method" not in request.fixturenames:
        return
    method = request.getfixturevalue("io_method")
    if not io_method_guc_supported(install_dir):
        if method != IO_METHOD_LEGACY_PLACEHOLDER:
            pytest.skip(
                f"io_method={method!r} applies only to PostgreSQL "
                f"{PG_IO_METHOD_MIN_MAJOR}+"
            )
        return
    if not io_method_usable(install_dir, method):
        if method == "io_uring":
            _ready, issues = io_uring_runtime_ready(install_dir)
            reason = "; ".join(issues) if issues else "not available on this host"
            pytest.skip(
                f"io_method=io_uring skipped ({reason}); "
                "see docs/io_uring_system_setup.md"
            )
        pytest.skip(f"io_method={method!r} is not available under {install_dir}")


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
def vault_config(request):
    """
    Parsed Vault/OpenBao settings when ``--vault-addr`` is set.

    See ``docs/vault.md``.
    """
    cfg = vault_config_from_options(
        addr=request.config.getoption("--vault-addr"),
        token=request.config.getoption("--vault-token"),
        token_path=request.config.getoption("--vault-token-file"),
        secret_mount=request.config.getoption("--vault-secret-mount"),
        ca_path=request.config.getoption("--vault-ca-path"),
        namespace=request.config.getoption("--vault-namespace"),
    )
    if cfg is None:
        pytest.skip("--vault-addr not provided")
    ready, reason = vault_runtime_ready(cfg)
    if not ready:
        pytest.skip(reason)
    return cfg


@pytest.fixture(scope="session")
def vault_kv_only_token_file(request) -> str:
    return request.config.getoption("--vault-kv-only-token-file")


@pytest.fixture(scope="session")
def openbao_bin(request) -> str:
    return request.config.getoption("--openbao-bin")


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
def kmip_config(request):
    """
    Parsed KMIP server settings for ``test_kmip.py``.

    Default profile is **cosmian** (``KMIP_SERVER_*`` from ``setup_cosmian_for_pytest.sh``).
    Choose another server with ``KMIP_PROFILE=vault_kmip`` or ``--kmip-profile=vault_kmip``.
    See ``docs/kmip/README.md`` and ``docs/key_provider_matrix.md``.
    """
    cfg, reason = resolve_session_kmip_config(request.config)
    if cfg is None:
        pytest.skip(reason or "--kmip-server-address not provided")
    return cfg


@pytest.fixture(scope="session")
def vault_kmip_config():
    """
    HashiCorp Vault **KMIP engine** (not KV v2). See ``docs/kmip/vault-kmip-engine.md``.
    """
    cfg = vault_kmip_config_from_env()
    if cfg is None:
        pytest.skip(
            "KMIP_VAULT_HOST not set; source scripts/setup_vault_kmip_for_pytest.sh"
        )
    ready, reason = vault_kmip_runtime_ready()
    if not ready:
        pytest.skip(reason)
    return cfg


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
    vault_cfg = vault_config_from_options(
        addr=config.getoption("--vault-addr"),
        token=config.getoption("--vault-token"),
        token_path=config.getoption("--vault-token-file"),
        secret_mount=config.getoption("--vault-secret-mount"),
        ca_path=config.getoption("--vault-ca-path"),
        namespace=config.getoption("--vault-namespace"),
    )
    kmip_cfg, kmip_skip_reason = resolve_session_kmip_config(config)
    kmip_ready = kmip_cfg is not None
    old_dir = config.getoption("--old-install-dir")
    upgrade_data_dir = config.getoption("--upgrade-data-dir")

    vault_ready, vault_skip_reason = (
        vault_runtime_ready(vault_cfg) if vault_cfg else (False, "")
    )
    skip_vault = pytest.mark.skip(
        reason=vault_skip_reason or "--vault-addr not provided"
    )
    skip_openbao = pytest.mark.skip(
        reason=(
            "OpenBao not configured — source scripts/setup_openbao_for_pytest.sh "
            "(see docs/vault.md § Install OpenBao)"
        )
    )
    vault_kmip_ready, vault_kmip_skip_reason = vault_kmip_runtime_ready()
    skip_kmip = pytest.mark.skip(
        reason=kmip_skip_reason or "--kmip-server-address not provided"
    )
    skip_vault_kmip = pytest.mark.skip(
        reason=vault_kmip_skip_reason or "KMIP_VAULT_HOST not set"
    )
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
    skip_section_markers = getattr(config, "_skip_section_markers", frozenset())
    skip_sections = getattr(config, "_skip_sections", [])
    if skip_sections:
        deselected = []
        kept = []
        for item in items:
            if item_matches_skipped_section(
                set(item.keywords), skip_section_markers
            ):
                deselected.append(item)
            else:
                kept.append(item)
        if deselected:
            config.hook.pytest_deselected(items=deselected)
            items[:] = kept

    for item in items:
        if io_matrix and "minor_upgrade" in item.keywords:
            item.add_marker(skip_io_matrix_staged)
        if "vault" in item.keywords and not vault_ready:
            item.add_marker(skip_vault)
        if "openbao" in item.keywords:
            if not vault_ready:
                item.add_marker(skip_vault)
            elif not (vault_cfg and vault_cfg.namespace.strip()):
                item.add_marker(skip_openbao)
        if "vault_kmip" in item.keywords and not vault_kmip_ready:
            item.add_marker(skip_vault_kmip)
        if (
            "kmip" in item.keywords
            and "kmip_revalidation" not in item.keywords
            and "kmip_matrix" not in item.keywords
            and "vault_kmip" not in item.keywords
            and "kmip_build" not in item.keywords
            and not kmip_ready
        ):
            item.add_marker(skip_kmip)
        if "upgrade" in item.keywords and not old_dir:
            item.add_marker(skip_upgrade)
        if "minor_upgrade" in item.keywords and not upgrade_data_dir:
            item.add_marker(skip_minor_upgrade)
        if "docker" in item.keywords and not docker_available:
            item.add_marker(skip_docker)
        if "pgbackrest" in item.keywords and not pgbr_ok:
            item.add_marker(skip_pgbackrest)
