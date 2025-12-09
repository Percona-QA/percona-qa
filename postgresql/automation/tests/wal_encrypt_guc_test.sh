#!/bin/bash

DB_NAME=postgres
KEYFILE="/tmp/keyring.file"

# Old server cleanup
old_server_cleanup $PGDATA
rm -rf $KEYFILE || true

# Create data directory
initialize_server $PGDATA $PORT

# Start PG server and enable TDE
enable_pg_tde $PGDATA
start_pg $PGDATA $PORT

echo "Install pg_tde extension and create server key"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$KEYFILE');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_set_default_key_using_global_key_provider('wal_key','global_keyring');"

echo "Enabling WAL encryption..."
$INSTALL_DIR/bin/psql -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg $PGDATA $PORT

echo "WAL encryption enabled."

# deterministic WAL test parameters
declare -A TEST_PARAMS=(
  [wal_compression]="on"
  [wal_log_hints]="on"
  [wal_writer_delay]="1000"
  [wal_writer_flush_after]="256"
  [wal_level]="logical"
  [wal_buffers]="1024"
  [max_wal_size]="2048"
  [min_wal_size]="128"
  [wal_retrieve_retry_interval]="5000"
  [wal_sender_timeout]="60000"
  [wal_receiver_create_temp_slot]="on"
  [wal_keep_size]="64"
  [track_wal_io_timing]="on"
  [summarize_wal]="on"
)

# which ones require restart
RESTART_REQUIRED=(
  wal_level
  wal_buffers
  max_wal_size
  min_wal_size
)

needs_restart=0

apply_param() {
  local key=$1
  local val=$2
  echo "Setting $key=$val ..."
  $INSTALL_DIR/bin/psql -d "$DB_NAME" -c "ALTER SYSTEM SET $key = '$val';"
  if printf '%s\n' "${RESTART_REQUIRED[@]}" | grep -q -w "$key"; then
    needs_restart=1
  else
    $INSTALL_DIR/bin/psql -d "$DB_NAME" -c "SELECT pg_reload_conf();"
  fi
}

for key in "${!TEST_PARAMS[@]}"; do
  apply_param "$key" "${TEST_PARAMS[$key]}"
done

if [ $needs_restart -eq 1 ]; then
  echo "Restarting for restart-required parameters..."
  restart_pg $PGDATA $PORT
fi

echo "Running workload..."
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "CREATE TABLE test_wal_crash(id SERIAL PRIMARY KEY, txt TEXT);"
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "INSERT INTO test_wal_crash(txt) SELECT md5(random()::text) FROM generate_series(1,5000);"

echo "Simulating crash..."
PG_PID=$(lsof -ti :$PORT)
kill -9 "$PG_PID"

echo "Starting PostgreSQL..."
start_pg $PGDATA $PORT

echo "Validating recovery..."
$INSTALL_DIR/bin/psql -d "$DB_NAME" -c "SELECT count(*) FROM test_wal_crash;"

echo "Crash recovery test with WAL encryption completed successfully."
