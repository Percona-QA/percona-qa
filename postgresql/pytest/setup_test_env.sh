#!/usr/bin/env bash
# setup_test_env.sh — Prepare the pytest environment for percona-pg-automation tests.
#
# Run with no arguments or --help to print usage.

set -euo pipefail

# ── colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "      $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ───────────────────────────────────────────────────────────────────
INSTALL_PKGS=false
PG_MAJOR="${PG_MAJOR:-18}"
PG_REPO_LINE="${PG_REPO_LINE:-}"
SERVER_VERSION="${SERVER_VERSION:-}"
REPO_COMPONENT="${REPO_COMPONENT:-release}"
COMPONENTS="${COMPONENTS:-server,pg_tde,pg_backrest}"
SETUP_EXTERNAL_KEY_PROVIDERS=true

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Prepare the pytest environment for percona-pg-automation tests:
detect PostgreSQL, create a Python venv, install dependencies, optional
Percona packages, sysbench (rewind load tests), and Cosmian KMIP + OpenBao
for vault/kmip tests.

Version terminology (keep these separate):
  PG_MAJOR       Integer PostgreSQL major (${PG_MAJOR}) — package names, install paths
  PG_REPO_LINE   Percona repo line (${PG_REPO_LINE:-<auto>}) → percona-release ppg-X.Y
  SERVER_VERSION Patch level — postgres --version; on apt the repo tier selects
                 the patch (release=18.4.1, testing=18.4.2, …)

Options:
  --install-dir PATH          PostgreSQL install root
                              (Ubuntu: /usr/lib/postgresql/18, RHEL: /usr/pgsql-18)
  --old-install-dir PATH      Old PG install for pg_upgrade tests
  --install-pkgs              Install Percona packages from configured repository
  --pg-major N                Integer major version (default: ${PG_MAJOR})
  --pg-repo-line X.Y          Percona repo line (default: same as --pg-major)
  --server-version X.Y.Z      Expected patch after install (verified with --install-pkgs)
  --repo-component TIER       Percona repo tier: release, testing, experimental
                              (default: ${REPO_COMPONENT})
  --components LIST           Comma-separated: server, pg_tde, pg_backrest
                              (default: ${COMPONENTS})
  --setup-external-key-providers     Install Cosmian KMS + OpenBao (default)
  --no-setup-external-key-providers  Skip Cosmian/OpenBao install
  -h, --help                  Show this help and exit

Environment variables (override auto-detection):
  INSTALL_DIR, OLD_INSTALL_DIR, VAULT_ADDR, VAULT_TOKEN
  PG_MAJOR, PG_REPO_LINE, SERVER_VERSION, REPO_COMPONENT, COMPONENTS
  PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS=1  Skip auto-start of Cosmian/OpenBao in pytest

Examples:
  bash $(basename "$0") --install-pkgs --pg-major 18 --pg-repo-line 18.4
  bash $(basename "$0") --install-dir /usr/lib/postgresql/18
  bash $(basename "$0") --install-pkgs --repo-component testing --server-version 18.4.2
  bash $(basename "$0") --no-setup-external-key-providers
EOF
}

# ── parse args ─────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)     INSTALL_DIR="$2";     shift 2 ;;
        --old-install-dir) OLD_INSTALL_DIR="$2"; shift 2 ;;
        --install-pkgs)    INSTALL_PKGS=true;    shift 1 ;;
        --pg-major)        PG_MAJOR="$2";        shift 2 ;;
        --pg-repo-line)    PG_REPO_LINE="$2";    shift 2 ;;
        --server-version)  SERVER_VERSION="$2";  shift 2 ;;
        --repo-component)  REPO_COMPONENT="$2";  shift 2 ;;
        --components)      COMPONENTS="$2";      shift 2 ;;
        --setup-external-key-providers) SETUP_EXTERNAL_KEY_PROVIDERS=true; shift 1 ;;
        --no-setup-external-key-providers) SETUP_EXTERNAL_KEY_PROVIDERS=false; shift 1 ;;
        -h|--help)         usage; exit 0 ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

