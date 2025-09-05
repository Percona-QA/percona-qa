#!/bin/bash

INSTALL_DIR="$HOME/postgresql/bld_17.6/install"
DATA_DIR_BASE="$INSTALL_DIR/data_segsize"
KEYFILE="/tmp/keyfile.per"
PG_PORT=5432

WAL_SEG_SIZES=(1 16 64)  # in MB
CUSTOM_SQL="/tmp/pgbench_custom.sql"

# Clean up old keyfile and custom SQL
rm -f "$KEYFILE" "$CUSTOM_SQL"

run_test() {
  local segsize_mb=$1
  local data_dir="${DATA_DIR_BASE}_${segsize_mb}MB"
  echo "============================="
  echo "Testing with --wal-segsize = ${segsize_mb}MB"
  echo "Data dir: $data_dir"
  echo "============================="

  pkill -9 postgres || true
  rm -rf "$data_dir"
  "$INSTALL_DIR/bin/initdb" --wal-segsize="$segsize_mb" -D "$data_dir"

  echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
  echo "port = $PG_PORT" >> "$data_dir/postgresql.conf"
  echo "logging_collector = on" >> "$data_dir/postgresql.conf"
  echo "log_directory = 'log'" >> "$data_dir/postgresql.conf"
  echo "log_filename = 'postgresql.log'" >> "$data_dir/postgresql.conf"

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" -l "$data_dir/server.log" start
  sleep 2

  # Setup pg_tde and enable WAL encryption
  "$INSTALL_DIR/bin/createdb" -p $PG_PORT postgres
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('server_key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_provider');"
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" restart
  sleep 2

  # Create 100 tables with initial data
  echo "Creating 100 tables with initial rows..."
  sysbench /usr/share/sysbench/oltp_insert.lua \
  --db-driver=pgsql \
  --pgsql-db=postgres \
  --pgsql-user=`whoami` \
  --pgsql-port=5432 \
  --pgsql-host=127.0.0.1 \
  --tables=100 \
  --table-size=1000 \
  --threads=5 \
  prepare


  # Run pgbench workload in 4 chunks of 30 seconds, restarting server in between
  for phase in {1..4}; do
    echo "Phase $phase: running sysbenchbench for 30s..."
    sysbench /usr/share/sysbench/oltp_read_write.lua \
  --db-driver=pgsql \
  --pgsql-db=postgres \
  --pgsql-user=`whoami` \
  --pgsql-port=5432 \
  --pgsql-host=127.0.0.1 \
  --threads=5 \
  --tables=100 \
  --time=50 \
  --report-interval=5 \
  --events=1870000000 \
  run &

    if [[ $phase -lt 4 ]]; then
      echo "Killing PostgreSQL server after 30 s..."
      sleep 30
      pkill -9 postgres
      sleep 2
      echo "Restarting PostgreSQL server..."
      "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" -l "$data_dir/server.log" start
      sleep 3
    fi
  done

  # Dump sample WAL file
  echo "Sample hexdump from WAL file:"
  WAL_FILE=$(find "$data_dir/pg_wal" -type f | head -n 1)
  if [[ -f "$WAL_FILE" ]]; then
    hexdump -C "$WAL_FILE" | head -n 10
  else
    echo "No WAL file found!"
  fi

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" stop
  echo "Test complete for --wal-segsize = ${segsize_mb}MB"
  echo
}

for segsize in "${WAL_SEG_SIZES[@]}"; do
  run_test "$segsize"
done

echo "All --wal-segsize crash-loop WAL encryption tests complete."

