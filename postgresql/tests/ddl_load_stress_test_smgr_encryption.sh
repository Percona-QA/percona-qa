#!/bin/bash

# Set variable
INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
DB_NAME="sbtest"
TABLE_PREFIX="ddl_test"
TOTAL_TABLES=20
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    $INSTALL_DIR/bin/createdb $DB_NAME
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_keyring');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_set_key_using_database_key_provider('table_key','local_keyring');"
    PG_PID=$(lsof -ti :5432)
}


# Create multiple tables
create_tables() {
    for i in $(seq 1 $TOTAL_TABLES); do
        TABLE_NAME="${TABLE_PREFIX}_${i}"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
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
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
            ALTER TABLE $TABLE ADD COLUMN $NEW_COLUMN TEXT DEFAULT 'default_value';"
        echo "ADD COLUMN: $NEW_COLUMN in table: $TABLE"
    done
}

# Function to drop a random column
drop_column() {
    while true; do
        sleep 3
        TABLE=$(random_table)
        COL_TO_DROP=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "
            SELECT column_name
            FROM information_schema.columns
            WHERE table_name='$TABLE' AND column_name LIKE 'col_%'
            ORDER BY random()
            LIMIT 1;")
    
        if [ -n "$COL_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
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
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
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
        INDEX_TO_DROP=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "
            SELECT indexname
            FROM pg_indexes
            WHERE tablename='$TABLE' AND indexname LIKE 'idx_%'
            ORDER BY random()
            LIMIT 1;")

        if [ -n "$INDEX_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "DROP INDEX IF EXISTS $INDEX_TO_DROP;"
            echo "Dropped index: $INDEX_TO_DROP from table: $TABLE"
        fi
    done
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 20 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql -d $DB_NAME -p 5432 -c "ALTER TABLE ddl_test_$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
        sleep 1
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating Global master key: wal_key$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5432 -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key$RAND_KEY','global_keyring','true');" || echo "SQL command failed, continuing..."
        sleep 1
    done
}

enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))
    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d $DB_NAME  -p 5432 -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

rotate_master_key(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql -d $DB_NAME  -p 5432 -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continue..."
        sleep 1
    done
}

# Function to run INSERT/UPDATE/DELETE load
run_load() {
    while true; do
        TABLE=$(random_table)
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
            INSERT INTO $TABLE (data) VALUES ('Insert ' || now());
            UPDATE $TABLE SET data = 'Updated ' || now() WHERE id % 5 = 0;
            DELETE FROM $TABLE WHERE random() < 0.01;"
        sleep 2
    done
}

# Function to run VACUUM FULL and CHECKPOINT
run_maintenance() {
    while true; do
        sleep 5
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_start() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    PG_PID=$(lsof -ti :5432)
}


crash_server() {
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

# Main load and DDL loop
initialize_server
start_server
create_tables         # Create initial tables
run_load &
LOAD_PID=$!
run_maintenance &
MAINT_PID=$!
add_column &
ADD_PID=$!
drop_column &
DROP_COLUMN_PID=$!
create_index &
CREATE_PID=$!
drop_index &
DROP_INDEX_PID=$!
rotate_master_key 120 >/dev/null 2>&1 &
ROTATE_MASTER_KEY=$!
enable_disable_wal_encryption 120 >/dev/null 2>&1 &
WAL_ENCRYPTION=$!
rotate_wal_key 120 >/dev/null 2>&1 &
WAL_KEY=$!
alter_encrypt_unencrypt_tables 120 >/dev/null 2>&1 &
ALTER_TABLES=$!


for i in {1..10}; do
    echo "########################################"
    echo "# TRIAL $i                             #"
    echo "########################################"
    sleep 20
    echo "Killing the Server"
    crash_server
    sleep 2
    echo "Starting the Server"
    crash_start
done

# Cleanup
kill $LOAD_PID $MAINT_PID $ADD_PID $DROP_COLUMN_PID $CREATE_PID $DROP_INDEX_PID $ROTATE_MASTER_KEY $WAL_ENCRYPTION $WAL_KEY $ALTER_TABLES
wait $LOAD_PID $MAINT_PID $ADD_PID $DROP_COLUMN_PID $CREATE_PID $DROP_INDEX_PID $ROTATE_MASTER_KEY $WAL_ENCRYPTION $WAL_KEY $ALTER_TABLES 2>/dev/null
echo "Multi-table DDL stress test completed."
