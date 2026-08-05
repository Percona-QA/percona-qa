#!/usr/bin/env bash
# verify_pg_tde_checksums.sh — single-script PG-2399 pg_tde_checksums verification.
#
# Parity with:
#   postgresql/automation/tests/pg_tde_checksums_test.sh
#   postgresql/pytest/tests/test_tde_cli_tools.py::TestPgTdeChecksumsCLI
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh                    # sets INSTALL_DIR
#   ./scripts/verify_pg_tde_checksums.sh
#
#   INSTALL_DIR=/usr/lib/postgresql/18 ./scripts/verify_pg_tde_checksums.sh   # Ubuntu
#   INSTALL_DIR=/usr/pgsql-18 ./scripts/verify_pg_tde_checksums.sh            # RHEL
#   (or omit INSTALL_DIR — auto-detects from OS)
#   IO_METHOD=sync ./scripts/verify_pg_tde_checksums.sh
#   KEEP_WORKDIR=1 ./scripts/verify_pg_tde_checksums.sh   # leave $TEST_DIR for debug
#
# Environment:
#   INSTALL_DIR          PostgreSQL + pg_tde install root (required)
#   IO_METHOD            initdb io_method on PG 18+ (default: worker)
#   PG_TDE_CHECKSUMS_PORT  TCP port (default: 55432)
#   KEEP_WORKDIR         If 1, do not rm test directory on exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PYTEST_ROOT}/.env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${PYTEST_ROOT}/.env.sh"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "   ${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "   ${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo ""; echo "==> $*"; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

resolve_install_dir() {
    if [[ -n "${INSTALL_DIR:-}" ]]; then
        echo "${INSTALL_DIR}"
        return
    fi
    # shellcheck source=pg_os_env.sh
    source "${SCRIPT_DIR}/pg_os_env.sh"
    pg_os_detect
    pg_resolve_install_dir "${PG_MAJOR:-18}"
}

INSTALL_DIR="$(resolve_install_dir)" || {
    echo "ERROR: set INSTALL_DIR to your PostgreSQL install root (with bin/pg_tde_checksums)." >&2
    exit 2
}

for bin in initdb pg_ctl psql pg_checksums pg_tde_checksums; do
    if [[ ! -x "${INSTALL_DIR}/bin/${bin}" ]]; then
        echo "ERROR: ${INSTALL_DIR}/bin/${bin} not found or not executable." >&2
        exit 2
    fi
done

PG_MAJOR="$("${INSTALL_DIR}/bin/postgres" --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
IO_METHOD="${IO_METHOD:-worker}"
PORT="${PG_TDE_CHECKSUMS_PORT:-55432}"
TEST_DIR="${PG_TDE_CHECKSUMS_WORKDIR:-${PYTEST_ROOT}/.work/pg_tde_checksums_verify}"
PGDATA="${TEST_DIR}/data"
KEYFILE="${TEST_DIR}/checksum_test_keyring.file"
LOGFILE="${TEST_DIR}/postgresql.log"

export LD_LIBRARY_PATH="${INSTALL_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

initdb_args() {
    local -a args=(-k -D "$PGDATA" --set "shared_preload_libraries=pg_tde")
    if [[ "${PG_MAJOR}" -ge 18 ]]; then
        args+=(--set "io_method=${IO_METHOD}")
    fi
    printf '%s\0' "${args[@]}"
}

start_pg() {
    "${INSTALL_DIR}/bin/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -o "-p ${PORT}" start -w
}

stop_pg() {
    "${INSTALL_DIR}/bin/pg_ctl" -D "$PGDATA" stop -m fast -w 2>/dev/null || true
}

restart_pg() {
    stop_pg
    start_pg
}

psql_cmd() {
    "${INSTALL_DIR}/bin/psql" -v ON_ERROR_STOP=1 -p "$PORT" -d postgres "$@"
}

corrupt_data_page() {
    local file="$1"
    [[ -f "$file" ]] || fail "data file not found: $file"
    dd if=/dev/urandom of="$file" bs=1 count=16 seek=100 conv=notrunc status=none
}

run_pg_tde_checksums() {
    "${INSTALL_DIR}/bin/pg_tde_checksums" -c -D "$PGDATA"
}

