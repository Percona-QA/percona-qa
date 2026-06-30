#!/usr/bin/env bash
# run_minor_upgrade_workflow.sh — End-to-end staged pg_tde minor upgrade (pytest).
#
# Installs Percona PG + pg_tde (source), runs Setup tests, upgrades packages,
# runs Verify tests. Same PostgreSQL integer major throughout (default 18.4.1 → 18.4.2).
#
# Version terminology (three distinct values — do not overload PG_MAJOR):
#   PG_MAJOR           Integer PostgreSQL major (18) — package suffix, install path
#   PG_REPO_LINE       Percona repo line (18.4) → percona-release enable ppg-18.4
#   SERVER_VERSION     Patch (18.4.1) — postgres --version; apt tier selects the patch
#                      (release → 18.4.1, testing → 18.4.2)
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
#   OLD_SERVER_VERSION        source patch (default: 18.4.1)
#   NEW_SERVER_VERSION        target patch (default: 18.4.2)
#   PG_REPO_LINE              Percona repo line (default: derived from OLD_SERVER_VERSION → 18.4)
#   PG_MAJOR                  Integer major (default: derived from PG_REPO_LINE → 18)
#   OLD_REPO_COMPONENT        Percona repo tier for source install (default: release)
#   NEW_REPO_COMPONENT        Percona repo tier for target install (default: testing)
#   COMPONENTS                passed to setup_test_env.sh (default: server,pg_tde)
#
# Legacy aliases (deprecated): OLD_PG_VERSION, NEW_PG_VERSION, OLD_PG_MAJOR, NEW_PG_MAJOR
#
# Repo policy (QA default): OLD=release (shipped build), NEW=testing (candidate patch).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── defaults ─────────────────────────────────────────────────────────────────
UPGRADE_DATA_DIR="${PG_TDE_UPGRADE_DATA_DIR:-/var/lib/pg_tde_minor_upgrade}"

# SERVER_VERSION: patch level verified via postgres --version
OLD_SERVER_VERSION="${OLD_SERVER_VERSION:-${OLD_PG_VERSION:-${OLD_PG_MAJOR:-18.4.1}}}"
NEW_SERVER_VERSION="${NEW_SERVER_VERSION:-${NEW_PG_VERSION:-${NEW_PG_MAJOR:-18.4.2}}}"

OLD_REPO_COMPONENT="${OLD_REPO_COMPONENT:-release}"
NEW_REPO_COMPONENT="${NEW_REPO_COMPONENT:-testing}"
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

server_version_to_repo_line() {
    # 18.4.1 → 18.4, 17.10.2 → 17.10
    local ver="$1"
    if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
        echo "$ver"
    fi
}

