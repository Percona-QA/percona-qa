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
    --server_build_path) SERVER_BUILD_PATH="$2"; shift;;
    --old_server_build_path) OLD_SERVER_BUILD_PATH="$2"; shift;;
    --testname) TESTNAME="$2"; shift;;
    --skip_test) SKIP_LIST="$2"; shift;;
    --io_method) IO_METHOD="$2"; shift;;
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
  "$SERVER_BUILD_PATH" \
  "$TESTNAME" \
  "$IO_METHOD" \
  "${OLD_SERVER_BUILD_PATH:-}"

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
echo "Server Build path: $SERVER_BUILD_PATH"
echo "IO_METHOD: $IO_METHOD"
echo "==============================================="

############################################
# Prepare Log Directory
############################################
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

############################################
# Save per-test server logs before next test wipes data dirs
############################################
save_test_configs() {
    local base="${1%.sh}"
    local test_start="${2}"
    local test_dir="$LOG_DIR/$base"
    mkdir -p "$test_dir"

    # Move the test stdout/stderr log into the per-test folder
    [[ -f "$LOG_DIR/${base}.log" ]] && mv "$LOG_DIR/${base}.log" "$test_dir/${base}.log" 2>/dev/null || true

    # Server logs and config files from each data directory
    for dir in "$PGDATA" "$PRIMARY_DATA" "$REPLICA_DATA"; do
        local dirname
        dirname=$(basename "$dir")
        [[ -f "$dir/server.log"           ]] && cp "$dir/server.log"           "$test_dir/${dirname}-server.log"           2>/dev/null || true
        [[ -f "$dir/postgresql.conf"      ]] && cp "$dir/postgresql.conf"      "$test_dir/${dirname}-postgresql.conf"      2>/dev/null || true
        [[ -f "$dir/pg_hba.conf"          ]] && cp "$dir/pg_hba.conf"          "$test_dir/${dirname}-pg_hba.conf"          2>/dev/null || true
        [[ -f "$dir/postgresql.auto.conf" ]] && cp "$dir/postgresql.auto.conf" "$test_dir/${dirname}-postgresql.auto.conf" 2>/dev/null || true
    done

    # pgbackrest config — only if written/modified during this test
    if [[ -f "/etc/pgbackrest/pgbackrest.conf" ]] && \
       [[ "/etc/pgbackrest/pgbackrest.conf" -nt "$test_start" ]]; then
        cp "/etc/pgbackrest/pgbackrest.conf" "$test_dir/pgbackrest.conf" 2>/dev/null || true
    fi

    # Vault log — only if written/modified during this test
    if [[ -f "$LOG_DIR/vault.log" ]] && \
       [[ "$LOG_DIR/vault.log" -nt "$test_start" ]]; then
        cp "$LOG_DIR/vault.log" "$test_dir/vault.log" 2>/dev/null || true
    fi

    # OpenBao server log — only if written/modified during this test
    find "$RUN_DIR" -maxdepth 2 -name "bao_server.log" -newer "$test_start" 2>/dev/null \
        -exec cp {} "$test_dir/bao_server.log" \; || true

    # KMIP server runs as a Docker container ('kmip', started with --rm by
    # start_kmip_server). Capture its logs only if the container was (re)started
    # during this test, so a container lingering from an earlier test is not
    # misattributed here. Fully best-effort: a test that never uses KMIP simply
    # produces no file, and nothing in this block can fail the test.
    if command -v docker >/dev/null 2>&1; then
        local kmip_started kmip_epoch start_epoch
        kmip_started=$(docker inspect -f '{{.State.StartedAt}}' kmip 2>/dev/null || true)
        if [[ -n "$kmip_started" ]]; then
            kmip_epoch=$(date -d "$kmip_started" +%s 2>/dev/null || echo 0)
            start_epoch=$(stat -c %Y "$test_start" 2>/dev/null || echo 0)
            [[ "$kmip_epoch" -ge "$start_epoch" ]] && \
                docker logs kmip > "$test_dir/kmip-container.log" 2>&1 || true
        fi
    fi
}

############################################
# Execute Tests
############################################

