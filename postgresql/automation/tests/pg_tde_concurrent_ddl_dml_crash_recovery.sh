#!/bin/bash

set -u

# =========================================================
# Configuration
# =========================================================

KEYRING="/tmp/keyring.file"

DB_NAME="sbtest"
TABLE_PREFIX="ddl_test"
TOTAL_TABLES=20

TRIALS=5
TRIAL_DURATION=30

# =========================================================
# Validation
# =========================================================

if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "ERROR: INSTALL_DIR is not set"
    exit 1
fi

if [[ -z "${PGDATA:-}" ]]; then
    echo "ERROR: PGDATA is not set"
    exit 1
fi

if [[ -z "${PORT:-}" ]]; then
    echo "ERROR: PORT is not set"
    exit 1
fi

PSQL="$INSTALL_DIR/bin/psql -X -v ON_ERROR_STOP=1 -p $PORT -d $DB_NAME"
PSQL_POSTGRES="$INSTALL_DIR/bin/psql -X -v ON_ERROR_STOP=1 -p $PORT -d postgres"

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

random_table() {
    echo "${TABLE_PREFIX}_$((RANDOM % TOTAL_TABLES + 1))"
}

generate_column_name() {
    echo "col_$(date +%s)_$RANDOM"
}

# =========================================================
# Table Creation
# =========================================================

create_tables() {
    log "Creating initial tables..."

    for i in $(seq 1 $TOTAL_TABLES); do
        TABLE_NAME="${TABLE_PREFIX}_${i}"

        run_sql "
            CREATE TABLE IF NOT EXISTS $TABLE_NAME (
                id SERIAL PRIMARY KEY,
                data TEXT
            ) USING tde_heap;
        "

        log "Created table: $TABLE_NAME"
    done
}

# =========================================================
# DDL Functions
# =========================================================

add_column() {
    while true; do
        sleep 3

        TABLE=$(random_table)
        NEW_COLUMN=$(generate_column_name)

        run_sql "
            ALTER TABLE $TABLE
            ADD COLUMN IF NOT EXISTS $NEW_COLUMN TEXT DEFAULT 'default_value';
        "

        log "ADD COLUMN: $NEW_COLUMN in table: $TABLE"
    done
}

drop_column() {
    while true; do
        sleep 3

        TABLE=$(random_table)

        COL_TO_DROP=$(
            $PSQL -Atc "
                SELECT column_name
                FROM information_schema.columns
                WHERE table_name='$TABLE'
                  AND column_name LIKE 'col_%'
                ORDER BY random()
                LIMIT 1;
            " 2>/dev/null
        )

        if [[ -n "${COL_TO_DROP:-}" ]]; then

            run_sql "
                ALTER TABLE $TABLE
                DROP COLUMN IF EXISTS $COL_TO_DROP;
            "

            log "DROPPED COLUMN: $COL_TO_DROP from table: $TABLE"
        fi
    done
}

create_index() {
    while true; do
        sleep 5

        TABLE=$(random_table)
        INDEX_NAME="idx_$(date +%s)_$RANDOM"

        $PSQL -c "
            CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
            ON $TABLE ((length(data)));
        " >/dev/null 2>&1 || true

        log "Created index: $INDEX_NAME on table: $TABLE"
    done
}

drop_index() {
    while true; do
        sleep 10

        TABLE=$(random_table)

        INDEX_TO_DROP=$(
            $PSQL -Atc "
                SELECT indexname
                FROM pg_indexes
                WHERE tablename='$TABLE'
                  AND indexname LIKE 'idx_%'
                ORDER BY random()
                LIMIT 1;
            " 2>/dev/null
        )

        if [[ -n "${INDEX_TO_DROP:-}" ]]; then

            $PSQL -c "
                DROP INDEX CONCURRENTLY IF EXISTS $INDEX_TO_DROP;
            " >/dev/null 2>&1 || true

            log "Dropped index: $INDEX_TO_DROP"
        fi
    done
}

