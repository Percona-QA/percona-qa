#!/usr/bin/env bash
# run_major_upgrade_workflow.sh — Staged PG major upgrade (17 → 18) with pg_tde.
#
# Mirrors the operator flow in:
#   https://docs.percona.com/postgresql/18/major-upgrade.html
#
# Two execution modes:
#   pytest   (default) — ephemeral clusters + pg_tde_upgrade via pytest (TDE-safe,
#                        works on Debian and RHEL when both install trees exist).
#   debian   — initdb clusters under /var/lib/postgresql/pg_tde_major_upgrade/
#              (config in PGDATA; pg_createcluster split layout is incompatible)
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
# Debian mode: resolved under OLD_DATA in debian_old_paths (postgres-owned).
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
  debian   initdb + pg_tde_upgrade under /var/lib/postgresql/pg_tde_major_upgrade/
           (postgres-owned PGDATA with postgresql.conf inside — required by
           pg_upgrade).  Does not use pg_createcluster / pg_upgradecluster.
  auto     debian when pg_createcluster exists, else pytest.

Options:
  --method METHOD          pytest | debian | auto (default: ${METHOD})
  --cluster-name NAME      Debian cluster name (default: ${CLUSTER_NAME})
  --skip-install           Skip package install phases
  --setup-only             Old packages + populate source cluster / state, exit
  --upgrade-only           Install new packages + run pg_tde_upgrade, exit
  --verify-only            Post-upgrade checks only (requires prior upgrade)
  --skip-drop              Do not remove the old major PGDATA tree at the end
  --upgrade-data-dir PATH  Override PG_TDE_MAJOR_UPGRADE_DATA_DIR
  --old-pg-major VER       Default: ${OLD_PG_MAJOR}
  --new-pg-major VER       Default: ${NEW_PG_MAJOR}
  --old-repo COMPONENT     Default: ${OLD_REPO_COMPONENT}
  --new-repo COMPONENT     Default: ${NEW_REPO_COMPONENT}
  -h, --help               Show this help

Examples:
  sudo mkdir -p ${UPGRADE_DATA_DIR} && sudo chown "\$USER" ${UPGRADE_DATA_DIR}
  # (state/metadata only; pg_tde keyring is created under the cluster data dir)

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
# Debian mode: resolved under OLD_DATA in debian_old_paths (postgres-owned).
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
export PG_MAJOR_SOCKET_DIR="${SOCKET_DIR:-}"
export PG_MAJOR_OLD_PORT="${OLD_PORT:-}"
export PG_MAJOR_NEW_PORT="${NEW_PORT:-}"
export PG_MAJOR_OLD_DATA="${OLD_DATA:-}"
export PG_MAJOR_NEW_DATA="${NEW_DATA:-}"
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

debian_base_paths() {
    DEBIAN_ROOT="/var/lib/postgresql/pg_tde_major_upgrade"
    SOCKET_DIR="${DEBIAN_ROOT}/run"
    OLD_PORT="${PG_MAJOR_OLD_PORT:-50417}"
    NEW_PORT="${PG_MAJOR_NEW_PORT:-50418}"
    OLD_DATA="${DEBIAN_ROOT}/${OLD_PG_MAJOR%%.*}/${CLUSTER_NAME}"
    NEW_DATA="${DEBIAN_ROOT}/${NEW_PG_MAJOR%%.*}/${CLUSTER_NAME}"
    OLD_BIN="/usr/lib/postgresql/${OLD_PG_MAJOR%%.*}/bin"
    NEW_BIN="/usr/lib/postgresql/${NEW_PG_MAJOR%%.*}/bin"
    KEYFILE="${OLD_DATA}/major_upgrade_keyring.per"
    export DEBIAN_ROOT SOCKET_DIR OLD_PORT NEW_PORT
    export OLD_DATA NEW_DATA OLD_BIN NEW_BIN KEYFILE
}

debian_remove_legacy_pg_createclusters() {
    command -v pg_lsclusters >/dev/null 2>&1 || return 0
    local pg_major
    for pg_major in "${OLD_PG_MAJOR%%.*}" "${NEW_PG_MAJOR%%.*}"; do
        if pg_lsclusters 2>/dev/null | grep -qE "^${pg_major}[[:space:]]+${CLUSTER_NAME}[[:space:]]"; then
            warn "Dropping legacy pg_createcluster ${pg_major}/${CLUSTER_NAME}"
            warn "(config under /etc/postgresql — incompatible with pg_tde_upgrade)"
            sudo pg_dropcluster "${pg_major}" "${CLUSTER_NAME}" --stop 2>/dev/null || \
                sudo pg_dropcluster "${pg_major}" "${CLUSTER_NAME}" || true
        fi
    done
}

