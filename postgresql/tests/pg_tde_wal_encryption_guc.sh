#!/bin/bash

INSTALL_DIR="$HOME/postgresql/bld_18.1.1/install"
DATA_DIR_BASE="$INSTALL_DIR/data"
KEYFILE="/tmp/keyfile.per"
PG_PORT=5432

WAL_BUFFER_SIZES=("4MB" "16MB" "32MB")

# Check for pg_tde keyfile
if [[ -f $KEYFILE ]]; then
  rm -rf $KEYFILE
fi

run_test() {
  local wal_buffer=$1
  local data_dir="${DATA_DIR_BASE}_${wal_buffer}"
  echo "============================="
  echo "Testing with wal_buffers = $wal_buffer"
  echo "Data dir: $data_dir"
  echo "============================="
  
  pkill -9 postgres
  rm -rf "$data_dir"
  "$INSTALL_DIR/bin/initdb" -D "$data_dir"

  echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
  echo "port = $PG_PORT" >> "$data_dir/postgresql.conf"
  echo "wal_buffers = '$wal_buffer'" >> "$data_dir/postgresql.conf"
  echo "logging_collector = on" >> "$data_dir/postgresql.conf"
  echo "log_directory = 'log'" >> "$data_dir/postgresql.conf"
  echo "io_method = 'sync'" >> "$data_dir/postgresql.conf"
  echo "log_filename = 'postgresql.log'" >> "$data_dir/postgresql.conf"

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" -l "$data_dir/server.log" start
  sleep 2

  # Setup pg_tde
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" restart
  sleep 2

  # Create test DB and run workload
  "$INSTALL_DIR/bin/createdb" -p $PG_PORT testdb
  "$INSTALL_DIR/bin/pgbench" -p $PG_PORT -i testdb
  "$INSTALL_DIR/bin/pgbench" -p $PG_PORT -c 4 -j 2 -T 30 testdb

  # Verify WAL files
  echo "Sample hexdump from WAL file:"
  WAL_FILE=$(find "$data_dir/pg_wal" -type f | head -n 1)
  if [[ -f "$WAL_FILE" ]]; then
    hexdump -C "$WAL_FILE" | head -n 10
  else
    echo "No WAL file found!"
  fi

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" stop
  echo "Test complete for wal_buffers = $wal_buffer"
  echo
}

for size in "${WAL_BUFFER_SIZES[@]}"; do
  run_test "$size"
done

echo "✅ All tests complete."

