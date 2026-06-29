#!/usr/bin/env bash
# run_major_upgrade_workflow.sh — Staged PG major upgrade (17 → 18) with pg_tde.
#
# Mirrors the operator flow in:
#   https://docs.percona.com/postgresql/18/major-upgrade.html
#
# Two execution modes:
#   pytest   (default) — ephemeral clusters + pg_tde_upgrade via pytest (TDE-safe,
#                        works on Debian and RHEL when both install trees exist).
#   debian   — system clusters under /var/lib/postgresql/{17,18}/<name> using
#              pg_tde_upgrade (NOT pg_upgradecluster alone; Percona doc requires
#              pg_tde_upgrade when pg_tde is loaded).
#
# Usage:
#   cd postgresql/pytest
#   bash run_major_upgrade_workflow.sh
#   bash run_major_upgrade_workflow.sh --method debian --cluster-name pg_tde_major_test
#   bash run_major_upgrade_workflow.sh --setup-only
#   bash run_major_upgrade_workflow.sh --verify-only --skip-install
#
# Environment:
#   PG_TDE_MAJOR_UPGRADE_DATA_DIR   state + keyring parent (default: /var/lib/pg_tde_major_upgrade)
#   OLD_PG_MAJOR                    source repo pin (default: 17)
#   NEW_PG_MAJOR                    target repo pin (default: 18)
#   PG_MAJOR_UPGRADE_CLUSTER        Debian cluster name (default: pg_tde_major_test)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UPGRADE_DATA_DIR="${PG_TDE_MAJOR_UPGRADE_DATA_DIR:-/var/lib/pg_tde_major_upgrade}"
OLD_PG_MAJOR="${OLD_PG_MAJOR:-17}"
NEW_PG_MAJOR="${NEW_PG_MAJOR:-18}"
OLD_REPO_COMPONENT="${OLD_REPO_COMPONENT:-release}"
NEW_REPO_COMPONENT="${NEW_REPO_COMPONENT:-release}"
COMPONENTS="${COMPONENTS:-server,pg_tde}"
CLUSTER_NAME="${PG_MAJOR_UPGRADE_CLUSTER:-pg_tde_major_test}"
METHOD="${PG_MAJOR_UPGRADE_METHOD:-auto}"

SKIP_INSTALL=false
SETUP_ONLY=false
UPGRADE_ONLY=false
VERIFY_ONLY=false
SKIP_DROP=false