alter_encrypt_unencrypt_tables() {
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [[ $SECONDS -lt $end_time ]]; do

        RAND_TABLE=$(( ( RANDOM % TOTAL_TABLES ) + 1 ))

        HEAP_TYPE=$(
            [[ $(( RANDOM % 2 )) -eq 0 ]] && echo "heap" || echo "tde_heap"
        )

        log "Altering ddl_test_$RAND_TABLE to use $HEAP_TYPE"

        run_sql "
            ALTER TABLE ddl_test_$RAND_TABLE
            SET ACCESS METHOD $HEAP_TYPE;
        "

        sleep 2
    done
}

# =========================================================
# Key Rotation Functions
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

rotate_master_key() {
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [[ $SECONDS -lt $end_time ]]; do

        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))

        log "Rotating master key: principal_key_test$RAND_KEY"

        run_sql "
            SELECT pg_tde_create_key_using_database_key_provider(
                'principal_key_test$RAND_KEY',
                'local_keyring'
            );
        "

        run_sql "
            SELECT pg_tde_set_key_using_database_key_provider(
                'principal_key_test$RAND_KEY',
                'local_keyring'
            );
        "

        sleep 2
    done
}

# =========================================================
# Load Functions
# =========================================================

run_load() {
    while true; do

        TABLE=$(random_table)

        run_sql "
            INSERT INTO $TABLE (data)
            VALUES ('Insert ' || now());

            UPDATE $TABLE
            SET data = 'Updated ' || now()
            WHERE id % 5 = 0;

            DELETE FROM $TABLE
            WHERE random() < 0.01;
        "

        sleep 2
    done
}

run_maintenance() {
    while true; do
        sleep 15

        log "Running VACUUM + CHECKPOINT"

        run_sql "VACUUM;"
        run_sql "CHECKPOINT;"
    done
}

# =========================================================
# Background Job Handling
# =========================================================

PIDS=()

start_background_jobs() {

    run_load &
    PIDS+=($!)

    run_maintenance &
    PIDS+=($!)

    add_column &
    PIDS+=($!)

    drop_column &
    PIDS+=($!)

    create_index &
    PIDS+=($!)

    drop_index &
    PIDS+=($!)

    rotate_master_key $TRIAL_DURATION &
    PIDS+=($!)

    rotate_wal_key $TRIAL_DURATION &
    PIDS+=($!)

    alter_encrypt_unencrypt_tables $TRIAL_DURATION &
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
# Initial Cleanup
# =========================================================

log "Cleaning previous environment..."

old_server_cleanup "$PGDATA" "$PORT"

rm -f "$KEYRING" || true

# =========================================================
# Server Initialization
# =========================================================

log "Initializing server..."

initialize_server "$PGDATA" "$PORT"

enable_pg_tde "$PGDATA"

start_pg "$PGDATA" "$PORT"

log "Creating database..."

"$INSTALL_DIR/bin/createdb" -p "$PORT" "$DB_NAME"

# =========================================================
# pg_tde Setup
# =========================================================

log "Configuring pg_tde..."

$PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"

$PSQL -c "
    SELECT pg_tde_add_global_key_provider_file(
        'global_keyring',
        '$KEYRING'
    );
"

$PSQL -c "
    SELECT pg_tde_add_database_key_provider_file(
        'local_keyring',
        '$KEYRING'
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
        'table_key',
        'local_keyring'
    );
"

$PSQL -c "
    SELECT pg_tde_set_key_using_database_key_provider(
        'table_key',
        'local_keyring'
    );
"

# =========================================================
# Create Initial Tables
# =========================================================

create_tables

# =========================================================
# Main Stress Loop
# =========================================================

for i in $(seq 1 $TRIALS); do

    log "=================================================="
    log "TRIAL $i"
    log "=================================================="

    start_background_jobs

    sleep "$TRIAL_DURATION"

    log "Stopping jobs before crash..."
    stop_background_jobs

    log "Crashing PostgreSQL..."
    crash_pg "$PGDATA" "$PORT"     # already waits for all procs to exit

    log "Restarting PostgreSQL..."
    start_pg "$PGDATA" "$PORT"     # already waits for pg_isready

done

# =========================================================
# Final Cleanup
# =========================================================

stop_background_jobs

log "Multi-table pg_tde DDL stress test completed successfully."
