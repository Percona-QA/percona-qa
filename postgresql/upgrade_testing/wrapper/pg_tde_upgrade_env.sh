#!/bin/bash

# Arguments passed from wrapper(pg_tde_upgrade_runner.sh)
export OLD_SERVER_BUILD_PATH="$1"
export NEW_SERVER_BUILD_PATH="$2"
export TESTNAME="$3"
export IO_METHOD="${4:-worker}"

# Build install location
export OLD_INSTALL_DIR="$OLD_SERVER_BUILD_PATH"
export NEW_INSTALL_DIR="$NEW_SERVER_BUILD_PATH"

# Global variables
export RUN_DIR="/tmp/pgtest"
export OLD_PGDATA="$RUN_DIR/old_data"
export NEW_PGDATA="$RUN_DIR/new_data"
export PGHOST=$RUN_DIR

export OLD_PGLOG="$OLD_PGDATA/server.log"
export NEW_PGLOG="$NEW_PGDATA/server.log"

export OLD_PORT=5454
export NEW_PORT=5464

export LOG_DIR="$RUN_DIR/test_logs"
export FAILED_DIR="$RUN_DIR/failed_tests"
