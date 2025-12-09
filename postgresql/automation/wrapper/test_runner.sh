#!/bin/bash
set -e

############################################
# Resolve wrapper directory paths
############################################
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="$(realpath "$WRAPPER_DIR/../helper_scripts")"
TEST_DIR="$(realpath "$WRAPPER_DIR/../tests")"
LOG_DIR="$(realpath "$WRAPPER_DIR/../test_logs")"

export WRAPPER_DIR
export HELPER_DIR
export LOG_DIR


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
    --pg_tde_build_path) PG_TDE_BUILD_PATH="$2"; shift;;
    --testname) TESTNAME="$2"; shift;;  # NEW
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

############################################
# Load env + common functions
############################################
source "$WRAPPER_DIR/env.sh" \
  "$SERVER_VERSION" \
  "$PG_TDE_VERSION" \
  "$SERVER_BRANCH" \
  "$PG_TDE_BRANCH" \
  "$SERVER_BUILD_PATH" \
  "$PG_TDE_BUILD_PATH"

source "$WRAPPER_DIR/common.sh"
source "$HELPER_DIR/setup_vault.sh"
source "$HELPER_DIR/setup_openbao.sh"
source "$HELPER_DIR/setup_kmip.sh"

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
# Print Banner
############################################
echo "==============================================="
echo "Starting pg_tde Test Suite"
echo "Server Version:    $SERVER_VERSION"
echo "pg_tde Version:    $PG_TDE_VERSION"
echo "Server Branch:     $SERVER_BRANCH"
echo "pg_tde Branch:     $PG_TDE_BRANCH"
echo "==============================================="

############################################
# Prepare log folder
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

    if source "$testscript" > "$LOGFILE" 2>&1; then
        echo "✅ PASS: $testname"
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
