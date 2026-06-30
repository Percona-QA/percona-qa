#!/usr/bin/env bash
# run_tde_upgrade_parallel.sh — Run major-upgrade bash matrix (Jenkins tde-upgrade-parallel parity).
#
# Executes the same upgrade bash scripts Jenkins typically runs in parallel stages.
# Locally runs sequentially; exit on first failure unless --continue-on-fail.
#
# Usage:
#   cd postgresql/pytest
#   bash run_tde_upgrade_parallel.sh
#   OLD_INSTALL_DIR=/opt/pg17 INSTALL_DIR=/opt/pg18 bash run_tde_upgrade_parallel.sh
#   bash run_tde_upgrade_parallel.sh --pytest-only   # skip bash, run pytest -m upgrade
#   bash run_tde_upgrade_parallel.sh --bash-only     # skip pytest
#
# Environment:
#   OLD_INSTALL_DIR   Source PostgreSQL prefix (default: /usr/lib/postgresql/17)
#   INSTALL_DIR       Target PostgreSQL prefix (default: /usr/lib/postgresql/18)
#   IO_METHOD         initdb io_method (default: worker)
#   SKIP_BASH         Comma-separated basenames to skip (e.g. pg_tde_upgrade_scenarios_test.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOMATION_WRAPPER="${REPO_ROOT}/postgresql/automation/wrapper"
UPGRADE_WRAPPER="${REPO_ROOT}/postgresql/upgrade_testing/wrapper"

OLD="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
NEW="${INSTALL_DIR:-/usr/lib/postgresql/18}"
IO="${IO_METHOD:-worker}"
BASH_ONLY=false
PYTEST_ONLY=false
CONTINUE_ON_FAIL=false

AUTOMATION_TESTS=(
  pg_tde_upgrade_test.sh
  pg_tde_upgrade_ppg_to_psp.sh
  pg_tde_upgrade_psp_to_psp.sh
  pg_tde_upgrade_access_method.sh
  pg_tde_upgrade_wal_encryption.sh
  pg_tde_upgrade_scenarios_test.sh
)

UPGRADE_TESTING_TESTS=(
  pg_tde_upgrade_basic_test.sh
  pg_tde_upgrade_wal_encryption.sh
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}WARN:${NC} $*"; }
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Major upgrade bash matrix (Jenkins tde-upgrade-parallel parity).

Options:
  --bash-only           Run automation + upgrade_testing bash only
  --pytest-only         Run pytest -m upgrade only
  --continue-on-fail    Do not stop after first bash failure
  --io-method METHOD    Default: ${IO}
  -h, --help            Show this help

Environment:
  OLD_INSTALL_DIR=${OLD}
  INSTALL_DIR=${NEW}
  SKIP_BASH             Comma-separated script basenames to skip
EOF
}

should_skip() {
  local name="$1"
  [[ -z "${SKIP_BASH:-}" ]] && return 1
  local s
  IFS=',' read -ra _skip <<< "$SKIP_BASH"
  for s in "${_skip[@]}"; do
    [[ "$name" == "$s" ]] && return 0
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bash-only)          BASH_ONLY=true; shift ;;
    --pytest-only)        PYTEST_ONLY=true; shift ;;
    --continue-on-fail)   CONTINUE_ON_FAIL=true; shift ;;
    --io-method)          IO="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -x "${OLD}/bin/postgres" ]] || die "OLD_INSTALL_DIR missing postgres: ${OLD}"
[[ -x "${NEW}/bin/postgres" ]] || die "INSTALL_DIR missing postgres: ${NEW}"
[[ -x "${NEW}/bin/pg_tde_upgrade" ]] || warn "pg_tde_upgrade not found under ${NEW}/bin (TDE upgrades may fail)"

FAILURES=()

run_automation_test() {
  local testname="$1"
  should_skip "$testname" && { warn "Skipping $testname (SKIP_BASH)"; return 0; }
  info "automation: $testname"
  if bash "${AUTOMATION_WRAPPER}/test_runner.sh" \
      --server_build_path "$NEW" \
      --old_server_build_path "$OLD" \
      --testname "$testname" \
      --io_method "$IO"
  then
    echo "  OK  $testname"
  else
    echo "  FAIL $testname"
    FAILURES+=("automation/$testname")
    $CONTINUE_ON_FAIL || return 1
  fi
}

run_bash_matrix() {
  [[ -d "$AUTOMATION_WRAPPER" ]] || die "Missing $AUTOMATION_WRAPPER"
  [[ -d "$UPGRADE_WRAPPER" ]] || die "Missing $UPGRADE_WRAPPER"

  info "Major upgrade bash matrix: OLD=$OLD NEW=$NEW IO=$IO"
  local t
  for t in "${AUTOMATION_TESTS[@]}"; do
    run_automation_test "$t" || $CONTINUE_ON_FAIL || break
  done

  local ut_list
  ut_list=$(IFS=,; echo "${UPGRADE_TESTING_TESTS[*]}")
  should_skip "pg_tde_upgrade_basic_test.sh" && should_skip "pg_tde_upgrade_wal_encryption.sh" && {
    warn "Skipping all upgrade_testing tests (SKIP_BASH)"
  } || {
    info "upgrade_testing: $ut_list"
    if bash "${UPGRADE_WRAPPER}/pg_tde_upgrade_runner.sh" \
        --old_server_build_path "$OLD" \
        --new_server_build_path "$NEW" \
        --testname "$ut_list" \
        --io_method "$IO"
    then
      echo "  OK  upgrade_testing suite"
    else
      echo "  FAIL upgrade_testing suite"
      FAILURES+=("upgrade_testing/suite")
      $CONTINUE_ON_FAIL || return 1
    fi
  }
}

run_pytest_matrix() {
  info "pytest -m upgrade: OLD=$OLD NEW=$NEW"
  cd "$SCRIPT_DIR"
  # shellcheck disable=SC1091
  [[ -f .env.sh ]] && source .env.sh
  export OLD_INSTALL_DIR="$OLD"
  export INSTALL_DIR="$NEW"

  local pytest_bin="${SCRIPT_DIR}/.venv/bin/pytest"
  [[ -x "$pytest_bin" ]] || pytest_bin="pytest"

  "$pytest_bin" -m upgrade \
    --old-install-dir="$OLD" \
    --install-dir="$NEW" \
    tests/test_tde_pg_upgrade.py tests/test_upgrade.py \
    -v --tb=short
}

echo ""
echo "======================================================================"
echo " tde-upgrade-parallel local driver"
echo "  OLD: $OLD"
echo "  NEW: $NEW"
echo "======================================================================"

if [[ "$PYTEST_ONLY" == true ]]; then
  run_pytest_matrix
elif [[ "$BASH_ONLY" == true ]]; then
  run_bash_matrix
else
  run_bash_matrix
  run_pytest_matrix
fi

if ((${#FAILURES[@]} > 0)); then
  die "Failures: ${FAILURES[*]}"
fi

info "All requested upgrade scenarios passed."
echo "  Doc: ${SCRIPT_DIR}/docs/ci_upgrade_scenarios.md"
