#!/usr/bin/env bash
# run_minor_upgrade_workflow.sh — End-to-end staged pg_tde minor upgrade (pytest).
#
# Installs Percona PG + pg_tde (source), runs Setup tests, upgrades packages,
# runs Verify tests. Same PostgreSQL major throughout (default 18.4.1 → 18.4.2).
#
# Usage:
#   cd postgresql/pytest
#   bash run_minor_upgrade_workflow.sh              # full workflow
#   bash run_minor_upgrade_workflow.sh --help
#
#   bash run_minor_upgrade_workflow.sh --skip-install   # packages already correct
#   bash run_minor_upgrade_workflow.sh --with-pg2381    # include PG-2381 scenario
#   bash run_minor_upgrade_workflow.sh --setup-only     # stop after Setup
#   bash run_minor_upgrade_workflow.sh --verify-only    # only Verify (after manual upgrade)
#
# Environment overrides:
#   PG_TDE_UPGRADE_DATA_DIR   persistent data parent (default: /var/lib/pg_tde_minor_upgrade)
#   OLD_PG_MAJOR              source PG + repo pin (default: 18.3)
#   NEW_PG_MAJOR              target PG + repo pin (default: 18.4)
#   OLD_REPO_COMPONENT        default: release
#   NEW_REPO_COMPONENT        default: testing
#   COMPONENTS                passed to setup_test_env.sh (default: server,pg_tde)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── defaults ─────────────────────────────────────────────────────────────────
UPGRADE_DATA_DIR="${PG_TDE_UPGRADE_DATA_DIR:-/var/lib/pg_tde_minor_upgrade}"
OLD_PG_MAJOR="${OLD_PG_MAJOR:-18.4.1}"
NEW_PG_MAJOR="${NEW_PG_MAJOR:-18.4.2}"
OLD_REPO_COMPONENT="${OLD_REPO_COMPONENT:-release}"
NEW_REPO_COMPONENT="${NEW_REPO_COMPONENT:-release}"
COMPONENTS="${COMPONENTS:-server,pg_tde}"

SKIP_INSTALL=false
WITH_PG2381=false
SETUP_ONLY=false
VERIFY_ONLY=false
UPGRADE_ONLY=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}WARN:${NC} $*"; }
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Full staged minor-upgrade workflow for tests/test_tde_minor_upgrade.py:
  1) install ${OLD_PG_MAJOR} (${OLD_REPO_COMPONENT}) + pytest venv
  2) TestPgTdeMinorUpgradeSetup (+ optional PG-2381, HA)
  3) install ${NEW_PG_MAJOR} (${NEW_REPO_COMPONENT})
  4) TestPgTdeMinorUpgradeVerify (+ optional PG-2381, HA)

Options:
  --skip-install     Skip both package-install phases (use current packages)
  --with-pg2381      Also run PG-2381 churn Setup and Verify
  --setup-only       Install old packages, run Setup, exit (for manual upgrade)
  --upgrade-only     Install new packages only, then exit
  --verify-only      Run Verify only (requires existing upgrade_state.json)
  --upgrade-data-dir PATH   Override PG_TDE_UPGRADE_DATA_DIR
  --old-pg-major VER        Default: ${OLD_PG_MAJOR}
  --new-pg-major VER        Default: ${NEW_PG_MAJOR}
  --old-repo COMPONENT      Default: ${OLD_REPO_COMPONENT}
  --new-repo COMPONENT      Default: ${NEW_REPO_COMPONENT}
  -h, --help         Show this help