# Reject patch strings where an integer major or repo line is expected.
if [[ "$PG_MAJOR" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "PG_MAJOR must be an integer (18, 17), not a patch. \
Use --server-version ${PG_MAJOR} and --pg-repo-line X.Y (e.g. 18.4)."
fi

# Backward compat: legacy callers pass --pg-major 18.4 (repo line, not integer major).
if [[ -z "$PG_REPO_LINE" && "$PG_MAJOR" =~ ^[0-9]+\.[0-9]+$ ]]; then
    PG_REPO_LINE="$PG_MAJOR"
    PG_MAJOR="${PG_MAJOR%%.*}"
fi

if [[ -z "$PG_REPO_LINE" ]]; then
    PG_REPO_LINE="$PG_MAJOR"
fi

REPO_BASE="${PG_REPO_LINE%%.*}"
PPG_MINOR="$PG_REPO_LINE"
PPG_REPO="ppg-${PPG_MINOR}"

if [[ "$REPO_BASE" != "$PG_MAJOR" && "$PG_REPO_LINE" != "$PG_MAJOR" ]]; then
    warn "PG_MAJOR=${PG_MAJOR} differs from PG_REPO_LINE=${PG_REPO_LINE} (integer major ${REPO_BASE})"
fi

# ── 1. not root ────────────────────────────────────────────────────────────────
echo ""
echo "=== 1. User check ==="
if [[ "$(id -u)" -eq 0 ]]; then
    fail "Do not run as root directly. The script handles sudo internally where needed."
fi
ok "Running as $(whoami)"

# ── 1a. PostgreSQL Installation ────────────────────────────────────────────────
if [ "$INSTALL_PKGS" = true ]; then
    echo ""
    echo "=== 1a. Installing Percona PostgreSQL & Ecosystem ==="
    
    # Detect OS family (Ubuntu/Debian vs RHEL/OL/Rocky/Alma)
    # shellcheck source=scripts/pg_os_env.sh
    source "${SCRIPT_DIR}/scripts/pg_os_env.sh"
    pg_os_detect
    OS_FAMILY="${PG_OS_FAMILY}"
    SU_CMD="sudo"
    if [[ "${OS_FAMILY}" != "debian" && "${OS_FAMILY}" != "rhel" ]]; then
        fail "Unsupported distribution (${PG_OS_ID:-unknown}). Manual installation required."
    fi
    info "OS family=${OS_FAMILY} id=${PG_OS_ID:-?} pkg=${PG_PKG_CMD}"

    # Set up Percona format structure for repository registration hook
    info "PG_MAJOR=${PG_MAJOR}  PG_REPO_LINE=${PG_REPO_LINE}  repo=${PPG_REPO} [${REPO_COMPONENT}]"
    if [[ -n "$SERVER_VERSION" ]]; then
        info "SERVER_VERSION=${SERVER_VERSION} (repo tier selects the patch; verified after install)"
    fi

    _deb_pkg_spec() {
        # Debian: repo component alone selects the patch (release=18.4.1, testing=18.4.2, …).
        echo "$1"
    }

    _rpm_pkg_spec() {
        local pkg="$1"
        if [[ -n "$SERVER_VERSION" ]]; then
            echo "${pkg}-${SERVER_VERSION}"
        else
            echo "$pkg"
        fi
    }

    # Setup repositories first if anything is slated for install
    if [ "$OS_FAMILY" = "debian" ]; then
        info "Installing prerequisites for Debian/Ubuntu..."
        $SU_CMD apt-get update -qq
        $SU_CMD apt-get install -y wget gnupg2 lsb-release curl

        info "Setting up Percona apt repository..."
        CODENAME=$(lsb_release -sc)
        DEB_FILE="percona-release_latest.${CODENAME}_all.deb"
        wget -q "https://repo.percona.com/apt/percona-release_latest.${CODENAME}_all.deb" -O "/tmp/$DEB_FILE" \
            || wget -q "https://repo.percona.com/apt/percona-release_latest.generic_all.deb" -O "/tmp/$DEB_FILE"
        $SU_CMD dpkg -i "/tmp/$DEB_FILE"
        rm -f "/tmp/$DEB_FILE"

        info "Enabling Percona repository component: ${PPG_REPO} [${REPO_COMPONENT}]..."
        $SU_CMD percona-release enable-only "${PPG_REPO}" "${REPO_COMPONENT}"
        $SU_CMD apt-get update
            
    elif [ "$OS_FAMILY" = "rhel" ]; then
        info "Installing prerequisites for RHEL/dnf ecosystem..."
        $SU_CMD "${PG_PKG_CMD}" -y install curl wget gnupg2 || \
            $SU_CMD "${PG_PKG_CMD}" -y install curl wget gnupg

        info "Setting up Percona RPM repository..."
        $SU_CMD "${PG_PKG_CMD}" install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm

        info "Enabling Percona repository component: ${PPG_REPO} [${REPO_COMPONENT}]..."
        $SU_CMD percona-release enable-only "${PPG_REPO}" "${REPO_COMPONENT}"
        # AppStream postgresql module often conflicts with Percona packages.
        $SU_CMD "${PG_PKG_CMD}" module disable postgresql -y 2>/dev/null || true
        $SU_CMD "${PG_PKG_CMD}" clean all
        $SU_CMD "${PG_PKG_CMD}" makecache || true
    fi

    # Build package array dynamically using mapped major version variables
    PKGS_TO_INSTALL=()
    
    if [ "$OS_FAMILY" = "debian" ]; then
        if [[ "$COMPONENTS" == *"server"* ]]; then
            PKGS_TO_INSTALL+=("$(_deb_pkg_spec "percona-postgresql-${REPO_BASE}")")
        fi
        if [[ "$COMPONENTS" == *"pg_backrest"* ]]; then PKGS_TO_INSTALL+=("percona-pgbackrest"); fi
        if [[ "$COMPONENTS" == *"pg_tde"* ]]; then
            PKGS_TO_INSTALL+=("$(_deb_pkg_spec "percona-pg-tde${REPO_BASE}")")
        fi
        
        if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
            info "Installing requested packages via apt: ${PKGS_TO_INSTALL[*]}"
            $SU_CMD apt-get install -y "${PKGS_TO_INSTALL[@]}"
        fi
        
    elif [ "$OS_FAMILY" = "rhel" ]; then
        if [[ "$COMPONENTS" == *"server"* ]]; then
            PKGS_TO_INSTALL+=("$(_rpm_pkg_spec "percona-postgresql${REPO_BASE}-server")")
            PKGS_TO_INSTALL+=("$(_rpm_pkg_spec "percona-postgresql${REPO_BASE}-contrib")")
        fi
        if [[ "$COMPONENTS" == *"pg_backrest"* ]]; then PKGS_TO_INSTALL+=("percona-pgbackrest"); fi
        if [[ "$COMPONENTS" == *"pg_tde"* ]]; then
            PKGS_TO_INSTALL+=("$(_rpm_pkg_spec "percona-pg_tde${REPO_BASE}")")
        fi

        if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
            info "Installing requested packages via ${PG_PKG_CMD}: ${PKGS_TO_INSTALL[*]}"
            $SU_CMD "${PG_PKG_CMD}" install -y "${PKGS_TO_INSTALL[@]}"
        fi
    fi
    ok "Percona components installation complete."
fi

# ── 2. detect PostgreSQL install dir ──────────────────────────────────────────
echo ""
echo "=== 2. PostgreSQL install directory ==="

# shellcheck source=scripts/pg_os_env.sh
source "${SCRIPT_DIR}/scripts/pg_os_env.sh"
pg_os_detect

if [[ -z "${INSTALL_DIR:-}" ]]; then
    if INSTALL_DIR="$(pg_detect_install_dir "${REPO_BASE}")"; then
        :
    else
        INSTALL_DIR=""
    fi
fi

if [[ -z "${INSTALL_DIR:-}" ]] || [[ ! -x "${INSTALL_DIR}/bin/initdb" ]]; then
    _ex="$(pg_default_install_dir "${REPO_BASE}")"
    fail "Cannot find PostgreSQL install. Pass --install-pkgs to install automatically, set INSTALL_DIR, or pass --install-dir.\n      Example: bash setup_test_env.sh --install-dir ${_ex}"
fi

if [[ "$INSTALL_PKGS" == true && -n "$SERVER_VERSION" && -x "${INSTALL_DIR}/bin/postgres" ]]; then
    _pg_ver="$("${INSTALL_DIR}/bin/postgres" --version 2>&1 || true)"
    if [[ "$_pg_ver" != *"${SERVER_VERSION}"* ]]; then
        fail "SERVER_VERSION mismatch: expected ${SERVER_VERSION}, got: ${_pg_ver}"
    fi
    ok "SERVER_VERSION ${SERVER_VERSION} confirmed (${_pg_ver})"
fi

PG_VERSION=$("${INSTALL_DIR}/bin/postgres" --version 2>&1 | grep -oP '\d+' | head -1)
ok "Found PostgreSQL ${PG_VERSION} at ${INSTALL_DIR}"
info "Server package: $("${INSTALL_DIR}/bin/postgres" --version 2>&1 | head -1)"
for _ctrl in \
    "${INSTALL_DIR}/share/postgresql/extension/pg_tde.control" \
    "${INSTALL_DIR}/share/extension/pg_tde.control"
do
    if [[ -f "$_ctrl" ]]; then
        info "pg_tde.control default_version: $(grep -E '^default_version' "$_ctrl" | cut -d= -f2 | tr -d "' '")"
        break
    fi
done

# ── 3. verify pg_tde extension is present ─────────────────────────────────────
echo ""
echo "=== 3. pg_tde extension ==="

SHARE_DIR="${INSTALL_DIR}/share/postgresql/extension"
if [[ ! -f "${SHARE_DIR}/pg_tde.control" ]] && \
   [[ ! -f "${INSTALL_DIR}/share/extension/pg_tde.control" ]]; then
    warn "pg_tde.control not found in ${SHARE_DIR}"
    warn "Make sure pg_tde is installed for this PostgreSQL version."
    warn "Encryption tests will fail without pg_tde."
else
    ok "pg_tde extension found"
fi

# ── 3a. pgBackRest (percona-pgbackrest) ───────────────────────────────────────
echo ""
echo "=== 3a. pgBackRest (Percona) ==="

if command -v pgbackrest >/dev/null 2>&1; then
    _pgbr_line=$(pgbackrest version 2>/dev/null | head -n1 || true)
    if [[ -n "${_pgbr_line}" ]]; then
        ok "pgBackRest already installed (${_pgbr_line})"
    else
        ok "pgBackRest already installed"
    fi
else
    warn "pgBackRest binary is missing from PATH. Ensure it was requested or manually installed."
fi

# ── 3b. sysbench (rewind / failover load loops) ───────────────────────────────
echo ""
echo "=== 3b. sysbench ==="

if command -v sysbench >/dev/null 2>&1; then
    _sb_ver=$(sysbench --version 2>/dev/null | head -n1 || true)
    if [[ -n "${_sb_ver}" ]]; then
        ok "sysbench already installed (${_sb_ver})"
    else
        ok "sysbench already installed"
    fi
else
    info "Installing sysbench (TestTdeRewindSysbenchLoop / failover load tests)..."
    if command -v apt-get >/dev/null 2>&1; then
        if sudo apt-get install -y sysbench; then
            ok "sysbench installed ($(sysbench --version 2>/dev/null | head -n1 || echo ok))"
        else
            warn "sysbench apt install failed — sysbench rewind tests will skip"
        fi
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        _yum=$(command -v dnf || command -v yum)
        if sudo "$_yum" install -y sysbench; then
            ok "sysbench installed ($(sysbench --version 2>/dev/null | head -n1 || echo ok))"
        else
            warn "sysbench yum/dnf install failed — sysbench rewind tests will skip"
        fi
    else
        warn "No apt/yum available — install sysbench manually for load-loop rewind tests"
    fi
fi

# ── 4. Python ──────────────────────────────────────────────────────────────────
echo ""
echo "=== 4. Python ==="

PYTHON=""
for py in python3 python; do
    if command -v "$py" &>/dev/null; then
        PY_VER=$("$py" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        MAJOR="${PY_VER%%.*}"
        MINOR="${PY_VER##*.}"
        if [[ "$MAJOR" -ge 3 ]] && [[ "$MINOR" -ge 9 ]]; then
            PYTHON="$py"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    fail "Python 3.9+ is required. Install it with your system package manager."
fi
ok "Found $($PYTHON --version)"

# ── 5. virtual environment ─────────────────────────────────────────────────────
echo ""
echo "=== 5. Python virtual environment ==="

VENV_DIR="${SCRIPT_DIR}/.venv"

if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtual environment at ${VENV_DIR}"
    if ! "$PYTHON" -m venv "$VENV_DIR" 2>/dev/null; then
        PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        warn "python${PY_VER}-venv not found — trying auto-install..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y "python${PY_VER}-venv"
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            _yum=$(command -v dnf || command -v yum)
            sudo "$_yum" install -y "python${PY_VER}-devel" python3-pip || \
                sudo "$_yum" install -y python3-devel python3-pip
            # ensurepip / venv module often ships with python3 itself on RHEL.
        fi
        "$PYTHON" -m venv "$VENV_DIR" || fail "venv creation failed."
    fi
    ok "Virtual environment created"
else
    ok "Virtual environment already exists at ${VENV_DIR}"
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

if [[ ! -x "$VENV_PIP" ]]; then
    info "pip not found in venv, bootstrapping with ensurepip..."
    "$VENV_PYTHON" -m ensurepip --upgrade || fail "ensurepip failed."
fi

# ── 6. install Python dependencies ────────────────────────────────────────────
echo ""
echo "=== 6. Python dependencies ==="

"$VENV_PYTHON" -m pip install --quiet --upgrade pip
"$VENV_PYTHON" -m pip install --quiet -e "${SCRIPT_DIR}[dev]" 2>/dev/null || \
"$VENV_PYTHON" -m pip install --quiet \
    "pytest>=7.4" \
    "pytest-xdist>=3.0" \
    "pytest-timeout>=2.1" \
    "pytest-html>=4.0" \
    "psutil>=5.9"
ok "Dependencies installed"

# ── 6a. external key providers (Cosmian KMIP + OpenBao) ───────────────────────
echo ""
echo "=== 6a. External key providers (Cosmian KMIP + OpenBao) ==="

if [[ "$SETUP_EXTERNAL_KEY_PROVIDERS" == true ]]; then
  _have_cosmian=false
  if command -v cosmian_kms >/dev/null 2>&1 || [[ -x /usr/sbin/cosmian_kms ]]; then
    _have_cosmian=true
    ok "cosmian_kms already installed"
  elif [[ -x "${SCRIPT_DIR}/scripts/install_cosmian_kms.sh" ]]; then
    info "Installing Cosmian KMS (KMIP tests)..."
    if bash "${SCRIPT_DIR}/scripts/install_cosmian_kms.sh"; then
      _have_cosmian=true
      ok "Cosmian KMS installed"
    else
      warn "Cosmian KMS install failed — KMIP tests will skip unless KMIP_* is set"
    fi
  else
    warn "scripts/install_cosmian_kms.sh not found"
  fi

  _have_openbao=false
  if command -v bao >/dev/null 2>&1; then
    _have_openbao=true
    ok "OpenBao (bao) already installed"
  elif [[ -x "${SCRIPT_DIR}/scripts/install_openbao.sh" ]]; then
    info "Installing OpenBao (vault/openbao tests)..."
    if bash "${SCRIPT_DIR}/scripts/install_openbao.sh"; then
      _have_openbao=true
      ok "OpenBao installed"
    else
      warn "OpenBao install failed — vault/openbao tests will skip unless VAULT_* is set"
    fi
  else
    warn "scripts/install_openbao.sh not found"
  fi

  if [[ "$_have_cosmian" == true && "$_have_openbao" == true ]]; then
    info "pytest auto-starts Cosmian KMIP + OpenBao dev server when you run the suite"
    info "(opt out: PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS=1 or --skip-sections=kmip,vault,openbao)"
  fi
else
  info "Skipping external key provider install (--no-setup-external-key-providers)"
fi

# ── 7. environment file ────────────────────────────────────────────────────────
echo ""
echo "=== 7. Environment file ==="

ENV_FILE="${SCRIPT_DIR}/.env.sh"
cat > "$ENV_FILE" <<EOF
# Auto-generated by setup_test_env.sh — source this before running pytest.
export INSTALL_DIR="${INSTALL_DIR}"
export PATH="${INSTALL_DIR}/bin:\$PATH"
export OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-}"
export VAULT_ADDR="${VAULT_ADDR:-}"
export VAULT_TOKEN="${VAULT_TOKEN:-}"
# Cosmian KMIP + OpenBao: pytest auto-starts local servers when binaries are installed.
# Manual setup (same shell as pytest): source scripts/setup_cosmian_for_pytest.sh
#   and/or source scripts/setup_openbao_for_pytest.sh
# Opt out of auto-start: export PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS=1
export PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS="${PG_TDE_SKIP_EXTERNAL_KEY_PROVIDERS:-}"
export VIRTUAL_ENV="${VENV_DIR}"
export PATH="${VENV_DIR}/bin:\$PATH"
if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    source "${VENV_DIR}/bin/activate"
fi
EOF
ok "Environment file written to ${ENV_FILE}"
info "Source it with:  source ${ENV_FILE}"

# ── 8. smoke-check PostgreSQL ──────────────────────────────────────────────────
echo ""
echo "=== 8. PostgreSQL smoke check ==="

TMPDATA=$(mktemp -d)
TMPPORT=19876
TMPSOCK="$TMPDATA"

cleanup_smoke() { "${INSTALL_DIR}/bin/pg_ctl" stop -D "$TMPDATA/data" -m immediate -t 10 &>/dev/null || true; rm -rf "$TMPDATA"; }
trap cleanup_smoke EXIT

INITDB_EXTRA=()
if [[ "${PG_VERSION}" -ge 18 ]]; then
    INITDB_EXTRA=(--no-data-checksums)
fi
"${INSTALL_DIR}/bin/initdb" -D "${TMPDATA}/data" "${INITDB_EXTRA[@]}" >/dev/null
cat >> "${TMPDATA}/data/postgresql.conf" <<PGCONF
port = ${TMPPORT}
unix_socket_directories = '${TMPSOCK}'
shared_preload_libraries = 'pg_tde'
PGCONF
echo "local all all trust" >> "${TMPDATA}/data/pg_hba.conf"

if "${INSTALL_DIR}/bin/pg_ctl" start -D "${TMPDATA}/data" -o "-k ${TMPSOCK}" \
   -l "${TMPDATA}/pg.log" -w -t 30 &>/dev/null; then

    "${INSTALL_DIR}/bin/psql" -h "${TMPSOCK}" -p "${TMPPORT}" -d postgres -c "SELECT 1" -q &>/dev/null \
        && ok "PostgreSQL starts and accepts connections"

    if "${INSTALL_DIR}/bin/psql" -h "${TMPSOCK}" -p "${TMPPORT}" -d postgres \
       -c "CREATE EXTENSION IF NOT EXISTS pg_tde;" -q &>/dev/null; then
        ok "pg_tde extension loads successfully"
    else
        warn "pg_tde extension failed to load — check system configuration"
    fi

    "${INSTALL_DIR}/bin/pg_ctl" stop -D "${TMPDATA}/data" -m fast -t 30 &>/dev/null || true
else
    warn "PostgreSQL failed to start ── check ${TMPDATA}/pg.log"
    cat "${TMPDATA}/pg.log" 2>/dev/null | tail -20 || true
fi

trap - EXIT
rm -rf "$TMPDATA"

# ── 9. summary ─────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo " Environment ready. Run tests like this:"
echo ""
echo "   source ${ENV_FILE}"
echo "   pytest tests/ -v"
echo ""
echo " Cosmian KMIP + OpenBao start automatically when pytest collects"
echo " vault/kmip/openbao tests (requires cosmian_kms + bao from step 6a)."
echo " sysbench is installed in step 3b for TestTdeRewindSysbenchLoop."
echo "======================================================================"