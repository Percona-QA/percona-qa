#!/bin/bash

##################################################################################
#                                                                                #
# This testcase is written for the following bug                                 #
# PG-1541 - FATAL: Failed to verify principal key header for Rotated WAL Key     #
#                                                                                #
# Author: Mohit Joshi                                                            #
# Creation date: 21-May-2026                                                     #
#                                                                                #
# ################################################################################

# =========================================================
# Configuration
# =========================================================

DB_NAME="sbtest"

GLOBAL_KEYRING="$PGDATA/keyring_global.file"
LOCAL_KEYRING="$PGDATA/keyring_local.file"

TRIALS=5
TRIAL_DURATION=20

SYSBENCH_THREADS=10
SYSBENCH_TABLES=10
SYSBENCH_TABLE_SIZE=1000

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

run_sql() {
    local sql="$1"

    $PSQL -c "$sql" >/dev/null 2>&1 || true
}

# =========================================================
# pg_tde Configuration
# =========================================================

configure_pg_tde() {

    log "Creating database..."

    "$INSTALL_DIR/bin/createdb" -p "$PORT" "$DB_NAME"

    log "Configuring pg_tde..."

    $PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"

    $PSQL -c "
        SELECT pg_tde_add_global_key_provider_file(
            'global_keyring',
            '$GLOBAL_KEYRING'
        );
    "

    $PSQL -c "
        SELECT pg_tde_add_database_key_provider_file(
            'local_keyring',
            '$LOCAL_KEYRING'
        );
    "

    $PSQL -c "
        SELECT pg_tde_create_key_using_global_key_provider(
            'wal_key',
            'global_keyring'
        );
    "

    $PSQL -c "
        SELECT pg_tde_set_server_key_using_global_key_provider(
            'wal_key',
            'global_keyring'
        );
    "

    $PSQL -c "
        SELECT pg_tde_create_key_using_database_key_provider(
            'principal_key_sbtest',
            'local_keyring'
        );
    "

    $PSQL -c "
        SELECT pg_tde_set_key_using_database_key_provider(
            'principal_key_sbtest',
            'local_keyring'
        );
    "
}

# =========================================================
# Sysbench Functions
# =========================================================

prepare_sysbench_data() {

    log "Preparing sysbench dataset..."

    sysbench /usr/share/sysbench/oltp_insert.lua \
        --pgsql-db="$DB_NAME" \
        --pgsql-user="$(whoami)" \
        --pgsql-port="$PORT" \
        --db-driver=pgsql \
        --threads="$SYSBENCH_THREADS" \
        --tables="$SYSBENCH_TABLES" \
        --table-size="$SYSBENCH_TABLE_SIZE" \
        prepare
}

run_sysbench_load() {

    sysbench /usr/share/sysbench/oltp_read_write.lua \
        --pgsql-db="$DB_NAME" \
        --pgsql-user="$(whoami)" \
        --pgsql-port="$PORT" \
        --db-driver=pgsql \
        --threads="$SYSBENCH_THREADS" \
        --tables="$SYSBENCH_TABLES" \
        --time="$TRIAL_DURATION" \
        --report-interval=5 \
        run
}

# =========================================================
# WAL Key Rotation
# =========================================================

rotate_wal_key() {

    local duration=$1
    local end_time=$((SECONDS + duration))

    while [[ $SECONDS -lt $end_time ]]; do

        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))

        log "Rotating WAL key: wal_key$RAND_KEY"

        run_sql "
            SELECT pg_tde_create_key_using_global_key_provider(
                'wal_key$RAND_KEY',
                'global_keyring'
            );
        "

        run_sql "
            SELECT pg_tde_set_server_key_using_global_key_provider(
                'wal_key$RAND_KEY',
                'global_keyring'
            );
        "

        sleep 2
    done
}

# =========================================================
# Background Job Handling
# =========================================================

PIDS=()

start_background_jobs() {

    rotate_wal_key "$TRIAL_DURATION" &
    PIDS+=($!)
}

stop_background_jobs() {

    log "Stopping background jobs..."

    for pid in "${PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done

    for pid in "${PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done

    PIDS=()
}

# =========================================================
# Main Test
# =========================================================

main() {

    log "Cleaning previous environment..."

    old_server_cleanup "$PGDATA" "$PORT"

    rm -rf "$GLOBAL_KEYRING" "$LOCAL_KEYRING"

    log "Initializing PostgreSQL cluster..."

    initialize_server "$PGDATA" "$PORT"

    enable_pg_tde "$PGDATA"

    start_pg "$PGDATA" "$PORT"

    configure_pg_tde

    prepare_sysbench_data

    for trial in $(seq 1 $TRIALS); do

        log "=================================================="
        log "TRIAL $trial"
        log "=================================================="

        start_background_jobs

        run_sysbench_load >/dev/null 2>&1 &
        SYSBENCH_PID=$!

        sleep 20

        log "Crashing PostgreSQL..."

        crash_pg "$PGDATA" "$PORT"

        stop_background_jobs

        wait "$SYSBENCH_PID" 2>/dev/null || true

        sleep 2

        log "Restarting PostgreSQL..."

        start_pg "$PGDATA" "$PORT"

        sleep 5
    done

    stop_background_jobs

    log "pg_tde WAL key rotation crash stress test completed successfully."
}

# =========================================================
# Execute
# =========================================================

main
