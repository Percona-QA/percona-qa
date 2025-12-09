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
export PGLOG="$PGDATA/server.log"
export PORT=5432
export ARCHIVE_DIR="$INSTALL_DIR/wal_archive"
export BACKUP_DIR="$INSTALL_DIR/base_backup"