resolve_version_defaults() {
    PG_REPO_LINE="${PG_REPO_LINE:-$(server_version_to_repo_line "$OLD_SERVER_VERSION")}"
    PG_MAJOR="${PG_MAJOR:-${PG_REPO_LINE%%.*}}"

    [[ -n "${OLD_PG_VERSION:-}" ]] && warn "OLD_PG_VERSION is deprecated; use OLD_SERVER_VERSION"
    [[ -n "${NEW_PG_VERSION:-}" ]] && warn "NEW_PG_VERSION is deprecated; use NEW_SERVER_VERSION"
    if [[ -n "${OLD_PG_MAJOR:-}" && "${OLD_PG_MAJOR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "OLD_PG_MAJOR as patch is deprecated; use OLD_SERVER_VERSION (PG_MAJOR is integer major only)"
    fi
    if [[ -n "${NEW_PG_MAJOR:-}" && "${NEW_PG_MAJOR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "NEW_PG_MAJOR as patch is deprecated; use NEW_SERVER_VERSION (PG_MAJOR is integer major only)"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Full staged minor-upgrade workflow for tests/test_tde_minor_upgrade.py:
  1) install SERVER_VERSION=${OLD_SERVER_VERSION} (ppg-${PG_REPO_LINE}, ${OLD_REPO_COMPONENT}) + pytest venv
  2) TestPgTdeMinorUpgradeSetup (+ optional PG-2381, HA)
  3) install SERVER_VERSION=${NEW_SERVER_VERSION} (ppg-${PG_REPO_LINE}, ${NEW_REPO_COMPONENT})
  4) TestPgTdeMinorUpgradeVerify (+ optional PG-2381, HA)

Version model:
  PG_MAJOR=${PG_MAJOR}           integer major (unchanged across minor upgrade)
  PG_REPO_LINE=${PG_REPO_LINE}     percona-release repo line
  SERVER_VERSION                 patch from postgres --version (apt tier selects it)

Options:
  --skip-install     Skip both package-install phases (use current packages)
  --with-pg2381      Also run PG-2381 churn Setup and Verify
  --setup-only       Install old packages, run Setup, exit (for manual upgrade)
  --upgrade-only     Install new packages only, then exit
  --verify-only      Run Verify only (requires existing upgrade_state.json)
  --upgrade-data-dir PATH   Override PG_TDE_UPGRADE_DATA_DIR
  --old-server-version VER  Source patch (default: ${OLD_SERVER_VERSION})
  --new-server-version VER  Target patch (default: ${NEW_SERVER_VERSION})
  --pg-repo-line VER        Percona repo line (default: ${PG_REPO_LINE})
  --pg-major VER            Integer PG major (default: ${PG_MAJOR})
  --old-repo COMPONENT      Default: ${OLD_REPO_COMPONENT}
  --new-repo COMPONENT      Default: ${NEW_REPO_COMPONENT}
  --old-pg-major VER        Deprecated alias for --old-server-version
  --new-pg-major VER        Deprecated alias for --new-server-version
  -h, --help         Show this help

Examples:
  bash $(basename "$0")
  OLD_SERVER_VERSION=17.10.1 NEW_SERVER_VERSION=17.10.2 bash $(basename "$0")
  PG_TDE_UPGRADE_DATA_DIR=/data/pg_tde_minor bash $(basename "$0") --with-pg2381
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-install)         SKIP_INSTALL=true; shift ;;
        --with-pg2381)          WITH_PG2381=true; shift ;;
        --setup-only)           SETUP_ONLY=true; shift ;;
        --upgrade-only)         UPGRADE_ONLY=true; shift ;;
        --verify-only)          VERIFY_ONLY=true; shift ;;
        --upgrade-data-dir)     UPGRADE_DATA_DIR="$2"; shift 2 ;;
        --old-server-version)   OLD_SERVER_VERSION="$2"; shift 2 ;;
        --new-server-version)   NEW_SERVER_VERSION="$2"; shift 2 ;;
        --pg-repo-line)         PG_REPO_LINE="$2"; shift 2 ;;
        --pg-major)             PG_MAJOR="$2"; shift 2 ;;
        --old-pg-major)         warn "--old-pg-major is deprecated; use --old-server-version"; OLD_SERVER_VERSION="$2"; shift 2 ;;
        --new-pg-major)         warn "--new-pg-major is deprecated; use --new-server-version"; NEW_SERVER_VERSION="$2"; shift 2 ;;
        --old-repo)             OLD_REPO_COMPONENT="$2"; shift 2 ;;
        --new-repo)             NEW_REPO_COMPONENT="$2"; shift 2 ;;
        -h|--help)              resolve_version_defaults; usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

resolve_version_defaults

export PG_TDE_UPGRADE_DATA_DIR="$UPGRADE_DATA_DIR"

if [[ "$(id -u)" -eq 0 ]]; then
    die "Do not run as root. setup_test_env.sh uses sudo for package install."
fi

if [[ ! -f "${SCRIPT_DIR}/setup_test_env.sh" ]]; then
    die "Missing ${SCRIPT_DIR}/setup_test_env.sh"
fi

# ── helpers ────────────────────────────────────────────────────────────────────

install_packages() {
    local repo_component="$1"
    local expected_server_version="$2"
    info "Installing packages: PG_MAJOR=${PG_MAJOR} ppg-${PG_REPO_LINE} [${repo_component}] → SERVER_VERSION ${expected_server_version}"
    bash "${SCRIPT_DIR}/setup_test_env.sh" \
        --install-pkgs \
        --pg-major "${PG_MAJOR}" \
        --pg-repo-line "${PG_REPO_LINE}" \
        --server-version "${expected_server_version}" \
        --repo-component "${repo_component}" \
        --components "${COMPONENTS}"
}

