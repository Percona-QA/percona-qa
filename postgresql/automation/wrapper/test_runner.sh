#!/bin/bash

set -e

############################################
# Resolve wrapper directory paths
############################################
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="$(realpath "$WRAPPER_DIR/../helper_scripts")"
TEST_DIR="$(realpath "$WRAPPER_DIR/../tests")"

export WRAPPER_DIR
export HELPER_DIR

############################################
# Argument Parsing
############################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --server_version) SERVER_VERSION="$2"; shift;;
    --pg_tde_version) PG_TDE_VERSION="$2"; shift;;
    --server_branch) SERVER_BRANCH="$2"; shift;;
    --pg_tde_branch) PG_TDE_BRANCH="$2"; shift;;
    --server_build_path) SERVER_BUILD_PATH="$2"; shift;;
    --testname) TESTNAME="$2"; shift;;
    --skip-test) SKIP_LIST="$2"; shift;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

############################################
# Process Skip List
############################################
SKIPLIST=()
if [[ -n "$SKIP_LIST" ]]; then
    IFS=',' read -ra SKIPLIST <<< "$SKIP_LIST"
fi

############################################
# Load env + common functions
############################################
source "$WRAPPER_DIR/env.sh" \
  "$SERVER_VERSION" \
  "$PG_TDE_VERSION" \
  "$SERVER_BRANCH" \
  "$PG_TDE_BRANCH" \
  "$SERVER_BUILD_PATH" \
  "$TESTNAME"

############################################
# Dependency Checks
############################################
check_dependency() {
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "❌ ERROR: Required utility '$bin' not installed."
        MISSING+=("$bin")
    fi
}

MISSING=()
check_dependency sysbench
check_dependency unzip
check_dependency tar
check_dependency jq
check_dependency go

if (( ${#MISSING[@]} > 0 )); then
    echo ""
    echo "Missing dependencies: ${MISSING[*]}"
    echo "Install them and retry."
    exit 1
fi

source "$WRAPPER_DIR/common.sh"
source "$HELPER_DIR/setup_vault.sh"
source "$HELPER_DIR/setup_openbao.sh"
source "$HELPER_DIR/setup_kmip.sh"

############################################
# Prepare Run Directory
############################################
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

############################################
# Test List Construction
############################################
if [[ -n "$TESTNAME" ]]; then
    # Convert comma-separated list → bash array
    IFS=',' read -ra TESTLIST <<< "$TESTNAME"

    TESTS=()
    for t in "${TESTLIST[@]}"; do
        if [[ -f "$TEST_DIR/$t" ]]; then
            TESTS+=("$TEST_DIR/$t")
        else
            echo "❌ ERROR: Test '$t' not found in $TEST_DIR"
            exit 1
        fi
    done
else
    # Run all tests
    TESTS=("$TEST_DIR"/*.sh)
fi

############################################
# Filter out skipped tests
############################################
if (( ${#SKIPLIST[@]} > 0 )); then
    FILTERED=()
    for t in "${TESTS[@]}"; do
        base=$(basename "$t")
        skip=false
        for s in "${SKIPLIST[@]}"; do
            if [[ "$base" == "$s" ]]; then
                skip=true
                break
            fi
        done
        if ! $skip; then
            FILTERED+=("$t")
        fi
    done
    TESTS=("${FILTERED[@]}")
fi

############################################
# Print Banner
############################################
echo "==============================================="
echo "Starting pg_tde Test Suite"
echo "Server Version:    $SERVER_VERSION"
echo "pg_tde Version:    $PG_TDE_VERSION"
echo "Server Branch:     $SERVER_BRANCH"
echo "pg_tde Branch:     $PG_TDE_BRANCH"
echo "Server Build path: $SERVER_BUILD_PATH"
echo "==============================================="

############################################
# Prepare Log Directory
############################################
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

############################################
# Execute Tests
############################################

for testscript in "${TESTS[@]}"; do
    testname=$(basename "$testscript")
    echo ""
    echo "--------------------------------------------------"
    echo " Running Test: $testname"
    echo "--------------------------------------------------"

    LOGFILE="$LOG_DIR/${testname%.sh}.log"

    # Run test and capture exit code
    set +e

    (
        set -euo pipefail
        source "$testscript"
    ) >"$LOGFILE" 2>&1

    exitcode=$?
    set -e

    if (( exitcode == 0 )); then
        echo "✅ PASS: $testname"
        echo "   Log: $LOGFILE"
    else
        echo "❌ FAIL: $testname"
        echo "   Log: $LOGFILE"
    fi
done

echo ""
echo "==============================================="
echo " ALL TESTS COMPLETED "
echo " Logs saved in: $LOG_DIR"
echo "==============================================="