# Bound the per-failure PGDATA snapshots saved under failed_tests/. Each one
# copies entire data directories, so a run with many failures can fill the disk
# and wipe out ALL artifacts (observed: ~20 failures x full PGDATA overflowed a
# 100 GB volume, so the host died before packaging and produced no logs). The
# per-test logs/<test>/ dir (server.log + configs) is always kept regardless.
# Override via env if needed.
FAIL_SNAPSHOT_MAX="${FAIL_SNAPSHOT_MAX:-3}"        # keep full data snapshots for at most N failures
FAIL_SNAPSHOT_DISK_PCT="${FAIL_SNAPSHOT_DISK_PCT:-80}"  # ...and only while disk is below this %
FAIL_SNAPSHOT_COUNT=0

for testscript in "${TESTS[@]}"; do
    testname=$(basename "$testscript")
    echo ""
    echo "--------------------------------------------------"
    echo " Running Test: $testname"
    echo "--------------------------------------------------"

    LOGFILE="$LOG_DIR/${testname%.sh}.log"

    # Record test start time via a temp marker file (used by save_test_configs
    # to detect which infra files were written during this specific test)
    TEST_START_MARKER=$(mktemp "$RUN_DIR/.test_start_XXXXXX")

    # Run test and capture exit code
    set +e

    (
        set -euo pipefail
        source "$testscript"
    ) >"$LOGFILE" 2>&1

    exitcode=$?
    set -e

    # Save server logs and config files immediately after each test, before
    # the next test wipes the data directories via initialize_server() / old_server_cleanup()
    save_test_configs "$testname" "$TEST_START_MARKER"
    rm -f "$TEST_START_MARKER"

    if (( exitcode == 0 )); then
        echo "✅ PASS: $testname"
        echo "   Log: $LOG_DIR/${testname%.sh}/${testname%.sh}.log"
    else
        echo "❌ FAIL: $testname"
        echo "   Log: $LOG_DIR/${testname%.sh}/${testname%.sh}.log"

        FAIL_SAVE_DIR="$FAILED_DIR/${testname%.sh}_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$FAIL_SAVE_DIR"

        # Always keep the (small) per-test log.
        cp "$LOG_DIR/${testname%.sh}/${testname%.sh}.log" "$FAIL_SAVE_DIR/" 2>/dev/null || true

        # Full PGDATA snapshot only while under the count cap AND disk is healthy,
        # so a cascade of failures can't fill the disk and destroy all artifacts.
        disk_used=$(df -P "$RUN_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
        disk_used=${disk_used:-0}
        if (( FAIL_SNAPSHOT_COUNT >= FAIL_SNAPSHOT_MAX )); then
            echo "Skipping PGDATA snapshot (snapshot cap $FAIL_SNAPSHOT_MAX reached); see logs/${testname%.sh}/"
        elif (( disk_used >= FAIL_SNAPSHOT_DISK_PCT )); then
            echo "Skipping PGDATA snapshot (disk ${disk_used}% >= ${FAIL_SNAPSHOT_DISK_PCT}%); see logs/${testname%.sh}/"
        else
            echo "Saving failed test artifacts (snapshot $((FAIL_SNAPSHOT_COUNT + 1))/$FAIL_SNAPSHOT_MAX)..."
            [[ -d "$PGDATA" ]]       && cp -r "$PGDATA"       "$FAIL_SAVE_DIR/" 2>/dev/null || true
            [[ -d "$PRIMARY_DATA" ]] && cp -r "$PRIMARY_DATA" "$FAIL_SAVE_DIR/" 2>/dev/null || true
            [[ -d "$REPLICA_DATA" ]] && cp -r "$REPLICA_DATA" "$FAIL_SAVE_DIR/" 2>/dev/null || true
            [[ -d "$ARCHIVE_DIR" ]]  && cp -r "$ARCHIVE_DIR"  "$FAIL_SAVE_DIR/" 2>/dev/null || true
            FAIL_SNAPSHOT_COUNT=$((FAIL_SNAPSHOT_COUNT + 1))
            echo "Artifacts saved at: $FAIL_SAVE_DIR"
        fi
    fi
done

echo ""
echo "==============================================="
echo " ALL TESTS COMPLETED "
echo " Logs saved in: $LOG_DIR"
echo "==============================================="