check_server_version() {
    local expected="$1"
    local label="$2"
    local ver
    ver="$("${INSTALL_DIR}/bin/postgres" --version 2>&1 || true)"
    if [[ "$ver" != *"${expected}"* ]]; then
        die "${label}: expected SERVER_VERSION ${expected}, got: ${ver}"
    fi
    ok "SERVER_VERSION ${expected} confirmed (${label})"
}

source_env() {
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.sh"
    export PG_TDE_UPGRADE_DATA_DIR="$UPGRADE_DATA_DIR"
}

ensure_upgrade_data_dir() {
    if [[ -d "$UPGRADE_DATA_DIR" ]] && [[ -w "$UPGRADE_DATA_DIR" ]]; then
        ok "Upgrade data dir ready: ${UPGRADE_DATA_DIR}"
        return
    fi
    info "Creating ${UPGRADE_DATA_DIR} (sudo)"
    sudo mkdir -p "$UPGRADE_DATA_DIR"
    sudo chown "$(id -un):$(id -gn)" "$UPGRADE_DATA_DIR"
    ok "Upgrade data dir ready: ${UPGRADE_DATA_DIR}"
}

print_install_versions() {
    local prefix="$1"
    local dir="$2"
    if [[ -z "${dir}" || ! -x "${dir}/bin/postgres" ]]; then
        warn "Cannot show versions: missing postgres under ${dir:-<unset>}"
        return
    fi
    if [[ -x "${SCRIPT_DIR}/.venv/bin/python" ]]; then
        (
            cd "${SCRIPT_DIR}"
            "${SCRIPT_DIR}/.venv/bin/python" - "${dir}" "${prefix}" <<'PY' || true
import sys
from pathlib import Path
from lib.cluster import install_version_summary_lines
install_dir = Path(sys.argv[1])
prefix = sys.argv[2]
for line in install_version_summary_lines(install_dir, prefix=prefix):
    print(f"  {line}")
PY
        )
        return
    fi
    echo "  ${prefix}PostgreSQL server: $("${dir}/bin/postgres" --version 2>&1)"
    local ctrl
    for ctrl in \
        "${dir}/share/postgresql/extension/pg_tde.control" \
        "${dir}/share/extension/pg_tde.control"
    do
        if [[ -f "$ctrl" ]]; then
            echo "  ${prefix}pg_tde.control default_version: $(grep -E '^default_version' "$ctrl" | cut -d= -f2 | tr -d "' '")"
            break
        fi
    done
}

print_staged_state_versions() {
    local scenario="$1"
    local state_file="${UPGRADE_DATA_DIR}/${scenario}/upgrade_state.json"
    if [[ ! -f "$state_file" ]]; then
        return
    fi
    if [[ ! -x "${SCRIPT_DIR}/.venv/bin/python" ]]; then
        return
    fi
    (
        cd "${SCRIPT_DIR}"
        "${SCRIPT_DIR}/.venv/bin/python" - "${state_file}" <<'PY' 2>/dev/null || true
import sys
import json
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
old_bin = state.get("old_pg_tde_binary_version") or ""
old_ext = state.get("old_extversion") or ""
if old_bin:
    print(f"  staged Setup pg_tde_version(): {old_bin}")
if old_ext:
    print(f"  staged Setup catalog extversion: {old_ext}")
PY
    )
}

show_versions() {
    local label="$1"
    echo ""
    info "Versions (${label})"
    echo "  PG_MAJOR=${PG_MAJOR}  PG_REPO_LINE=${PG_REPO_LINE}"
    echo "  OLD_SERVER_VERSION=${OLD_SERVER_VERSION}  NEW_SERVER_VERSION=${NEW_SERVER_VERSION}"
    echo "  INSTALL_DIR=${INSTALL_DIR:-<unset>}"
    if [[ -n "${INSTALL_DIR:-}" ]]; then
        print_install_versions "" "${INSTALL_DIR}"
    else
        warn "INSTALL_DIR not set"
    fi
    if [[ "$label" == *Verify* || "$label" == *verify* ]]; then
        print_staged_state_versions "single"
        print_staged_state_versions "ha"
    fi
}

