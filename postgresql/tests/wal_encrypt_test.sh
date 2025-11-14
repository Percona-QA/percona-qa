#!/bin/bash

INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
DB_NAME=postgres

source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/start_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/enable_tde.sh"

# Create data directory
initialize_server

# Start PG server and enable TDE
start_server
enable_tde

echo "Enabling WAL encryption..."
$INSTALL_DIR/bin/psql -d $DB_NAME -c"ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
$INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE restart
PG_PID=$(lsof -ti :5432)
echo "WAL encryption enabled."

# Fetch all WAL-related vars (excluding unset ones)
mapfile -t wal_vars < <($INSTALL_DIR/bin/psql -d "$DB_NAME" -Atc \
  "SELECT name FROM pg_settings WHERE name LIKE '%wal%' AND setting IS NOT NULL AND name != 'pg_tde.wal_encrypt'")

# Pick a random variable
RANDOM_VAR=${wal_vars[$RANDOM % ${#wal_vars[@]}]}
echo "Randomly selected WAL variable: $RANDOM_VAR"

# Decide a new test value (override below as needed)
declare -A test_values=(
  [wal_compression]="on"
  [wal_log_hints]="on"
  [wal_writer_delay]="1000"
  [wal_writer_flush_after]="256"
  [wal_level]="logical"
  [wal_buffers]="1024"
  [max_wal_size]="2048"
  [min_wal_size]="128"
  [wal_init_zero]="off"
  [wal_sync_method]="fsync"
  [wal_retrieve_retry_interval]="5000"
  [wal_segment_size]="16777216"
  [wal_sender_timeout]="60000"
  [wal_recycle]="off"
  [wal_receiver_create_temp_slot]="on"
  [wal_keep_size]=5
  [track_wal_io_timing]="on"
  [summarize_wal]="on"

)

TEST_VALUE="${test_values[$RANDOM_VAR]:-42}"  # Fallback value

echo "Setting $RANDOM_VAR to $TEST_VALUE..."

$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "ALTER SYSTEM SET $RANDOM_VAR = '$TEST_VALUE';"
#$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "ALTER SYSTEM SET wal_sender_timeout = 60000;"
$INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE restart
PG_PID=$(lsof -ti :5432)

echo "$RANDOM_VAR set. Running some operations..."

# Simulate workload
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "CREATE TABLE IF NOT EXISTS test_wal_crash(id SERIAL PRIMARY KEY, txt TEXT);"
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "INSERT INTO test_wal_crash(txt) SELECT md5(random()::text) FROM generate_series(1,1000);"

echo "Simulating crash with kill -9"
kill -9 $PG_PID

echo "Starting PostgreSQL..."
$INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
PG_PID=$(lsof -ti :5432)

echo "Checking recovery..."
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "SELECT count(*) FROM test_wal_crash;"

echo "Crash recovery test with WAL encryption and $RANDOM_VAR=$TEST_VALUE completed successfully."

