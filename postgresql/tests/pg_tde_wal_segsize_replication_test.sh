#!/bin/bash

INSTALL_DIR="$HOME/postgresql/bld_18.1.1/install"
DATA_DIR_BASE="$INSTALL_DIR/data_segsize"
KEYFILE="/tmp/keyfile.per"
PG_PORT=5432

WAL_SEG_SIZES=(1 16 64)  # in MB

rm -f "$KEYFILE"

run_test() {
  local segsize_mb=$1
  local data_dir="${DATA_DIR_BASE}_${segsize_mb}MB"
  local replica_dir="${data_dir}_replica"
  local replica_port=$((PG_PORT + 1))

  echo "============================="
  echo "Testing with --wal-segsize = ${segsize_mb}MB"
  echo "Primary: $data_dir"
  echo "Replica: $replica_dir"
  echo "============================="

  pkill -9 postgres || true
  rm -rf "$data_dir" "$replica_dir"

  "$INSTALL_DIR/bin/initdb" --wal-segsize="$segsize_mb" -D "$data_dir"

  cat >> "$data_dir/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
port = $PG_PORT
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql.log'
io_method = 'sync'
wal_level = replica
max_wal_senders = 5
wal_keep_size = 64
hot_standby = on
EOF

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" -l "$data_dir/server.log" start
  sleep 2

  # Enable WAL encryption
  "$INSTALL_DIR/bin/psql" -p $PG_PORT -d postgres <<EOF
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');
SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_provider');
ALTER SYSTEM SET pg_tde.wal_encrypt = 'OFF';
EOF

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" restart
  sleep 2

  # Setup replica
  echo "Setting up replica..."
  mkdir $replica_dir
  chmod 700 $replica_dir
  cp -R $data_dir/pg_tde $replica_dir
  "$INSTALL_DIR/bin/pg_tde_basebackup" -h 127.0.0.1 -p $PG_PORT -D "$replica_dir" -Xs -E -U $(whoami) --no-password --write-recovery-conf

  cat >> "$replica_dir/postgresql.conf" <<EOF
port = $replica_port
hot_standby = on
EOF

  echo "Starting replica..."
  "$INSTALL_DIR/bin/pg_ctl" -D "$replica_dir" -l "$replica_dir/server.log" start
  sleep 2

  echo "Replica status:"
  "$INSTALL_DIR/bin/psql" -p $replica_port -d postgres -c "SELECT pg_is_in_recovery();"

  echo "Creating 100 tables..."
  sysbench /usr/share/sysbench/oltp_insert.lua \
    --db-driver=pgsql \
    --pgsql-db=postgres \
    --pgsql-user=$(whoami) \
    --pgsql-port=$PG_PORT \
    --pgsql-host=127.0.0.1 \
    --tables=100 \
    --table-size=1000 \
    --threads=5 \
    prepare

# Run sysbench workload and simulate crash-restart and failover
for phase in {1..4}; do
  echo "============================"
  echo "Phase $phase: Workload Start"
  echo "============================"

  if [[ $phase -eq 1 ]]; then
    echo "Running on primary (normal state)"
    WORKLOAD_PORT=$PG_PORT

  elif [[ $phase -eq 2 ]]; then
    echo "Simulating failover: stopping primary and promoting replica..."
    sleep 5
    "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" stop
    sleep 2
    "$INSTALL_DIR/bin/pg_ctl" -D "$replica_dir" promote
    sleep 3
    echo "Replica promoted. Running on promoted replica."
    WORKLOAD_PORT=$replica_port

  elif [[ $phase -eq 3 ]]; then
    echo "Workload continues on promoted replica"
    WORKLOAD_PORT=$replica_port

  elif [[ $phase -eq 4 ]]; then
    echo "Restarting original primary (now demoted or stale)..."
    "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" -l "$data_dir/server.log" start
    sleep 5
    echo "Original primary restarted. Workload stays on promoted replica."
    WORKLOAD_PORT=$replica_port
  fi

  # Run workload
  sysbench /usr/share/sysbench/oltp_read_write.lua \
    --db-driver=pgsql \
    --pgsql-db=postgres \
    --pgsql-user=$(whoami) \
    --pgsql-port=$WORKLOAD_PORT \
    --pgsql-host=127.0.0.1 \
    --threads=5 \
    --tables=100 \
    --time=30 \
    --report-interval=5 \
    --events=1870000000 \
    run

  echo "============================"
  echo "Phase $phase: Workload End"
  echo "============================"

done

  echo "Sample WAL file:"
  WAL_FILE=$(find "$data_dir/pg_wal" -type f | head -n 1)
  [[ -f "$WAL_FILE" ]] && hexdump -C "$WAL_FILE" | head -n 10 || echo "No WAL found."

  "$INSTALL_DIR/bin/pg_ctl" -D "$data_dir" stop
  "$INSTALL_DIR/bin/pg_ctl" -D "$replica_dir" stop
  echo "Test complete for --wal-segsize = ${segsize_mb}MB"
  echo
}

for segsize in "${WAL_SEG_SIZES[@]}"; do
  run_test "$segsize"
done

echo "All WAL segsize streaming replication + encryption crash tests complete."

