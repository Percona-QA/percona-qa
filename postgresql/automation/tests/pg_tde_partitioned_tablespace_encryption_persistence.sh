#!/bin/bash

##################################################################################
#                                                                                #
# This testcase validates encryption persistence for partitioned tables moved    #
# across tablespaces with pg_tde enabled.                                        #
#                                                                                #
# PG-1493 - Encrypted partition tables when moved to external tablespaces loses  #
# all the data                                                                   #
#                                                                                #
# Author: Mohit Joshi                                                            #
# Creation Date: 21-May-2026                                                     #
##################################################################################

# =========================================================
# Configuration
# =========================================================

DB_NAME="postgres"
TABLES=10
KEYRING_FILE="$RUN_DIR/keyring.file"
CUSTOM_TABLESPACE_DIR="$RUN_DIR/custom_tablespace"

# =========================================================
# Validation
# =========================================================

if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "ERROR: INSTALL_DIR is not set"
    exit 1
fi

if [[ -z "${RUN_DIR:-}" ]]; then
    echo "ERROR: RUN_DIR is not set"
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
    rm -rf "$CUSTOM_TABLESPACE_DIR" || true
    mkdir -p "$CUSTOM_TABLESPACE_DIR"

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
    # Tablespace Setup
    # =====================================================

    log "Creating external tablespace..."

    $PSQL -c "
        CREATE TABLESPACE custom_tablespace
        LOCATION '$CUSTOM_TABLESPACE_DIR';
    "

    # =====================================================
    # Create Partitioned Tables
    # =====================================================

    log "Creating $TABLES partitioned encrypted tables..."

    for i in $(seq 1 $TABLES); do

        log "Creating partitioned_table$i"

        $PSQL -c "
            CREATE TABLE IF NOT EXISTS partitioned_table$i (
                id SERIAL,
                data TEXT,
                created_at DATE NOT NULL,
                PRIMARY KEY (id, created_at)
            )
            PARTITION BY RANGE (created_at) USING tde_heap;
        "

        $PSQL -c "
            CREATE TABLE partition${i}_q1_2024
            PARTITION OF partitioned_table$i
            FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
        "

        $PSQL -c "
            CREATE TABLE partition${i}_q2_2024
            PARTITION OF partitioned_table$i
            FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
        "

        $PSQL -c "
            CREATE TABLE partition${i}_q3_2024
            PARTITION OF partitioned_table$i
            FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
        "

        $PSQL -c "
            CREATE TABLE partition${i}_q4_2024
            PARTITION OF partitioned_table$i
            FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');
        "
    done

    # =====================================================
    # Insert Test Data
    # =====================================================

    log "Inserting test data..."

    for i in $(seq 1 $TABLES); do

        for j in $(seq 1 5); do

            data="RandomData_${i}_${j}"
            date_offset=$(( RANDOM % 365 ))
            created_at=$(date -d "2024-01-01 +$date_offset days" "+%Y-%m-%d")

            log "Inserting row into partitioned_table$i"

            $PSQL -c "
                INSERT INTO partitioned_table$i (
                    data,
                    created_at
                )
                VALUES (
                    '$data',
                    '$created_at'
                );
            "
        done
    done

    # =====================================================
    # ALTER TABLESPACE Operations
    # =====================================================

    log "Moving partitioned tables across tablespaces..."

    for i in $(seq 1 $TABLES); do

        log "Moving partitioned_table$i to custom_tablespace"

        $PSQL -c "
            ALTER TABLE partitioned_table$i
            SET TABLESPACE custom_tablespace;
        "

        log "Moving partitioned_table$i back to pg_default"

        $PSQL -c "
            ALTER TABLE partitioned_table$i
            SET TABLESPACE pg_default;
        "

        log "Moving partitioned_table$i again to custom_tablespace"

        $PSQL -c "
            ALTER TABLE partitioned_table$i
            SET TABLESPACE custom_tablespace;
        "
    done

    # =====================================================
    # Query Validation
    # =====================================================

    log "Querying partitioned tables..."

    for i in $(seq 1 $TABLES); do

        $PSQL -c "
            SELECT count(*)
            FROM partitioned_table$i;
        " >/dev/null
    done

    # =====================================================
    # Restart Validation
    # =====================================================

    log "Restarting PostgreSQL..."

    stop_pg "$PGDATA"
    start_pg "$PGDATA" "$PORT"

    # =====================================================
    # Encryption Validation
    # =====================================================

    log "Verifying partition encryption status..."

    for i in $(seq 1 $TABLES); do
        for j in $(seq 1 4); do
            TABLE_NAME="partition${i}_q${j}_2024"
            ENCRYPTED_STATUS=$(
                $PSQL -t -A -c "
                    SELECT pg_tde_is_encrypted('$TABLE_NAME');
                "
            )

            if [[ "$ENCRYPTED_STATUS" != "t" ]]; then
                log "FAIL: $TABLE_NAME is not encrypted"
                exit 1
            fi
        done

        log "partitioned_table$i verified successfully"
    done

    log "Test completed successfully."
}

# =========================================================
# Execute
# =========================================================

main
