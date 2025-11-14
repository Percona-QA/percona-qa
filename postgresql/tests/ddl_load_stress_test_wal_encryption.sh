#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
DB_NAME="sbtest"
TABLE_PREFIX="ddl_test"
TOTAL_TABLES=20

source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
rm -rf $PGDATA/keyring.file

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    $INSTALL_DIR/bin/createdb $DB_NAME
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_add_global_key_provider_file('global_provider','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_create_key_using_global_key_provider('table_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_set_key_using_global_key_provider('table_key','global_provider');"
    PG_PID=$(lsof -ti :5432)
}


# Create multiple tables
create_tables() {
    for i in $(seq 1 $TOTAL_TABLES); do
        TABLE_NAME="${TABLE_PREFIX}_${i}"
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "
            CREATE TABLE IF NOT EXISTS $TABLE_NAME (
                id SERIAL PRIMARY KEY,
                data TEXT
            ) USING tde_heap;"
        echo "Created table: $TABLE_NAME"
    done
}

# Function to pick a random table
random_table() {
    echo "${TABLE_PREFIX}_$((RANDOM % TOTAL_TABLES + 1))"
}

# Function to generate random column names
generate_column_name() {
    echo "col_$(date +%s)_$RANDOM"
}

# Function to add a random column
add_column() {
    while true; do
        sleep 3
        TABLE=$(random_table)
        NEW_COLUMN=$(generate_column_name)
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "
            ALTER TABLE $TABLE ADD COLUMN $NEW_COLUMN TEXT DEFAULT 'default_value';"
        echo "ADD COLUMN: $NEW_COLUMN in table: $TABLE"
    done
}

# Function to drop a random column
drop_column() {
    while true; do
        sleep 3
        TABLE=$(random_table)
        COL_TO_DROP=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "
            SELECT column_name
            FROM information_schema.columns
            WHERE table_name='$TABLE' AND column_name LIKE 'col_%'
            ORDER BY random()
            LIMIT 1;")
    
        if [ -n "$COL_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql -d $DB_NAME -c "
                ALTER TABLE $TABLE DROP COLUMN $COL_TO_DROP;"
            echo " DROPPED COLUMN: $COL_TO_DROP from table: $TABLE"
        fi
    done
}

# Function to create a random index
create_index() {
    while true; do
        sleep 5
        TABLE=$(random_table)
        INDEX_NAME="idx_$(date +%s)_$RANDOM"
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "
            CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
            ON $TABLE ((length(data)));"
        echo " Created index: $INDEX_NAME on table: $TABLE"
    done
}

# Function to drop a random index
drop_index() {
    while true; do
        sleep 10
        TABLE=$(random_table)
        INDEX_TO_DROP=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "
            SELECT indexname
            FROM pg_indexes
            WHERE tablename='$TABLE' AND indexname LIKE 'idx_%'
            ORDER BY random()
            LIMIT 1;")

        if [ -n "$INDEX_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql -d $DB_NAME -c "DROP INDEX IF EXISTS $INDEX_TO_DROP;"
            echo "Dropped index: $INDEX_TO_DROP from table: $TABLE"
        fi
    done
}

# Function to run INSERT/UPDATE/DELETE load
run_load() {
    while true; do
        TABLE=$(random_table)
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "
            INSERT INTO $TABLE (data) VALUES ('Insert ' || now());
            UPDATE $TABLE SET data = 'Updated ' || now() WHERE id % 5 = 0;
            DELETE FROM $TABLE WHERE random() < 0.01;
        "
        sleep 2
    done
}

# Function to run VACUUM FULL and CHECKPOINT
run_maintenance() {
    while true; do
        sleep 15
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_start() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    PG_PID=$(lsof -ti :5432)
}


crash_server() {
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    echo "Altering WAL encryption to use $value..."
    $INSTALL_DIR/bin/psql -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

# Main load and DDL loop
initialize_server
start_server
create_tables         # Create initial tables

for i in {1..5}; do
    run_load &
    LOAD_PID=$!
    run_maintenance &
    MAINT_PID=$!
    add_column &
    ADD_PID=$!
    drop_column &
    DROP_PID=$!
    create_index &
    CREATE_PID=$!
    drop_index &
    DROP_INDEX_PID=$!
    sleep 30
    crash_server
    kill $LOAD_PID $MAINT_PID $ADD_PID $DROP_PID $CREATE_PID $DROP_INDEX_PID
    sleep 2
    crash_start
done

# Cleanup
kill $LOAD_PID $MAINT_PID $ADD_PID $DROP_PID $CREATE_PID $DROP_INDEX_PID
wait $LOAD_PID $MAINT_PID $ADD_PID $DROP_PID $CREATE_PID $DROP_INDEX_PID 2>/dev/null
echo "Multi-table DDL stress test completed."
