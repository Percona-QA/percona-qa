#!/bin/bash

##################################################################################
#                                                                                #
# This testcase validates the following bug fix:                                 #
# PG-1503 - Deleting a Global key provider must not be allowed when active keys  #
#           are still associated with the database                               #
#                                                                                #
# Author: Mohit Joshi                                                            #
# Creation date: 21-May-2026                                                     #
#                                                                                #
##################################################################################

set -u

# =========================================================
# Configuration
# =========================================================

DB_NAME="postgres"

PGDATA="$INSTALL_DIR/data"
PORT=5432

KEYRING_FILE="$PGDATA/keyring.file"

# =========================================================
# Validation
# =========================================================

if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "ERROR: INSTALL_DIR is not set"
    exit 1
fi

PSQL="$INSTALL_DIR/bin/psql -X -v ON_ERROR_STOP=1 -p $PORT -d $DB_NAME"

# =========================================================
# Utility Functions
# =========================================================

log() {
    echo "[$(date '+%F %T')] $*"
}

# =========================================================
# Main Test
# =========================================================

main() {

    log "Cleaning previous environment..."

    old_server_cleanup "$PGDATA" "$PORT"

    rm -f "$KEYRING_FILE" || true

    log "Initializing PostgreSQL cluster..."

    initialize_server "$PGDATA" "$PORT"

    enable_pg_tde "$PGDATA"

    log "Starting PostgreSQL..."

    start_pg "$PGDATA" "$PORT"

    # =====================================================
    # pg_tde Setup
    # =====================================================

    log "Creating pg_tde extension..."

    $PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"

    log "Creating global key provider..."

    $PSQL -c "
        SELECT pg_tde_add_global_key_provider_file(
            'global_keyring',
            '$KEYRING_FILE'
        );
    "

    log "Creating principal key using global key provider..."

    $PSQL -c "
        SELECT pg_tde_create_key_using_global_key_provider(
            'local_key_of_db1_using_global_key_provider',
            'global_keyring'
        );
    "

    $PSQL -c "
        SELECT pg_tde_set_key_using_global_key_provider(
            'local_key_of_db1_using_global_key_provider',
            'global_keyring'
        );
    "

    # =====================================================
    # Encrypted Table Operations
    # =====================================================

    log "Creating encrypted table..."

    $PSQL -c "
        CREATE TABLE t1(a INT) USING tde_heap;
    "

    log "Inserting data into encrypted table..."

    $PSQL -c "
        INSERT INTO t1 VALUES(1);
    "

    # =====================================================
    # Validation
    # =====================================================

    log "Attempting to delete active global key provider..."

    set +e

    $PSQL -c "
        SELECT pg_tde_delete_global_key_provider(
            'global_keyring'
        );
    "

    ret_code=$?

    set -e

    if [[ $ret_code -ne 0 ]]; then
        log "SUCCESS: Global key provider deletion was correctly blocked."
    else
        log "FAIL: Global key provider deletion unexpectedly succeeded."
        exit 1
    fi

    log "Test completed successfully."
}

# =========================================================
# Execute
# =========================================================

main