STATE_ENV="${UPGRADE_DATA_DIR}/major_upgrade_state.env"
KEYFILE="${UPGRADE_DATA_DIR}/major_upgrade_keyring.per"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}WARN:${NC} $*"; }
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
ok()    { echo -e "  ${GREEN}OK${NC}  $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Staged major upgrade (PG ${OLD_PG_MAJOR} → ${NEW_PG_MAJOR}) with pg_tde.

Methods:
  pytest   Run tests/test_tde_pg_upgrade.py smoke tests with --old-install-dir
           (default when pg_upgradecluster is absent or METHOD=pytest).
  debian   Populate a Debian-style cluster, run pg_tde_upgrade on
           /var/lib/postgresql/{${OLD_PG_MAJOR},${NEW_PG_MAJOR}}/${CLUSTER_NAME},
           then vacuumdb + inline SQL checks.
  auto     debian when pg_createcluster exists, else pytest.

Options:
  --method METHOD          pytest | debian | auto (default: ${METHOD})
  --cluster-name NAME      Debian cluster name (default: ${CLUSTER_NAME})
  --skip-install           Skip package install phases
  --setup-only             Old packages + populate source cluster / state, exit
  --upgrade-only           Install new packages + run pg_tde_upgrade, exit
  --verify-only            Post-upgrade checks only (requires prior upgrade)
  --skip-drop              Do not pg_dropcluster the old major at the end
  --upgrade-data-dir PATH  Override PG_TDE_MAJOR_UPGRADE_DATA_DIR
  --old-pg-major VER       Default: ${OLD_PG_MAJOR}
  --new-pg-major VER       Default: ${NEW_PG_MAJOR}
  --old-repo COMPONENT     Default: ${OLD_REPO_COMPONENT}
  --new-repo COMPONENT     Default: ${NEW_REPO_COMPONENT}
  -h, --help               Show this help

Examples:
  sudo mkdir -p ${UPGRADE_DATA_DIR} && sudo chown "\$USER" ${UPGRADE_DATA_DIR}
  bash $(basename "$0")
  bash $(basename "$0") --method debian --setup-only
  bash $(basename "$0") --upgrade-only
  bash $(basename "$0") --verify-only --skip-install

Doc: ${SCRIPT_DIR}/docs/major_upgrade.md
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --method)           METHOD="$2"; shift 2 ;;
        --cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
        --skip-install)     SKIP_INSTALL=true; shift ;;
        --setup-only)       SETUP_ONLY=true; shift ;;
        --upgrade-only)     UPGRADE_ONLY=true; shift ;;
        --verify-only)      VERIFY_ONLY=true; shift ;;
        --skip-drop)        SKIP_DROP=true; shift ;;
        --upgrade-data-dir) UPGRADE_DATA_DIR="$2"; shift 2 ;;
        --old-pg-major)     OLD_PG_MAJOR="$2"; shift 2 ;;
        --new-pg-major)     NEW_PG_MAJOR="$2"; shift 2 ;;
        --old-repo)         OLD_REPO_COMPONENT="$2"; shift 2 ;;
        --new-repo)         NEW_REPO_COMPONENT="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

export PG_TDE_MAJOR_UPGRADE_DATA_DIR="$UPGRADE_DATA_DIR"
STATE_ENV="${UPGRADE_DATA_DIR}/major_upgrade_state.env"
KEYFILE="${UPGRADE_DATA_DIR}/major_upgrade_keyring.per"

if [[ "$(id -u)" -eq 0 ]]; then
    die "Do not run as root. Package install uses sudo internally."
fi

if [[ ! -f "${SCRIPT_DIR}/setup_test_env.sh" ]]; then
    die "Missing ${SCRIPT_DIR}/setup_test_env.sh"
fi

resolve_method() {
    case "$METHOD" in
        pytest|debian) echo "$METHOD" ;;
        auto)
            if command -v pg_createcluster >/dev/null 2>&1; then
                echo "debian"
            else
                echo "pytest"
            fi
            ;;
        *) die "Invalid --method: ${METHOD} (use pytest, debian, or auto)" ;;
    esac
}

install_packages() {
    local pg_major="$1"
    local repo_component="$2"
    info "Installing Percona packages: pg-major=${pg_major} repo=${repo_component}"
    bash "${SCRIPT_DIR}/setup_test_env.sh" \
        --install-pkgs \
        --pg-major "${pg_major}" \
        --repo-component "${repo_component}" \
        --components "${COMPONENTS}"
}

