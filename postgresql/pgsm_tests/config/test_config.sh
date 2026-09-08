#!/bin/bash

###############################################################################
# PGSM Test Framework Configuration
###############################################################################

###############################################################################
# Runtime
###############################################################################

# All PostgreSQL runtime files are created here.
PGSM_RUNTIME_DIR="/tmp/pgsm_tests"

# PostgreSQL data directory.
PGSM_PGDATA="${PGSM_RUNTIME_DIR}/data"

# PostgreSQL Unix socket directory.
PGSM_SOCKET_DIR="${PGSM_RUNTIME_DIR}/socket"

# PostgreSQL server log.
PGSM_PGLOG="${PGSM_RUNTIME_DIR}/postgresql.log"

###############################################################################
# PostgreSQL connection
###############################################################################

# Dedicated port for the PGSM test PostgreSQL instance.
#
# run_tests.sh uses flock to ensure that only one test run is active,
# therefore a fixed port is safe.
PGSM_PGPORT="55432"

# Host used for TCP connections.
PGSM_PGHOST="127.0.0.1"

# Database used by the framework by default.
PGSM_TEST_DB="postgres"

# User used to execute tests.
PGSM_TEST_USER="${USER}"

###############################################################################
# PostgreSQL binaries
###############################################################################

# Leave empty to use binaries available in PATH.
#
# Set PGSM_PG_BIN_DIR if testing a specific PostgreSQL installation.
#
# Example:
# PGSM_PG_BIN_DIR="/usr/lib/postgresql/17/bin"

PGSM_PG_BIN_DIR="$HOME/postgresql/bld_18.6.1/install/bin"

###############################################################################
# PostgreSQL initialization
###############################################################################

# Encoding used when initializing the test cluster.
PGSM_INITDB_ENCODING="UTF8"

# Locale used by initdb.
#
# Empty means use --no-locale.
PGSM_INITDB_LOCALE=""

###############################################################################
# PostgreSQL configuration
###############################################################################

# Libraries required by the PGSM test environment.
#
# pg_stat_monitor requires shared_preload_libraries.
#
# Keep pg_stat_statements here because PGSM is commonly tested together
# with pg_stat_statements and its preload ordering.
PGSM_SHARED_PRELOAD_LIBRARIES="pg_stat_statements,pg_stat_monitor"

# Listen only on localhost.
PGSM_LISTEN_ADDRESSES="127.0.0.1"

# PostgreSQL logging.
PGSM_LOG_MIN_MESSAGES="warning"

###############################################################################
# Test database
###############################################################################

# Additional databases can be created by individual tests using
# postgres_create_database().
#
# The default database used by execute_sql() is PGSM_TEST_DB.
###############################################################################
