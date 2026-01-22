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

  echo "Creating 10 tables with initial rows..."
  sysbench /usr/share/sysbench/oltp_insert.lua \
  --db-driver=pgsql \
  --pgsql-db=postgres \
  --pgsql-user=$(whoami) \
  --pgsql-port=$PORT \
  --pgsql-host=127.0.0.1 \
  --tables=10 \
  --table-size=100 \
  --threads=2 \
  prepare

  # Run sysbench workload in 4 chunks of 30 seconds, restarting server in between
  for phase in {1..4}; do
    echo "Phase $phase: running sysbenchbench for 30s..."
    sysbench /usr/share/sysbench/oltp_read_write.lua \
  --db-driver=pgsql \
  --pgsql-db=postgres \
  --pgsql-user=`whoami` \
  --pgsql-port=$PORT \
  --pgsql-host=127.0.0.1 \
  --threads=2 \
  --tables=10 \
  --time=50 \
  --report-interval=5 \
  run &

    if [[ $phase -lt 4 ]]; then
      echo "Killing PostgreSQL server after 30 s..."
      sleep 30
      $INSTALL_DIR/bin/pg_ctl -D "$data_dir" -m immediate stop
      sleep 2
      echo "Restarting PostgreSQL server..."
      start_pg $data_dir $PORT
    fi
  done

  # Verify WAL files
  echo "Sample hexdump from WAL file:"
  for WAL_FILE in "$data_dir/pg_wal"/[0-9A-F]*; do
    if [[ -f "$WAL_FILE" ]]; then
      if strings "$WAL_FILE" | grep -qi "sbtest"; then
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

