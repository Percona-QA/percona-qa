#!/bin/bash

DATA_DIR_BASE="$RUN_DIR/data_segsize"
KEYFILE="/tmp/keyfile.per"

WAL_SEG_SIZES=(1 16 64)  # in MB

# Clean up old keyfile and custom SQL
rm -f "$KEYFILE" || true

run_test() {
  local segsize_mb=$1
  local data_dir="${DATA_DIR_BASE}_${segsize_mb}MB"
  echo "============================="
  echo "Testing with --wal-segsize = ${segsize_mb}MB"
  echo "Data dir: $data_dir"
  echo "============================="

  old_server_cleanup $data_dir
  initialize_server $data_dir $PORT "--wal-segsize=$segsize_mb"
  enable_pg_tde $data_dir

  local minwal=$(( segsize_mb * 2 ))
  echo "min_wal_size = '${minwal}MB'" >> "$data_dir/postgresql.conf"

  start_pg $data_dir $PORT

  # Setup pg_tde and enable WAL encryption
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres <<EOF
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');
SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_provider');
ALTER SYSTEM SET pg_tde.wal_encrypt='ON';
EOF

  restart_pg $data_dir $PORT

  # pgbench instead of sysbench: sysbench's Lua engine (LuaJIT 2.1.0-beta3)
  # crashes on Ubuntu 22.04 arm64.
  echo "Creating pgbench tables with initial rows..."
  "$INSTALL_DIR/bin/pgbench" -h 127.0.0.1 -p $PORT -U $(whoami) -d postgres -i -s 1 -q

  # Run pgbench workload in 4 chunks, restarting server in between
  for phase in {1..4}; do
    echo "Phase $phase: running pgbench..."
    "$INSTALL_DIR/bin/pgbench" -h 127.0.0.1 -p $PORT -U $(whoami) -d postgres \
      -c 2 -j 2 -T 50 -P 5 --max-tries=10 &

    if [[ $phase -lt 4 ]]; then
      echo "Killing PostgreSQL server after 10 s..."
      sleep 10
      $INSTALL_DIR/bin/pg_ctl -D "$data_dir" -m immediate stop
      sleep 2
      echo "Restarting PostgreSQL server..."
      start_pg $data_dir $PORT
    fi
  done

  # A distinctive row written just before the check: unencrypted WAL would
  # contain it in plain text. (pgbench's rows have no identifiable text, and
  # the WAL that created its tables may already be recycled.)
  WAL_MARKER="walmarker-$RANDOM$RANDOM"
  "$INSTALL_DIR/bin/psql" -h 127.0.0.1 -p $PORT -d postgres -c "CREATE TABLE IF NOT EXISTS wal_marker(v text); INSERT INTO wal_marker VALUES ('$WAL_MARKER');"

  # Verify WAL files
  echo "Sample hexdump from WAL file:"
  for WAL_FILE in "$data_dir/pg_wal"/[0-9A-F]*; do
    if [[ -f "$WAL_FILE" ]]; then
      if strings "$WAL_FILE" | grep -qF "$WAL_MARKER"; then
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
  echo "Test complete for --wal-segsize = ${segsize_mb}MB"
  echo
}

for segsize in "${WAL_SEG_SIZES[@]}"; do
  run_test "$segsize"
done

echo "All --wal-segsize crash-loop WAL encryption tests complete."

