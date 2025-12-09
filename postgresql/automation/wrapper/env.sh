#!/bin/bash

# Arguments passed from wrapper
export SERVER_VERSION="$1"
export PG_TDE_VERSION="$2"
export SERVER_BRANCH="$3"
export PG_TDE_BRANCH="$4"
export SERVER_BUILD_PATH="$5"
export PG_TDE_BUILD_PATH="$6"

# Build install location
export INSTALL_DIR="$SERVER_BUILD_PATH"

# Add postgres binaries to PATH
export PATH="$INSTALL_DIR/bin:$PATH"

# Global variables
export PGDATA="$INSTALL_DIR/data"
export PRIMARY_DATA=$INSTALL_DIR/primary_data
export REPLICA_DATA=$INSTALL_DIR/replica_data

export PGLOG="$PGDATA/server.log"
export PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
export REPLICA_LOGFILE=$REPLICA_DATA/server.log

export PORT=5432
export PRIMARY_PORT=5433
export REPLICA_PORT=5434

export ARCHIVE_DIR="$INSTALL_DIR/wal_archive"
export BACKUP_DIR="$INSTALL_DIR/base_backup"
