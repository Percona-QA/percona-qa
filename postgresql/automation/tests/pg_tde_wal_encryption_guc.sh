#!/bin/bash

DATA_DIR_BASE="$RUN_DIR/data"
KEYFILE="$RUN_DIR/keyfile.per"

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
  
  old_server_cleanup $data_dir
  initialize_server $data_dir $PORT
  enable_pg_tde $data_dir
  echo "wal_buffers = '$wal_buffer'" >> "$data_dir/postgresql.conf"

  start_pg $data_dir $PORT

  # Setup pg_tde
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "CREATE EXTENSION pg_tde;"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

  restart_pg $data_dir $PORT

  # Create test DB and run workload
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "CREATE TABLE t1(x text);"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "INSERT INTO t1 VALUES ('IamNotEncryptedDB');"
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres -c "SELECT pg_switch_wal();"

  # Verify WAL files
  echo "Sample hexdump from WAL file:"
  for WAL_FILE in "$data_dir/pg_wal"/[0-9A-F]*; do
    if [[ -f "$WAL_FILE" ]]; then
      if strings "$WAL_FILE" | grep -qi "IamNotEncryptedDB"; then
        echo "ERROR: WAL appears to be unencrypted (plaintext found)"
        exit 1
      else
        echo "WAL appears to be encrypted (plaintext not found)"
      fi
    else
      echo "No WAL file found!"
      exit 1
    fi
  done

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" stop
  echo "Test complete for wal_buffers = $wal_buffer"

  # Check for pg_tde keyfile
  if [[ -f $KEYFILE ]]; then
    rm -rf $KEYFILE
  fi
}

for size in "${WAL_BUFFER_SIZES[@]}"; do
  run_test "$size"
done

echo "✅ All tests complete."