cleanup() {
    stop_pg 2>/dev/null || true
    if [[ "${KEEP_WORKDIR:-0}" != "1" ]]; then
        rm -rf "$TEST_DIR"
    else
        echo "KEEP_WORKDIR=1 — left ${TEST_DIR}"
    fi
}
trap cleanup EXIT

echo "pg_tde_checksums verification (PG-2399)"
echo "  INSTALL_DIR=${INSTALL_DIR}"
echo "  PG_MAJOR=${PG_MAJOR}"
echo "  IO_METHOD=${IO_METHOD} (PG 18+ only)"
echo "  PORT=${PORT}"
echo "  WORKDIR=${TEST_DIR}"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

step "1. initdb with data checksums enabled (-k) and pg_tde preloaded"
readarray -d '' INIT_ARGS < <(initdb_args)
"${INSTALL_DIR}/bin/initdb" "${INIT_ARGS[@]}" >/dev/null
pass "initdb succeeded"

step "2. pg_checksums on fresh cluster (no extension yet)"
if "${INSTALL_DIR}/bin/pg_checksums" -c -D "$PGDATA" >/dev/null 2>&1; then
    pass "healthy cluster verified with pg_checksums"
else
    fail "pg_checksums reported errors on fresh cluster"
fi

step "3. pg_tde_checksums on fresh cluster (no extension yet)"
if run_pg_tde_checksums >/dev/null 2>&1; then
    pass "fresh cluster verified with pg_tde_checksums"
else
    fail "pg_tde_checksums reported errors on fresh cluster"
fi

step "4. start server and configure pg_tde (global file key + WAL encryption)"
start_pg
psql_cmd -c "CREATE EXTENSION pg_tde;"
psql_cmd -c "SELECT pg_tde_add_global_key_provider_file('global_keyring', '${KEYFILE}');"
psql_cmd -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_keyring');"
psql_cmd -c "SELECT pg_tde_set_default_key_using_global_key_provider('wal_key', 'global_keyring');"
psql_cmd -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg
pass "pg_tde extension, keyring, and WAL encryption configured"

step "5. create encrypted (tde_heap) and plain (heap) tables"
psql_cmd -c "CREATE TABLE test(id INT, val TEXT) USING tde_heap;"
psql_cmd -c "INSERT INTO test VALUES (1, 'before corruption');"
psql_cmd -c "CREATE TABLE test1(id INT, val TEXT) USING heap;"
psql_cmd -c "INSERT INTO test1 VALUES (1, 'before corruption');"
psql_cmd -c "CHECKPOINT;"
pass "tables created and checkpointed"

DB_OID="$(psql_cmd -t -A -c "SELECT oid FROM pg_database WHERE datname = 'postgres';")"
ENC_RELFILENODE="$(psql_cmd -t -A -c "SELECT pg_relation_filenode('test');")"
PLAIN_RELFILENODE="$(psql_cmd -t -A -c "SELECT pg_relation_filenode('test1');")"
ENC_DATA_FILE="${PGDATA}/base/${DB_OID}/${ENC_RELFILENODE}"
PLAIN_DATA_FILE="${PGDATA}/base/${DB_OID}/${PLAIN_RELFILENODE}"

step "6. pg_tde_checksums verify before corruption (both table types)"
stop_pg
if run_pg_tde_checksums >/dev/null 2>&1; then
    pass "pg_tde_checksums verified checksums on tde_heap + heap"
else
    fail "pg_tde_checksums failed before corruption"
fi

step "7. corrupt encrypted tde_heap page — expect checksum failure (PG-2399)"
corrupt_data_page "$ENC_DATA_FILE"
if run_pg_tde_checksums >/dev/null 2>&1; then
    fail "pg_tde_checksums should detect encrypted-table corruption but exited 0"
else
    pass "pg_tde_checksums detected encrypted-table corruption"
fi

step "8. corrupt plain heap page — expect checksum failure"
corrupt_data_page "$PLAIN_DATA_FILE"
if run_pg_tde_checksums >/dev/null 2>&1; then
    fail "pg_tde_checksums should detect plain-heap corruption but exited 0"
else
    pass "pg_tde_checksums detected plain-heap corruption"
fi

echo ""
echo "=== DONE: pg_tde_checksums verification passed ==="