Examples:
  bash $(basename "$0")
  sudo mkdir -p ${UPGRADE_DATA_DIR} && sudo chown "\$USER" ${UPGRADE_DATA_DIR}
  PG_TDE_UPGRADE_DATA_DIR=/data/pg_tde_minor bash $(basename "$0") --with-pg2381
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-install)     SKIP_INSTALL=true; shift ;;
        --with-pg2381)      WITH_PG2381=true; shift ;;
        --setup-only)       SETUP_ONLY=true; shift ;;
        --upgrade-only)     UPGRADE_ONLY=true; shift ;;
        --verify-only)      VERIFY_ONLY=true; shift ;;
        --upgrade-data-dir) UPGRADE_DATA_DIR="$2"; shift 2 ;;
        --old-pg-major)     OLD_PG_MAJOR="$2"; shift 2 ;;
        --new-pg-major)     NEW_PG_MAJOR="$2"; shift 2 ;;
        --old-repo)         OLD_REPO_COMPONENT="$2"; shift 2 ;;
        --new-repo)         NEW_REPO_COMPONENT="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

export PG_TDE_UPGRADE_DATA_DIR="$UPGRADE_DATA_DIR"

if [[ "$(id -u)" -eq 0 ]]; then
    die "Do not run as root. setup_test_env.sh uses sudo for package install."
fi

if [[ ! -f "${SCRIPT_DIR}/setup_test_env.sh" ]]; then
    die "Missing ${SCRIPT_DIR}/setup_test_env.sh"
fi

# ── helpers ────────────────────────────────────────────────────────────────────

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

source_env() {
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.sh"
    export PG_TDE_UPGRADE_DATA_DIR="$UPGRADE_DATA_DIR"
}

check_verify_target_packages() {
    local ver
    ver="$("${INSTALL_DIR}/bin/postgres" --version 2>&1 || true)"
    if [[ "$ver" != *"${NEW_PG_MAJOR}"* ]]; then
        die "Verify expects PostgreSQL ${NEW_PG_MAJOR} on disk, but got: ${ver}. \
Run the full workflow or: bash $(basename "$0") --upgrade-only"
    fi
    local ctrl ver_line=""
    for ctrl in \
        "${INSTALL_DIR}/share/postgresql/extension/pg_tde.control" \
        "${INSTALL_DIR}/share/extension/pg_tde.control"
    do
        if [[ -f "$ctrl" ]]; then
            ver_line="$(grep -E '^default_version' "$ctrl" || true)"
            break
        fi
    done
    info "Package check for Verify: ${ver} | ${ver_line}"
}

show_versions() {
    local label="$1"
    echo ""
    info "Versions (${label})"
    echo "  INSTALL_DIR=${INSTALL_DIR:-<unset>}"
    if [[ -n "${INSTALL_DIR:-}" && -x "${INSTALL_DIR}/bin/postgres" ]]; then
        echo "  postgres: $("${INSTALL_DIR}/bin/postgres" --version 2>&1 || true)"
        local ctrl
        for ctrl in \
            "${INSTALL_DIR}/share/postgresql/extension/pg_tde.control" \
            "${INSTALL_DIR}/share/extension/pg_tde.control"
        do
            if [[ -f "$ctrl" ]]; then
                echo "  pg_tde.control: $(grep -E '^default_version' "$ctrl" || true)"
                break
            fi
        done
    else
        warn "postgres binary not found under INSTALL_DIR"
    fi
}

ensure_pytest_env() {
    if [[ ! -x "${SCRIPT_DIR}/.venv/bin/pytest" ]]; then
        info "Creating Python venv and dependencies (setup_test_env without --install-pkgs)"
        bash "${SCRIPT_DIR}/setup_test_env.sh" \
            --pg-major "${OLD_PG_MAJOR}" \
            --repo-component "${OLD_REPO_COMPONENT}" \
            || bash "${SCRIPT_DIR}/setup_test_env.sh"
    fi
}

assert_state_file() {
    local scenario="$1"
    local path="${UPGRADE_DATA_DIR}/${scenario}/upgrade_state.json"
    if [[ ! -f "$path" ]]; then
        die "Missing staged state: ${path} (Setup did not complete for scenario '${scenario}')"
    fi
    ok "Found ${path}"
}

