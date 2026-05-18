#!/usr/bin/env bash
# setup_test_env.sh — Prepare the pytest environment for percona-pg-automation tests.
#
# Usage:
#   bash setup_test_env.sh [--install-dir /path/to/pg] [--old-install-dir /path/to/old/pg] 
#                          [--install-pkgs] [--pg-major 18.4] [--repo-component testing]
#                          [--components server,pg_tde,pg_backrest]
#
# Environment variables (override auto-detection):
#   INSTALL_DIR       Path to the Percona PostgreSQL install (e.g. /usr/lib/postgresql/18)
#   OLD_INSTALL_DIR   Path to old PG install used as pg_upgrade source
#   VAULT_ADDR        HashiCorp Vault address (only needed for vault tests)
#   VAULT_TOKEN       Vault token
#   PG_MAJOR          Target major or minor version to install if --install-pkgs is used (default: 18)
#   REPO_COMPONENT    Percona repo tier: release, testing, or experimental (default: release)
#   COMPONENTS        Comma-separated list of components to install (default: server,pg_tde,pg_backrest)

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
REPO_COMPONENT="${REPO_COMPONENT:-release}"
COMPONENTS="${COMPONENTS:-server,pg_tde,pg_backrest}"

# ── parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)     INSTALL_DIR="$2";     shift 2 ;;
        --old-install-dir) OLD_INSTALL_DIR="$2"; shift 2 ;;
        --install-pkgs)    INSTALL_PKGS=true;    shift 1 ;;
        --pg-major)        PG_MAJOR="$2";        shift 2 ;;
        --repo-component)  REPO_COMPONENT="$2";  shift 2 ;;
        --components)      COMPONENTS="$2";      shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Extract true baseline integer major number for core OS package lookups
# E.g., if PG_MAJOR is "18.4", REPO_BASE becomes "18". If it's already "18", it stays "18".
REPO_BASE=$(echo "$PG_MAJOR" | cut -d'.' -f1)

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
    
    # Detect OS family
    if command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
        SU_CMD="sudo"
    elif command -v yum >/dev/null 2>&1; then
        OS_FAMILY="rhel"
        SU_CMD="sudo"
    else
        fail "Unsupported distribution. Manual installation required."
    fi

    # Set up Percona format structure for repository registration hook
    PPG_REPO="ppg-${PG_MAJOR}"

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
        info "Installing prerequisites for RHEL/Yum ecosystem..."
        $SU_CMD yum -y install curl wget gnupg

        info "Setting up Percona RPM repository..."
        $SU_CMD yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm

        info "Enabling Percona repository component: ${PPG_REPO} [${REPO_COMPONENT}]..."
        $SU_CMD percona-release enable-only "${PPG_REPO}" "${REPO_COMPONENT}"
    fi

    # Build package array dynamically using mapped major version variables
    PKGS_TO_INSTALL=()
    
    if [ "$OS_FAMILY" = "debian" ]; then
        if [[ "$COMPONENTS" == *"server"* ]]; then PKGS_TO_INSTALL+=("percona-postgresql-${REPO_BASE}"); fi
        if [[ "$COMPONENTS" == *"pg_backrest"* ]]; then PKGS_TO_INSTALL+=("percona-pgbackrest"); fi
        if [[ "$COMPONENTS" == *"pg_tde"* ]]; then PKGS_TO_INSTALL+=("percona-pg-tde${REPO_BASE}"); fi
        
        if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
            info "Installing requested packages via apt: ${PKGS_TO_INSTALL[*]}"
            $SU_CMD apt-get install -y "${PKGS_TO_INSTALL[@]}"
        fi
        
    elif [ "$OS_FAMILY" = "rhel" ]; then
        if [[ "$COMPONENTS" == *"server"* ]]; then PKGS_TO_INSTALL+=("percona-postgresql${REPO_BASE}-server"); fi
        if [[ "$COMPONENTS" == *"pg_backrest"* ]]; then PKGS_TO_INSTALL+=("percona-pgbackrest"); fi
        if [[ "$COMPONENTS" == *"pg_tde"* ]]; then PKGS_TO_INSTALL+=("percona-pg_tde${REPO_BASE}"); fi
        
        if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
            info "Installing requested packages via yum: ${PKGS_TO_INSTALL[*]}"
            $SU_CMD yum install -y "${PKGS_TO_INSTALL[@]}"
        fi
    fi
    ok "Percona components installation complete."
fi

# ── 2. detect PostgreSQL install dir ──────────────────────────────────────────
echo ""
echo "=== 2. PostgreSQL install directory ==="

if [[ -z "${INSTALL_DIR:-}" ]]; then
    # Try common Percona/PostgreSQL install locations using base parsed major id
    for candidate in \
        /usr/lib/postgresql/18/bin \
        /usr/lib/postgresql/17/bin \
        /usr/pgsql-18/bin \
        /usr/pgsql-17/bin \
        /opt/postgresql/18/bin \
        /opt/postgresql/17/bin \
        /usr/lib/postgresql/"${REPO_BASE}"/bin \
        /usr/pgsql-"${REPO_BASE}"/bin
    do
        if [[ -x "$candidate/initdb" ]]; then
            INSTALL_DIR="${candidate%/bin}"
            break
        fi
    done
fi

if [[ -z "${INSTALL_DIR:-}" ]] || [[ ! -x "${INSTALL_DIR}/bin/initdb" ]]; then
    fail "Cannot find PostgreSQL install. Pass --install-pkgs to install automatically, set INSTALL_DIR, or pass --install-dir.\n      Example: bash setup_test_env.sh --install-dir /usr/lib/postgresql/18"
fi

PG_VERSION=$("${INSTALL_DIR}/bin/postgres" --version 2>&1 | grep -oP '\d+' | head -1)
ok "Found PostgreSQL ${PG_VERSION} at ${INSTALL_DIR}"

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
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "python${PY_VER}-python-venv" || sudo yum install -y python3-libexec
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
echo "======================================================================"