detect_install_dir() {
    local major="$1"
    local base="${major%%.*}"
    local candidate
    for candidate in \
        "/usr/lib/postgresql/${base}" \
        "/usr/pgsql-${base}" \
        "/opt/postgresql/${base}"
    do
        if [[ -x "${candidate}/bin/initdb" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

write_state() {
    mkdir -p "${UPGRADE_DATA_DIR}"
    cat > "${STATE_ENV}" <<EOF
# Generated by run_major_upgrade_workflow.sh — source before verify/upgrade-only.
export PG_TDE_MAJOR_UPGRADE_DATA_DIR="${UPGRADE_DATA_DIR}"
export OLD_PG_MAJOR="${OLD_PG_MAJOR}"
export NEW_PG_MAJOR="${NEW_PG_MAJOR}"
export OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-}"
export NEW_INSTALL_DIR="${NEW_INSTALL_DIR:-}"
export PG_MAJOR_UPGRADE_CLUSTER="${CLUSTER_NAME}"
export PG_MAJOR_UPGRADE_METHOD="${RESOLVED_METHOD}"
export PG_MAJOR_UPGRADE_KEYFILE="${KEYFILE}"
EOF
    ok "Wrote ${STATE_ENV}"
}

load_state() {
    if [[ ! -f "${STATE_ENV}" ]]; then
        die "Missing ${STATE_ENV}. Run setup first."
    fi
    # shellcheck disable=SC1090
    source "${STATE_ENV}"
}

source_env_new() {
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.sh"
    NEW_INSTALL_DIR="${INSTALL_DIR}"
    export NEW_INSTALL_DIR
}

ensure_pytest_env() {
    if [[ ! -x "${SCRIPT_DIR}/.venv/bin/pytest" ]]; then
        info "Creating Python venv (setup_test_env without --install-pkgs)"
        bash "${SCRIPT_DIR}/setup_test_env.sh" \
            --pg-major "${NEW_PG_MAJOR}" \
            --repo-component "${NEW_REPO_COMPONENT}" \
            || bash "${SCRIPT_DIR}/setup_test_env.sh"
    fi
}

show_versions() {
    local label="$1"
    echo ""
    info "Versions (${label})"
    [[ -n "${OLD_INSTALL_DIR:-}" ]] && echo "  OLD_INSTALL_DIR=${OLD_INSTALL_DIR}"
    [[ -n "${NEW_INSTALL_DIR:-}" ]] && echo "  NEW_INSTALL_DIR=${NEW_INSTALL_DIR}"
    for dir_var in OLD_INSTALL_DIR NEW_INSTALL_DIR; do
        local dir="${!dir_var:-}"
        [[ -z "$dir" || ! -x "${dir}/bin/postgres" ]] && continue
        echo "  ${dir_var}: $("${dir}/bin/postgres" --version 2>&1 || true)"
        local ctrl
        for ctrl in \
            "${dir}/share/postgresql/extension/pg_tde.control" \
            "${dir}/share/extension/pg_tde.control"
        do
            if [[ -f "$ctrl" ]]; then
                echo "    pg_tde: $(grep -E '^default_version' "$ctrl" || true)"
                break
            fi
        done
    done
}

run_pytest_smoke() {
    info "Phase: pytest major-upgrade smoke (pg_tde_upgrade)"
    load_state
    ensure_pytest_env

    local old_dir="${OLD_INSTALL_DIR:-}"
    local new_dir="${NEW_INSTALL_DIR:-${INSTALL_DIR:-}}"
    [[ -n "$old_dir" && -x "${old_dir}/bin/initdb" ]] || die "OLD_INSTALL_DIR not set or invalid"
    [[ -n "$new_dir" && -x "${new_dir}/bin/initdb" ]] || die "NEW_INSTALL_DIR / INSTALL_DIR not set or invalid"

    local tests=(
        "tests/test_tde_pg_upgrade.py::TestPspToPspUpgrade::test_tde_heap_data_survives"
        "tests/test_tde_pg_upgrade.py::TestPspToPspUpgrade::test_check_mode_with_tde_configured"
        "tests/test_upgrade.py::TestUpgradePostMaintenance::test_analyze_all_after_upgrade"
    )

    "${SCRIPT_DIR}/.venv/bin/pytest" "${tests[@]}" -v \
        --install-dir="${new_dir}" \
        --old-install-dir="${old_dir}"
}

debian_old_paths() {
    OLD_DATA="/var/lib/postgresql/${OLD_PG_MAJOR%%.*}/${CLUSTER_NAME}"
    OLD_BIN="/usr/lib/postgresql/${OLD_PG_MAJOR%%.*}/bin"
}

debian_new_paths() {
    NEW_DATA="/var/lib/postgresql/${NEW_PG_MAJOR%%.*}/${CLUSTER_NAME}"
    NEW_BIN="/usr/lib/postgresql/${NEW_PG_MAJOR%%.*}/bin"
}

# PG 18+ defaults checksums on and accepts --no-data-checksums; PG 17 rejects that flag.
debian_initdb_checksum_args() {
    local pg_major="${1%%.*}"
    if [[ "$pg_major" -ge 18 ]]; then
        printf '%s\0' --no-data-checksums
    fi
}

debian_initdb_extra_args() {
    local pg_major="${1%%.*}"
    local -a args=(--set shared_preload_libraries=pg_tde)
    local -a cs_args=()
    while IFS= read -r -d '' arg; do cs_args+=("$arg"); done \
        < <(debian_initdb_checksum_args "$pg_major")
    if ((${#cs_args[@]})); then
        args=("${cs_args[@]}" "${args[@]}")
    fi
    printf '%s\0' "${args[@]}"
}

debian_setup_cluster() {
    command -v pg_createcluster >/dev/null 2>&1 || \
        die "pg_createcluster not found (install percona-postgresql-common / postgresql-common)"

    debian_old_paths
    mkdir -p "${UPGRADE_DATA_DIR}"

    local pg_major="${OLD_PG_MAJOR%%.*}"
    local -a initdb_args=()
    while IFS= read -r -d '' arg; do initdb_args+=("$arg"); done \
        < <(debian_initdb_extra_args "$pg_major")

    if ! sudo pg_lsclusters -h 2>/dev/null | grep -qE "^${pg_major}[[:space:]]+${CLUSTER_NAME}[[:space:]]"; then
        info "Creating Debian cluster ${pg_major}/${CLUSTER_NAME}"
        sudo pg_createcluster "${pg_major}" "${CLUSTER_NAME}" -- "${initdb_args[@]}"
    else
        info "Cluster ${pg_major}/${CLUSTER_NAME} already exists"
    fi

    sudo pg_ctlcluster "${pg_major}" "${CLUSTER_NAME}" start

    local port
    port="$(pg_lsclusters | awk -v v="${pg_major}" -v c="${CLUSTER_NAME}" \
        '$1==v && $2==c {print $3}')"
    [[ -n "$port" ]] || die "Could not resolve port for ${OLD_PG_MAJOR}/${CLUSTER_NAME}"

    info "Populating pg_tde data on port ${port}"
    sudo -u postgres psql -p "${port}" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS pg_tde;
SELECT pg_tde_add_global_key_provider_file('major_upg_provider', '${KEYFILE}');
SELECT pg_tde_create_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
SELECT pg_tde_set_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
DROP TABLE IF EXISTS major_upg_t;
CREATE TABLE major_upg_t (id INT PRIMARY KEY, payload TEXT) USING tde_heap;
INSERT INTO major_upg_t SELECT i, md5(i::text) FROM generate_series(1, 500) i;
SQL

    sudo pg_ctlcluster "${OLD_PG_MAJOR%%.*}" "${CLUSTER_NAME}" stop

    OLD_INSTALL_DIR="$(detect_install_dir "${OLD_PG_MAJOR}")" || \
        OLD_INSTALL_DIR="/usr/lib/postgresql/${OLD_PG_MAJOR%%.*}"
    export OLD_INSTALL_DIR

    write_state
    ok "Debian setup complete: ${OLD_DATA} (500 rows in major_upg_t)"
}

debian_run_pg_tde_upgrade() {
    load_state
    debian_old_paths
    debian_new_paths

    [[ -x "${NEW_BIN}/pg_tde_upgrade" ]] || \
        die "pg_tde_upgrade not found at ${NEW_BIN}/pg_tde_upgrade (install percona-pg-tde${NEW_PG_MAJOR%%.*})"

    sudo pg_ctlcluster "${OLD_PG_MAJOR%%.*}" "${CLUSTER_NAME}" stop 2>/dev/null || true

    if ! sudo pg_lsclusters 2>/dev/null | grep -qE "^${NEW_PG_MAJOR%%.*}[[:space:]]+${CLUSTER_NAME}[[:space:]]"; then
        info "Creating empty target cluster ${NEW_PG_MAJOR}/${CLUSTER_NAME}"
        local -a new_initdb_args=()
        while IFS= read -r -d '' arg; do new_initdb_args+=("$arg"); done \
            < <(debian_initdb_checksum_args "${NEW_PG_MAJOR%%.*}")
        sudo pg_createcluster "${NEW_PG_MAJOR%%.*}" "${CLUSTER_NAME}" -- "${new_initdb_args[@]}"
    fi
    sudo pg_ctlcluster "${NEW_PG_MAJOR%%.*}" "${CLUSTER_NAME}" stop 2>/dev/null || true

    warn "Using pg_tde_upgrade (required for pg_tde clusters per Percona doc)."
    warn "Do NOT use plain pg_upgradecluster without pg_tde_upgrade on encrypted data."

    local workdir="${UPGRADE_DATA_DIR}/pg_tde_upgrade_cwd"
    mkdir -p "${workdir}"

    info "pg_tde_upgrade --check"
    sudo -u postgres env PGDATA="${NEW_DATA}" bash -c "
        cd '${workdir}' && \
        '${NEW_BIN}/pg_tde_upgrade' \
            --old-bindir='${OLD_BIN}' \
            --new-bindir='${NEW_BIN}' \
            --old-datadir='${OLD_DATA}' \
            --new-datadir='${NEW_DATA}' \
            --check
    "

    info "pg_tde_upgrade (upgrade)"
    sudo -u postgres env PGDATA="${NEW_DATA}" bash -c "
        cd '${workdir}' && \
        '${NEW_BIN}/pg_tde_upgrade' \
            --old-bindir='${OLD_BIN}' \
            --new-bindir='${NEW_BIN}' \
            --old-datadir='${OLD_DATA}' \
            --new-datadir='${NEW_DATA}'
    "

    NEW_INSTALL_DIR="$(detect_install_dir "${NEW_PG_MAJOR}")" || \
        NEW_INSTALL_DIR="/usr/lib/postgresql/${NEW_PG_MAJOR%%.*}"
    export NEW_INSTALL_DIR
    write_state
    ok "pg_tde_upgrade finished"
}

debian_verify_cluster() {
    load_state
    debian_new_paths

    sudo pg_ctlcluster "${NEW_PG_MAJOR%%.*}" "${CLUSTER_NAME}" start

    local port
    port="$(pg_lsclusters | awk -v v="${NEW_PG_MAJOR%%.*}" -v c="${CLUSTER_NAME}" \
        '$1==v && $2==c {print $3}')"
    [[ -n "$port" ]] || die "Could not resolve port for upgraded cluster"

    info "ALTER EXTENSION pg_tde UPDATE + row check on port ${port}"
    sudo -u postgres psql -p "${port}" -d postgres -v ON_ERROR_STOP=1 <<SQL
ALTER EXTENSION pg_tde UPDATE;
SELECT COUNT(*) AS major_upg_rows FROM major_upg_t;
SQL

    info "vacuumdb --all --analyze-in-stages (doc step 6)"
    sudo -u postgres "${NEW_BIN}/vacuumdb" -p "${port}" --all --analyze-in-stages

    ok "Debian verify complete (500 rows expected in major_upg_t)"

    if [[ "$SKIP_DROP" != true ]]; then
        info "Dropping old cluster ${OLD_PG_MAJOR}/${CLUSTER_NAME} (doc step 7)"
        sudo pg_dropcluster "${OLD_PG_MAJOR%%.*}" "${CLUSTER_NAME}" || \
            warn "pg_dropcluster failed (cluster may already be gone)"
    else
        warn "Skipping pg_dropcluster (--skip-drop)"
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

RESOLVED_METHOD="$(resolve_method)"

echo ""
echo "======================================================================"
echo " pg_tde staged MAJOR upgrade workflow"
echo "  data dir : ${UPGRADE_DATA_DIR}"
echo "  source   : PG ${OLD_PG_MAJOR} (${OLD_REPO_COMPONENT})"
echo "  target   : PG ${NEW_PG_MAJOR} (${NEW_REPO_COMPONENT})"
echo "  method   : ${RESOLVED_METHOD}"
echo "  cluster  : ${CLUSTER_NAME} (debian mode only)"
echo "======================================================================"

ensure_pytest_env

if [[ "$VERIFY_ONLY" == true ]]; then
    if [[ "$RESOLVED_METHOD" == "debian" ]]; then
        if [[ "$SKIP_INSTALL" != true ]]; then
            install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
        fi
        debian_verify_cluster
    else
        if [[ "$SKIP_INSTALL" != true ]]; then
            install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
        fi
        source_env_new
        show_versions "verify (pytest)"
        run_pytest_smoke
    fi
    info "Verify-only workflow finished successfully."
    exit 0
fi

if [[ "$UPGRADE_ONLY" == true ]]; then
    install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
    if [[ "$RESOLVED_METHOD" == "debian" ]]; then
        debian_run_pg_tde_upgrade
        info "Upgrade-only finished. Run: $0 --verify-only --skip-install"
    else
        source_env_new
        OLD_INSTALL_DIR="$(detect_install_dir "${OLD_PG_MAJOR}")" || true
        export OLD_INSTALL_DIR
        write_state
        show_versions "upgrade-only (pytest — run smoke tests next)"
        info "Packages upgraded. Run: $0 --verify-only --skip-install"
    fi
    exit 0
fi

# ── Phase 1: source packages + setup ──────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${OLD_PG_MAJOR}" "${OLD_REPO_COMPONENT}"
fi

OLD_INSTALL_DIR="$(detect_install_dir "${OLD_PG_MAJOR}")" || \
    die "Could not find PG ${OLD_PG_MAJOR} install after package phase"
export OLD_INSTALL_DIR

if [[ "$RESOLVED_METHOD" == "debian" ]]; then
    debian_setup_cluster
else
    mkdir -p "${UPGRADE_DATA_DIR}"
    write_state
    source_env_new
    # Re-pin OLD after setup_test_env may have pointed INSTALL_DIR at newest major only
    OLD_INSTALL_DIR="$(detect_install_dir "${OLD_PG_MAJOR}")"
    export OLD_INSTALL_DIR
    write_state
    ok "Pytest method: state saved (OLD_INSTALL_DIR=${OLD_INSTALL_DIR})"
fi

show_versions "after Setup"

if [[ "$SETUP_ONLY" == true ]]; then
    info "Setup-only finished."
    echo "  Next: bash $(basename "$0") --upgrade-only"
    echo "  Then: bash $(basename "$0") --verify-only --skip-install"
    exit 0
fi

# ── Phase 2: target packages + upgrade ────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
fi

NEW_INSTALL_DIR="$(detect_install_dir "${NEW_PG_MAJOR}")" || \
    die "Could not find PG ${NEW_PG_MAJOR} install after package phase"
export NEW_INSTALL_DIR
write_state

if [[ "$RESOLVED_METHOD" == "debian" ]]; then
    debian_run_pg_tde_upgrade
    debian_verify_cluster
else
    source_env_new
    NEW_INSTALL_DIR="${INSTALL_DIR}"
    export NEW_INSTALL_DIR
    write_state
    show_versions "before pytest smoke"
    run_pytest_smoke
fi

echo ""
info "Full major-upgrade workflow finished successfully."
echo "  State: ${STATE_ENV}"
echo "  Doc:  ${SCRIPT_DIR}/docs/major_upgrade.md"