check_verify_target_packages() {
    show_versions "Verify package check"
    check_server_version "${NEW_SERVER_VERSION}" "verify target"
}

ensure_pytest_env() {
    if [[ ! -x "${SCRIPT_DIR}/.venv/bin/pytest" ]]; then
        info "Creating Python venv and dependencies (setup_test_env without --install-pkgs)"
        bash "${SCRIPT_DIR}/setup_test_env.sh" \
            --pg-major "${PG_MAJOR}" \
            --pg-repo-line "${PG_REPO_LINE}" \
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
    info "Phase: pytest Setup (SERVER_VERSION ${OLD_SERVER_VERSION}, ppg-${PG_REPO_LINE})"
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

    "${SCRIPT_DIR}/.venv/bin/pytest" "${pytest_args[@]}" -v -s \
        --install-dir="${INSTALL_DIR}" \
        --upgrade-data-dir="${UPGRADE_DATA_DIR}"

    assert_state_file "single"
    assert_state_file "ha"
    if [[ "$WITH_PG2381" == true ]]; then
        assert_state_file "single_pg2381"
    fi
}

run_verify_tests() {
    info "Phase: pytest Verify (SERVER_VERSION ${NEW_SERVER_VERSION}, ppg-${PG_REPO_LINE})"
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

    "${SCRIPT_DIR}/.venv/bin/pytest" "${pytest_args[@]}" -v -s \
        --install-dir="${INSTALL_DIR}" \
        --upgrade-data-dir="${UPGRADE_DATA_DIR}"
}

# ── main flow ──────────────────────────────────────────────────────────────────

echo ""
echo "======================================================================"
echo " pg_tde staged minor-upgrade workflow"
echo "  data dir         : ${UPGRADE_DATA_DIR}"
echo "  PG_MAJOR         : ${PG_MAJOR} (integer major — unchanged)"
echo "  PG_REPO_LINE     : ${PG_REPO_LINE} (percona-release ppg-${PG_REPO_LINE})"
echo "  OLD_SERVER_VERSION: ${OLD_SERVER_VERSION} (repo=${OLD_REPO_COMPONENT})"
echo "  NEW_SERVER_VERSION: ${NEW_SERVER_VERSION} (repo=${NEW_REPO_COMPONENT})"
echo "  repos            : ${OLD_REPO_COMPONENT} → ${NEW_REPO_COMPONENT} (QA default: release → testing)"
echo "======================================================================"

ensure_upgrade_data_dir
ensure_pytest_env

if [[ "$VERIFY_ONLY" == true ]]; then
    if [[ "$SKIP_INSTALL" != true ]]; then
        install_packages "${NEW_REPO_COMPONENT}" "${NEW_SERVER_VERSION}"
    fi
    source_env
    show_versions "verify"
    check_verify_target_packages
    run_verify_tests
    info "Verify-only workflow finished successfully."
    exit 0
fi

if [[ "$UPGRADE_ONLY" == true ]]; then
    install_packages "${NEW_REPO_COMPONENT}" "${NEW_SERVER_VERSION}"
    source_env
    show_versions "after package upgrade"
    info "Upgrade-only finished. Run: $0 --verify-only --skip-install"
    exit 0
fi

# ── Phase 1: old packages + Setup ───────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${OLD_REPO_COMPONENT}" "${OLD_SERVER_VERSION}"
fi
source_env
show_versions "before Setup (source packages)"
check_server_version "${OLD_SERVER_VERSION}" "setup source"
run_setup_tests

if [[ "$SETUP_ONLY" == true ]]; then
    info "Setup-only finished. Upgrade packages, then run:"
    echo "  bash $(basename "$0") --upgrade-only"
    echo "  bash $(basename "$0") --verify-only --skip-install"
    exit 0
fi

# ── Phase 2: new packages ───────────────────────────────────────────────────
if [[ "$SKIP_INSTALL" != true ]]; then
    install_packages "${NEW_REPO_COMPONENT}" "${NEW_SERVER_VERSION}"
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
