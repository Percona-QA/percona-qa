#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde_17.4/install
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
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT pg_tde_add_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT pg_tde_set_principal_key('principal_key_sbtest','local_keyring');"
    for i in $(seq 1 $TOTAL_TABLES); do
       TABLE_NAME="${TABLE_PREFIX}_${i}"
       $INSTALL_DIR/bin/psql  -d $DB_NAME -c "
          CREATE TABLE IF NOT EXISTS $TABLE_NAME (
             id SERIAL PRIMARY KEY,
             data TEXT
          ) USING tde_heap;"
       echo "Created table: $TABLE_NAME"
    for i in $(seq 1 500); do
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

# Function to run INSERT/UPDATE/DELETE load
init_pgbench() {
     # Initialize pgbench on Master
    echo "Initializing pgbench with scale factor $SCALE on database: $DB_NAME and (port: $MASTER_PORT)..."
    pgbench -i -s $SCALE -d $DB_NAME -p $MASTER_PORT 
    if [ $? -eq 0 ]; then
       echo "✅ Pgbench Initialization done..."
    else
       echo "❌ Pgbench Initialization failed..."
    fi
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"ALTER TABLE pgbench_accounts SET ACCESS METHOD tde_heap"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"ALTER TABLE pgbench_branches SET ACCESS METHOD tde_heap"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"ALTER TABLE pgbench_history SET ACCESS METHOD tde_heap"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"ALTER TABLE pgbench_tellers SET ACCESS METHOD tde_heap"
}

run_pgbench() {
    while true; do
    # Run pgbench Transactions
    local duration="${1:-$DURATION}"
    local clients="${2:-$CLIENTS}"
    local threads="${3:-$THREADS}"
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    echo "Running pgbench with $clients clients and $threads threads for $duration seconds..."
    pgbench -T $duration -c $clients -j $threads -M prepared -d $DB_NAME -p $MASTER_PORT > /dev/null 2>&1
    if [ $? -eq 0 ]; then
       echo "✅ Pgbench Run Completed..."
    else
       echo "❌ Pgbench Run failed..."
    fi
done
}

# Function to run VACUUM FULL and CHECKPOINT
run_maintenance() {
    while true; do
        sleep 15
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_start() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start
    PG_PID=$(lsof -ti :5432)
}


crash_server() {
    PG_PID=$(lsof -ti :5432)
    #value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    #echo "Altering WAL encryption to use $value..."
    #$INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
    echo "Waiting for the server to be completely gone...."
    kill $INDEX_PID $ADD_PID $DROP_PID $CREATE_PID $ALTER_PID $ROTATE_PID $COMP_PID
    sleep 5
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
       $INSTALL_DIR/bin/psql -d $DB_NAME -c "SELECT pg_tde_set_principal_key('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."
    done
}

compress_wal(){
    while true; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Compress WAL Encryption: $value"
        $INSTALL_DIR/bin/psql -d postgres -c"ALTER SYSTEM SET wal_encryption=$value"
    done
}

# Main load and DDL loop
# Create initial tables
PG_PIDS=$(lsof -ti :5432 -ti :5433 -ti :5434 2>/dev/null) || true
if [[ -n "$PG_PIDS" ]]; then
    echo "Killing PostgreSQL processes: $PG_PIDS"
    kill -9 $PG_PIDS
fi
sleep 5
rm -rf $PGDATA $PGDATA2
sleep 5
$INSTALL_DIR/bin/initdb -D $PGDATA
cp $INSTALL_DIR/postgresql.conf $PGDATA/postgresql.conf
cp $INSTALL_DIR/pg_hba.conf $PGDATA
sleep 10
$INSTALL_DIR/bin/pg_ctl -D $PGDATA start
$INSTALL_DIR/bin/psql -d postgres -c "CREATE USER replica_user WITH REPLICATION;"
$INSTALL_DIR/bin/psql -d postgres -c "SELECT pg_create_physical_replication_slot('standby1_slot');"


setup_db

$INSTALL_DIR/bin/pg_basebackup -D $PGDATA2 -U replica_user -p 5432 -Xs -R -P
cp $INSTALL_DIR/postgresql.conf_rpl_bk $INSTALL_DIR/replica_data/postgresql.conf

$INSTALL_DIR/bin/pg_ctl -D $PGDATA2 start

sleep 5


#setup_db
#init_pgbench

for i in {1..5}; do
    #run_pgbench &
    #LOAD_PID=$!

    add_column &
    ADD_PID=$!

    drop_column &
    DROP_PID=$!

    create_index &
    CREATE_PID=$!

    drop_index &
    INDEX_PID=$!

    alter_encrypt_unencrypt_tables &
    ALTER_PID=$!

    rotate_master_key &
    ROTATE_PID=$!

    compress_wal &
    COMP_PID=$!

    sleep 30
    crash_server
    crash_start
done

echo "Multi-table DDL stress test completed."

# Cleanup
kill $INDEX_PID $ADD_PID $DROP_PID $CREATE_PID $ALTER_PID $ROTATE_PID $COMP_PID
sleep 2
wait $INDEX_PID $ADD_PID $DROP_PID $CREATE_PID $ALTER_PID $ROTATE_PID $COMP_PID 2>/dev/null

