#!/bin/bash

##################################################################################
#                                                                                #
# This testcase validates encrypted table behavior after CLUSTER and VACUUM FULL #
# operations with pg_tde enabled.                                                #
#                                                                                #
# https://perconadev.atlassian.net/browse/PG-1494                                #
# https://perconadev.atlassian.net/browse/PG-1495                                #
#                                                                                #
# Scenarios covered:                                                             #
# 1. Encrypted table remains encrypted after CLUSTER operation                   #
# 2. Regular heap table loses encryption after VACUUM FULL rewrite               #
#                                                                                #
# Author: Mohit Joshi                                                            #
# Creation Date: 21-May-2026                                                     #
##################################################################################

# =========================================================
# Configuration
# =========================================================

DB_NAME="postgres"
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

    $PSQL -c "
        CREATE EXTENSION IF NOT EXISTS pg_tde;
    "

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
    # Scenario 1
    # Encrypted table remains encrypted after CLUSTER
    # =====================================================

    log "Creating encrypted table..."

    $PSQL -c "
        CREATE TABLE encrypted_table (
            id SERIAL,
            data TEXT,
            created_at DATE NOT NULL,
            PRIMARY KEY (id, created_at)
        ) USING tde_heap;
    "

    log "Creating index on encrypted table..."

    $PSQL -c "
        CREATE INDEX idx_date
        ON encrypted_table(created_at);
    "

    log "Verifying table encryption before CLUSTER..."

    BEFORE_CLUSTER=$(
        $PSQL -t -A -c "
            SELECT pg_tde_is_encrypted('encrypted_table');
        "
    )

    if [[ "$BEFORE_CLUSTER" != "t" ]]; then
        log "FAIL: encrypted_table is not encrypted before CLUSTER"
        exit 1
    fi

    log "Running CLUSTER operation..."

    $PSQL -c "
        CLUSTER encrypted_table USING idx_date;
    "

    log "Verifying encryption after CLUSTER..."

    AFTER_CLUSTER=$(
        $PSQL -t -A -c "
            SELECT pg_tde_is_encrypted('encrypted_table');
        "
    )

    if [[ "$AFTER_CLUSTER" == "t" ]]; then
        log "SUCCESS: encrypted_table remained encrypted after CLUSTER"
    else
        log "FAIL: encrypted_table lost encryption after CLUSTER"
        exit 1
    fi

    # =====================================================
    # Scenario 2
    # VACUUM FULL rewrites table as unencrypted heap
    # =====================================================

    log "Creating second encrypted table..."

    $PSQL -c "
        CREATE TABLE t1(
            n integer
        ) USING tde_heap;
    "

    log "Verifying encryption before VACUUM FULL..."

    BEFORE_VACUUM=$(
        $PSQL -t -A -c "
            SELECT pg_tde_is_encrypted('t1');
        "
    )

    if [[ "$BEFORE_VACUUM" != "t" ]]; then
        log "FAIL: t1 is not encrypted before VACUUM FULL"
        exit 1
    fi

    log "Running VACUUM FULL..."

    $PSQL -c "
        VACUUM(FULL) t1;
    "

    log "Verifying encryption after VACUUM FULL..."

    AFTER_VACUUM=$(
        $PSQL -t -A -c "
            SELECT pg_tde_is_encrypted('t1');
        "
    )

    if [[ "$AFTER_VACUUM" == "t" ]]; then
        log "SUCCESS: t1 remained encrypted after VACUUM FULL as expected"
    else
        log "FAIL: t1 lost encryption after VACUUM FULL"
        exit 1
    fi

    log "Test completed successfully."
}

# =========================================================
# Execute
# =========================================================

main