debian_pg_ctl() {
    local action="$1"
    local bin="$2"
    local data="$3"
    local port="$4"
    if [[ "$action" == "start" ]]; then
        sudo -u postgres "${bin}/pg_ctl" -D "$data" \
            -o "-p ${port} -k ${SOCKET_DIR}" -w start
    else
        sudo -u postgres "${bin}/pg_ctl" -D "$data" -m fast -w stop 2>/dev/null || true
    fi
}

debian_has_postgresql_conf() {
    # PGDATA is 0700 postgres:postgres after initdb — check as postgres.
    sudo test -f "$1/postgresql.conf"
}

# PG 18+ defaults checksums on and accepts --no-data-checksums; PG 17 rejects that flag.
debian_initdb_checksum_args() {
    local pg_major="${1%%.*}"
    if [[ "$pg_major" -ge 18 ]]; then
        printf '%s\0' --no-data-checksums
    fi
}

debian_append_cluster_conf() {
    local data_dir="$1"
    local port="$2"

    if ! sudo grep -qE '^[[:space:]]*local[[:space:]]' "${data_dir}/pg_hba.conf" 2>/dev/null; then
        echo "local all all trust" | sudo tee -a "${data_dir}/pg_hba.conf" >/dev/null
    fi
    if ! sudo grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1' \
        "${data_dir}/pg_hba.conf" 2>/dev/null; then
        echo "host all all 127.0.0.1/32 trust" | sudo tee -a "${data_dir}/pg_hba.conf" >/dev/null
    fi
    if ! sudo grep -qE '^[[:space:]]*port[[:space:]]*=' "${data_dir}/postgresql.conf" 2>/dev/null; then
        sudo -u postgres tee -a "${data_dir}/postgresql.conf" >/dev/null <<EOF
port = ${port}
wal_level = replica
include_if_exists = 'postgresql.auto.conf'
EOF
    fi
}

debian_initdb_cluster() {
    local data_dir="$1"
    local bin_dir="$2"
    local pg_major="${3%%.*}"
    local port="$4"

    if debian_has_postgresql_conf "${data_dir}"; then
        info "Reusing PGDATA ${data_dir}"
        debian_append_cluster_conf "${data_dir}" "${port}"
        return 0
    fi

    if [[ -d "${data_dir}" ]]; then
        warn "Removing incomplete PGDATA ${data_dir}"
        sudo rm -rf "${data_dir}"
    fi

    sudo mkdir -p "${data_dir}" "${SOCKET_DIR}"
    sudo chown postgres:postgres "${data_dir}" "${SOCKET_DIR}"
    sudo chmod 0700 "${SOCKET_DIR}"

    local -a initdb_args=()
    while IFS= read -r -d '' arg; do initdb_args+=("$arg"); done \
        < <(debian_initdb_checksum_args "$pg_major")
    initdb_args+=(--set "shared_preload_libraries=pg_tde")
    initdb_args+=(--set "unix_socket_directories=${SOCKET_DIR}")

    info "initdb PG ${pg_major} at ${data_dir}"
    sudo -u postgres "${bin_dir}/initdb" -D "${data_dir}" "${initdb_args[@]}"

    debian_append_cluster_conf "${data_dir}" "${port}"
}

debian_run_pg_tde_upgrade_cmd() {
    local extra_flag="${1:-}"
    sudo -u postgres bash -c "
        cd '${SOCKET_DIR}' && \
        '${NEW_BIN}/pg_tde_upgrade' \
            --old-bindir='${OLD_BIN}' \
            --new-bindir='${NEW_BIN}' \
            --old-datadir='${OLD_DATA}' \
            --new-datadir='${NEW_DATA}' \
            --socketdir='${SOCKET_DIR}' \
            -p '${OLD_PORT}' \
            -P '${NEW_PORT}' \
            ${extra_flag}
    "
}

