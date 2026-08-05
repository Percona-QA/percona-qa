#!/bin/bash

# Arguments passed from wrapper(test_runner.sh)
# SERVER_BUILD_PATH may be empty — resolve OS-aware package install dir.
_AUTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../pytest/scripts/pg_os_env.sh
source "${_AUTO_ROOT}/../pytest/scripts/pg_os_env.sh"
pg_os_detect

PG_MAJOR="${PG_MAJOR:-18}"
if [[ -z "${1:-}" ]]; then
    SERVER_BUILD_PATH="$(pg_resolve_install_dir "${PG_MAJOR}")"
else
    SERVER_BUILD_PATH="$1"
fi
export SERVER_BUILD_PATH
export TESTNAME="$2"
export IO_METHOD="${3:-worker}"
# Optional: old PostgreSQL installation for cross-version upgrade tests (e.g. PG-17 -> PG-18).
# Defaults to SERVER_BUILD_PATH when not supplied (same-version upgrade path).
if [[ -n "${4:-}" ]]; then
    export OLD_SERVER_BUILD_PATH="$4"
else
    export OLD_SERVER_BUILD_PATH="$SERVER_BUILD_PATH"
fi

# Build install locations
export INSTALL_DIR="$SERVER_BUILD_PATH"
export OLD_INSTALL_DIR="$OLD_SERVER_BUILD_PATH"

# Global variables
export RUN_DIR="/tmp/pgtest"
export PGDATA="$RUN_DIR/data"
export PRIMARY_DATA=$RUN_DIR/primary_data
export REPLICA_DATA=$RUN_DIR/replica_data

# Add postgres binaries to PATH
export PATH="$INSTALL_DIR/bin:$PATH"
export PGHOST=$RUN_DIR
export PGPORT=5432
export PGDATABASE=postgres

export PGLOG="$PGDATA/server.log"
export PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
export REPLICA_LOGFILE=$REPLICA_DATA/server.log

export PORT=5432
export PRIMARY_PORT=5433
export REPLICA_PORT=5434

export LOG_DIR="$RUN_DIR/test_logs"
export ARCHIVE_DIR="$RUN_DIR/wal_archive"
export BACKUP_DIR="$RUN_DIR/base_backup"
export FAILED_DIR="$RUN_DIR/failed_tests"
