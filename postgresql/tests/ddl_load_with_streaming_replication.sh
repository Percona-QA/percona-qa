#!/bin/bash

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde/install
export PGDATA=$INSTALL_DIR/primary_data
export PGDATA2=$INSTALL_DIR/replica_data
export LOG_FILE=$PGDATA/server.log
export DB_NAME="sbtest"
export TABLE_PREFIX="ddl_test"
export TOTAL_TABLES=5
export MASTER_PORT=5432
export REPLICA_PORT=5433
export PATH=/usr/local/pgsql/bin:$PATH

# pgbench Configuration
SCALE=50        # ~5 million rows
DURATION=300    # 5 minutes test
CLIENTS=16      # Moderate concurrent load
THREADS=4       # Suitable for 4+ core machines

# Create multiple tables
setup_db() {
    $INSTALL_DIR/bin/psql  -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME"
    $INSTALL_DIR/bin/psql  -d postgres -c "CREATE DATABASE $DB_NAME"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c "CREATE EXTENSION pg_tde"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    for i in $(seq 1 $TOTAL_TABLES); do
       TABLE_NAME="${TABLE_PREFIX}_${i}"
       $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
          CREATE TABLE IF NOT EXISTS $TABLE_NAME (
             id SERIAL PRIMARY KEY,
             data TEXT
          ) USING tde_heap;"
       echo "Created table: $TABLE_NAME"
    for i in $(seq 1 100); do
    $INSTALL_DIR/bin/psql -p $MASTER_PORT -d $DB_NAME -c \
    "INSERT INTO $TABLE_NAME (data) VALUES ('Test record $i');"
    done
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
        sleep 5
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
    $INSTALL_DIR/bin/pg_ctl -D "$PGDATA" -l "$PGDATA/server.log" start
    exit_stats="$?"
    if [ $exit_status -ne 0 ]; then
        echo "Primary Server Failed to start. Check Logs: $PGDATA/server.log"
        grep "lock pg_tde_tranche is not held" $PGDATA/server.log
        grep "pg_tde/ADD_RELATION_KEY" $PGDATA/server.log
        exit 1
    else
        echo "Server started successfully"
        PG_PID1=$(lsof -ti :5432)
    fi
}


crash_server() {
    echo "Killing the Primary Server with PID=$PG_PID1..."
    kill -9 $PG_PID1
}

alter_encrypt_unencrypt_tables(){
    while true; do
        sleep 5
        RAND_TABLE=$(( ( RANDOM % $TOTAL_TABLES ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table ddl_test_$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "ALTER TABLE ddl_test_$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;" || true
    done
}

rotate_master_key(){
    while true; do
       sleep 5
       RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
       echo "Rotating master key: principal_key_test$RAND_KEY"
       $INSTALL_DIR/bin/psql -d $DB_NAME -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."
    done
}

compress_wal(){
    while true; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Compress WAL Encryption: $value"
        $INSTALL_DIR/bin/psql -d postgres -c"ALTER SYSTEM SET wal_compression=$value"
    done
}

# Main load and DDL loop
# Create initial tables
PG_PIDS=$(lsof -ti :5432 -ti :5433 2>/dev/null) || true
if [[ -n "$PG_PIDS" ]]; then
    echo "Killing PostgreSQL processes: $PG_PIDS"
    kill -9 $PG_PIDS
fi
rm -rf $PGDATA $PGDATA2
$INSTALL_DIR/bin/initdb -D $PGDATA
cat > "$PGDATA/postgresql.conf" <<SQL
port=5432
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$PGDATA'
log_filename = 'server.log'
log_statement = 'all'
SQL

cat >> "$PGDATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL

echo "Starting Primary Server..."
$INSTALL_DIR/bin/pg_ctl -D $PGDATA start
PG_PID1=$(lsof -ti :5432)
echo "Primary Server started PID:$PG_PID1"
$INSTALL_DIR/bin/psql -d postgres -c "CREATE USER replica_user WITH REPLICATION;"
$INSTALL_DIR/bin/psql -d postgres -c "SELECT pg_create_physical_replication_slot('standby1_slot');"

echo "Creating initial load with 5tables and 100 records each..."
setup_db > /dev/null 2>&1

$INSTALL_DIR/bin/pg_basebackup -D $PGDATA2 -U replica_user -p 5432 -Xs -R -P
cat >> "$PGDATA2/postgresql.conf" <<SQL
port=5433
logging_collector = on
log_directory = '$PGDATA2'
log_filename = 'server.log'
log_statement = 'all'
SQL

echo "Starting Replica Server..."
$INSTALL_DIR/bin/pg_ctl -D $PGDATA2 start
if [ $? -ne 0 ]; then
    echo "Replica Server Failed to start. Check logs: $PGDATA2/server.log" 
    grep "lock pg_tde_tranche is not held" $PGDATA2/server.log
    grep "pg_tde/ADD_RELATION_KEY" $PGDATA/server.log
    exit 1
else
    echo "Server started successfully"
    PG_PID2=$(lsof -ti :5433)
    echo "Replica Server started with PID: $PG_PID2"
fi

for i in {1..5}; do
    echo "#####################################"
    echo "# TRIAL $i                          #"
    echo "#####################################"
    add_column > /dev/null 2>&1 &
    ADD_PID=$!

    drop_column > /dev/null 2>&1 &
    DROP_PID=$!

    create_index > /dev/null 2>&1 &
    CREATE_PID=$!

    drop_index > /dev/null 2>&1 &
    INDEX_PID=$!

    alter_encrypt_unencrypt_tables > /dev/null 2>&1 &
    ALTER_PID=$!

    rotate_master_key > /dev/null 2>&1 &
    ROTATE_PID=$!

    compress_wal > /dev/null 2>&1 &
    COMP_PID=$!

    sleep 20
    crash_server
    crash_start

    kill $ADD_PID $DROP_PID $CREATE_PID $INDEX_PID $ALTER_PID $ROTATE_PID $COMP_PID > /dev/null
    wait $ADD_PID $DROP_PID $CREATE_PID $INDEX_PID $ALTER_PID $ROTATE_PID $COMP_PID > /dev/null
done

echo "Multi-table DDL stress test completed."

# Cleanup

