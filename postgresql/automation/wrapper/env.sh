#!/bin/bash

# Arguments passed from wrapper(test_runner.sh)
export SERVER_BUILD_PATH="$1"
export TESTNAME="$2"
export IO_METHOD="${3:-worker}"

# Build install location
export INSTALL_DIR="$SERVER_BUILD_PATH"

# Global variables
export RUN_DIR=/tmp/pgtest
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