ok() { echo -e "  ${GREEN}OK${NC}  $*"; }

run_setup_tests() {
    info "Phase: pytest Setup (pg_tde on ${OLD_PG_MAJOR} packages)"
    mkdir -p "${UPGRADE_DATA_DIR}"

    local pytest_args=(
        tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup::test_prepare_persistent_state_for_minor_upgrade
        tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetupHA::test_prepare_persistent_ha_state_for_minor_upgrade
    )
    if [[ "$WITH_PG2381" == true ]]; then
        pytest_args+=(
            tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeSetup::test_prepare_pg2381_churn_for_minor_upgrade
        )
    fi

    "${SCRIPT_DIR}/.venv/bin/pytest" "${pytest_args[@]}" -v \
        --install-dir="${INSTALL_DIR}" \
        --upgrade-data-dir="${UPGRADE_DATA_DIR}"

    assert_state_file "single"
    assert_state_file "ha"
    if [[ "$WITH_PG2381" == true ]]; then
        assert_state_file "single_pg2381"
    fi
}

run_verify_tests() {
    info "Phase: pytest Verify (pg_tde on ${NEW_PG_MAJOR} packages)"
    assert_state_file "single"
    assert_state_file "ha"

    local pytest_args=(
        tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerify::test_minor_upgrade_verification_flow
        tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerifyHA::test_ha_minor_upgrade_verification_flow
    )
    if [[ "$WITH_PG2381" == true ]]; then
        assert_state_file "single_pg2381"
        pytest_args+=(
            tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeVerify::test_verify_pg2381_churn_after_minor_upgrade
        )
    fi

    "${SCRIPT_DIR}/.venv/bin/pytest" "${pytest_args[@]}" -v \
        --install-dir="${INSTALL_DIR}" \
        --upgrade-data-dir="${UPGRADE_DATA_DIR}"
}

# ── main flow ──────────────────────────────────────────────────────────────────

echo ""
echo "======================================================================"
echo " pg_tde staged minor-upgrade workflow"
echo "  data dir : ${UPGRADE_DATA_DIR}"
echo "  source   : PG ${OLD_PG_MAJOR} (${OLD_REPO_COMPONENT})"
echo "  target   : PG ${NEW_PG_MAJOR} (${NEW_REPO_COMPONENT})"
echo "======================================================================"

ensure_pytest_env

if [[ "$VERIFY_ONLY" == true ]]; then
    if [[ "$SKIP_INSTALL" != true ]]; then
        install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
    fi
    source_env
    show_versions "verify"
    check_verify_target_packages
    run_verify_tests
    info "Verify-only workflow finished successfully."
    exit 0
fi

if [[ "$UPGRADE_ONLY" == true ]]; then
    install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
    source_env
    show_versions "after package upgrade"
    info "Upgrade-only finished. Run: $0 --verify-only --skip-install"
    exit 0
fi

# ── Phase 1: old packages + Setup ───────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${OLD_PG_MAJOR}" "${OLD_REPO_COMPONENT}"
fi
source_env
show_versions "before Setup (source packages)"
run_setup_tests

if [[ "$SETUP_ONLY" == true ]]; then
    info "Setup-only finished. Upgrade packages, then run:"
    echo "  bash $(basename "$0") --upgrade-only"
    echo "  bash $(basename "$0") --verify-only --skip-install"
    exit 0
fi

# ── Phase 2: new packages ───────────────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${NEW_PG_MAJOR}" "${NEW_REPO_COMPONENT}"
fi
source_env
show_versions "before Verify (target packages)"
check_verify_target_packages

# ── Phase 3: Verify ─────────────────────────────────────────────────────────
run_verify_tests

echo ""
info "Full minor-upgrade workflow finished successfully."
echo "  Staged data kept at: ${UPGRADE_DATA_DIR}"
echo "  Doc: ${SCRIPT_DIR}/docs/minor_upgrade.md"