debian_setup_cluster() {
    debian_base_paths
    debian_remove_legacy_pg_createclusters
    mkdir -p "${UPGRADE_DATA_DIR}"

    debian_initdb_cluster "${OLD_DATA}" "${OLD_BIN}" "${OLD_PG_MAJOR%%.*}" "${OLD_PORT}"
    debian_has_postgresql_conf "${OLD_DATA}" || die \
        "initdb did not create ${OLD_DATA}/postgresql.conf (check initdb output above)"

    debian_pg_ctl start "${OLD_BIN}" "${OLD_DATA}" "${OLD_PORT}"

    info "Populating pg_tde data (port ${OLD_PORT}, socket ${SOCKET_DIR})"
    sudo -u postgres psql -h "${SOCKET_DIR}" -p "${OLD_PORT}" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS pg_tde;
SELECT pg_tde_add_global_key_provider_file('major_upg_provider', '${KEYFILE}');
SELECT pg_tde_create_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
SELECT pg_tde_set_key_using_global_key_provider('major_upg_key', 'major_upg_provider');
DROP TABLE IF EXISTS major_upg_t;
CREATE TABLE major_upg_t (id INT PRIMARY KEY, payload TEXT) USING tde_heap;
INSERT INTO major_upg_t SELECT i, md5(i::text) FROM generate_series(1, 500) i;
SQL

    debian_pg_ctl stop "${OLD_BIN}" "${OLD_DATA}" "${OLD_PORT}"

    OLD_INSTALL_DIR="$(detect_install_dir "${OLD_PG_MAJOR}")" || \
        OLD_INSTALL_DIR="${OLD_BIN%/bin}"
    export OLD_INSTALL_DIR

    write_state
    ok "Debian setup complete: ${OLD_DATA} (500 rows in major_upg_t)"
}

debian_run_pg_tde_upgrade() {
    load_state
    debian_base_paths

    [[ -x "${NEW_BIN}/pg_tde_upgrade" ]] || \
        die "pg_tde_upgrade not found at ${NEW_BIN}/pg_tde_upgrade (install percona-pg-tde${NEW_PG_MAJOR%%.*})"
    debian_has_postgresql_conf "${OLD_DATA}" || die \
        "Missing ${OLD_DATA}/postgresql.conf — re-run --setup-only (pg_createcluster layout is not supported)"

    debian_pg_ctl stop "${OLD_BIN}" "${OLD_DATA}" "${OLD_PORT}"

    if [[ -d "${NEW_DATA}" ]]; then
        warn "Removing prior target PGDATA ${NEW_DATA}"
        sudo rm -rf "${NEW_DATA}"
    fi
    debian_initdb_cluster "${NEW_DATA}" "${NEW_BIN}" "${NEW_PG_MAJOR%%.*}" "${NEW_PORT}"
    debian_pg_ctl stop "${NEW_BIN}" "${NEW_DATA}" "${NEW_PORT}"

    warn "Using pg_tde_upgrade (required for pg_tde clusters per Percona doc)."

    info "pg_tde_upgrade --check"
    debian_run_pg_tde_upgrade_cmd "--check"

    info "pg_tde_upgrade (upgrade)"
    debian_run_pg_tde_upgrade_cmd ""

    NEW_INSTALL_DIR="$(detect_install_dir "${NEW_PG_MAJOR}")" || \
        NEW_INSTALL_DIR="${NEW_BIN%/bin}"
    export NEW_INSTALL_DIR
    write_state
    ok "pg_tde_upgrade finished"
}

debian_verify_cluster() {
    load_state
    debian_base_paths

    debian_pg_ctl start "${NEW_BIN}" "${NEW_DATA}" "${NEW_PORT}"

    info "ALTER EXTENSION pg_tde UPDATE + row check (port ${NEW_PORT})"
    sudo -u postgres psql -h "${SOCKET_DIR}" -p "${NEW_PORT}" -d postgres -v ON_ERROR_STOP=1 <<SQL
ALTER EXTENSION pg_tde UPDATE;
SELECT COUNT(*) AS major_upg_rows FROM major_upg_t;
SQL

    info "vacuumdb --all --analyze-in-stages (doc step 6)"
    sudo -u postgres "${NEW_BIN}/vacuumdb" -h "${SOCKET_DIR}" -p "${NEW_PORT}" \
        --all --analyze-in-stages

    debian_pg_ctl stop "${NEW_BIN}" "${NEW_DATA}" "${NEW_PORT}"

    ok "Debian verify complete (500 rows expected in major_upg_t)"

    if [[ "$SKIP_DROP" != true ]]; then
        info "Removing old PGDATA ${OLD_DATA}"
        debian_pg_ctl stop "${OLD_BIN}" "${OLD_DATA}" "${OLD_PORT}"
        sudo rm -rf "${OLD_DATA}"
    else
        warn "Keeping old PGDATA ${OLD_DATA} (--skip-drop)"
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
