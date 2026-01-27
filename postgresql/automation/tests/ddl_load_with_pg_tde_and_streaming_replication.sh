#!/bin/bash

# Set variable
DB_NAME="sbtest"
TABLE_PREFIX="ddl_test"
TOTAL_TABLES=5

# pgbench Configuration
SCALE=50        # ~5 million rows
DURATION=300    # 5 minutes test
CLIENTS=16      # Moderate concurrent load
THREADS=4       # Suitable for 4+ core machines

# Create multiple tables
create_tables() {
  for t in $(seq 1 $TOTAL_TABLES); do
    TABLE_NAME="${TABLE_PREFIX}_${t}"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "
       CREATE TABLE IF NOT EXISTS $TABLE_NAME (
          id SERIAL PRIMARY KEY,
          data TEXT
       ) USING tde_heap;"
    echo "Created table: $TABLE_NAME"
    for r in $(seq 1 100); do
      $INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d $DB_NAME -c \
      "INSERT INTO $TABLE_NAME (data) VALUES ('Test record $r');"
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
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 3
    TABLE=$(random_table)
    NEW_COLUMN=$(generate_column_name)
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "
         ALTER TABLE $TABLE ADD COLUMN $NEW_COLUMN TEXT DEFAULT 'default_value';"
    echo "ADD COLUMN: $NEW_COLUMN in table: $TABLE"
  done
}

# Function to drop a random column
drop_column() {
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 3
    TABLE=$(random_table)
    COL_TO_DROP=$($INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -Atc "
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name='$TABLE' AND column_name LIKE 'col_%'
        ORDER BY random()
        LIMIT 1;")
    if [ -n "$COL_TO_DROP" ]; then
       $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "
           ALTER TABLE $TABLE DROP COLUMN $COL_TO_DROP;"
       echo " DROPPED COLUMN: $COL_TO_DROP from table: $TABLE"
    fi
  done
}

# Function to create a random index
create_index() {
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 5
    TABLE=$(random_table)
    INDEX_NAME="idx_$(date +%s)_$RANDOM"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "
        CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
        ON $TABLE ((length(data)));"
    echo " Created index: $INDEX_NAME on table: $TABLE"
  done
}

# Function to drop a random index
drop_index() {
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 5
    TABLE=$(random_table)
    INDEX_TO_DROP=$($INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -Atc "
        SELECT indexname
        FROM pg_indexes
        WHERE tablename='$TABLE' AND indexname LIKE 'idx_%'
        ORDER BY random()
        LIMIT 1;")

    if [ -n "$INDEX_TO_DROP" ]; then
      $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "DROP INDEX IF EXISTS $INDEX_TO_DROP;"
      echo "Dropped index: $INDEX_TO_DROP from table: $TABLE"
    fi
  done
}

# Function to run VACUUM FULL and CHECKPOINT
run_maintenance() {
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 5
    echo "Running VACUUM FULL and CHECKPOINT"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "VACUUM FULL;"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "CHECKPOINT;"
  done
}

crash_server() {
    local PID=$1
    echo "Killing the Server with PID=$PID..."
    kill -9 $PID
    sleep 5
}

alter_encrypt_unencrypt_tables(){
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 5
    RAND_TABLE=$(( ( RANDOM % $TOTAL_TABLES ) + 1 ))
    HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
    echo "Altering table ddl_test_$RAND_TABLE to use $HEAP_TYPE..."
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "ALTER TABLE ddl_test_$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;" || true
  done
}

rotate_master_key(){
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    sleep 5
    RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
    echo "Rotating master key: principal_key_test$RAND_KEY"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');"
  done
}

compress_wal(){
  local duration="$1"
  local end=$((SECONDS + duration))
  while [ $SECONDS -lt $end ]; do
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    echo "Compress WAL Encryption: $value"
    $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"ALTER SYSTEM SET wal_compression=$value;"
  done
}

# Actual test begins here...
# Cleanup from previous runs, any running server or residual datadirs
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA

echo "1=>Create Data Directory"
initialize_server $PRIMARY_DATA $PRIMARY_PORT

cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL

echo "2=> Enable pg_tde and WAL encryption"
enable_pg_tde $PRIMARY_DATA

echo "3=> Start Primary Server"
start_pg $PRIMARY_DATA $PRIMARY_PORT

$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "CREATE USER replica_user WITH REPLICATION;"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "SELECT pg_create_physical_replication_slot('standby1_slot');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "DROP DATABASE IF EXISTS $DB_NAME"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "CREATE DATABASE $DB_NAME"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "CREATE EXTENSION pg_tde"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_add_database_key_provider_file('local_keyring','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

restart_pg $PRIMARY_DATA $PRIMARY_PORT
PID_PRIMARY=$(lsof -ti :$PRIMARY_PORT)
echo "Primary Server started with PID:$PID_PRIMARY"

echo "Creating initial load with $TOTAL_TABLES tables and 100 records each..."
create_tables > /dev/null 2>&1

mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R $PRIMARY_DATA/pg_tde $REPLICA_DATA
$INSTALL_DIR/bin/pg_tde_basebackup -D $REPLICA_DATA -U replica_user -p $PRIMARY_PORT -X stream -E -R -P

write_postgresql_conf "$REPLICA_DATA" "$REPLICA_PORT" "replica"

echo "4=> Start Replica Server"
start_pg $REPLICA_DATA $REPLICA_PORT
PID_REPLICA=$(lsof -ti :$REPLICA_PORT)
echo "Replica Server started with PID: $PID_REPLICA"

for i in {1..5}; do
    echo "#####################################"
    echo "# TRIAL $i                          #"
    echo "#####################################"
    add_column 30 > /dev/null 2>&1 &
    drop_column 30 > /dev/null 2>&1 &
    create_index 30 > /dev/null 2>&1 &
    drop_index 30 > /dev/null 2>&1 &
    alter_encrypt_unencrypt_tables 30 > /dev/null 2>&1 &
    rotate_master_key 30 > /dev/null 2>&1 &
    compress_wal 30 > /dev/null 2>&1 &

    sleep 10
    crash_server $PID_PRIMARY
    sleep 3
    start_pg $PRIMARY_DATA $PRIMARY_PORT
    PID_PRIMARY=$(lsof -ti :$PRIMARY_PORT)

    wait
done

echo "Multi-table DDL stress test completed."
