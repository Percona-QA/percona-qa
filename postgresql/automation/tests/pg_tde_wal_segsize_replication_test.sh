#!/bin/bash

DATA_DIR_BASE="$RUN_DIR/data_segsize"
KEYFILE="$RUN_DIR/keyfile.per"

WAL_SEG_SIZES=(1 16 64)  # in MB

rm -f "$KEYFILE" || true

run_test() {
  local segsize_mb=$1
  local data_dir="${DATA_DIR_BASE}_${segsize_mb}MB"
  local replica_dir="${data_dir}_replica"
  local replica_port=$((PORT + 1))

  echo "============================="
  echo "Testing with --wal-segsize = ${segsize_mb}MB"
  echo "Primary: $data_dir"
  echo "Replica: $replica_dir"
  echo "============================="

  old_server_cleanup $data_dir
  old_server_cleanup $replica_dir

  initialize_server $data_dir $PORT "--wal-segsize=$segsize_mb"
  enable_pg_tde $data_dir

  local minwal=$(( segsize_mb * 2 ))
  echo "min_wal_size = '${minwal}MB'" >> "$data_dir/postgresql.conf"

  cat >> "$data_dir/postgresql.conf" <<EOF
wal_level = replica
max_wal_senders = 5
wal_keep_size = 64
hot_standby = on
EOF
  start_pg $data_dir $PORT

  # Enable WAL encryption
  "$INSTALL_DIR/bin/psql" -p $PORT -d postgres <<EOF
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');
SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_key_using_global_key_provider('server_key1', 'global_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_provider');
ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';
EOF
  restart_pg $data_dir $PORT

  # Setup replica
  echo "Setting up replica..."
  mkdir $replica_dir
  chmod 700 $replica_dir
  cp -R $data_dir/pg_tde $replica_dir
  "$INSTALL_DIR/bin/pg_tde_basebackup" -h 127.0.0.1 -p $PORT -D "$replica_dir" -Xs -E -U $(whoami) --no-password --write-recovery-conf

  cat >> "$replica_dir/postgresql.conf" <<EOF
port = $replica_port
hot_standby = on
EOF

  echo "Starting replica..."
  start_pg $replica_dir $replica_port

  echo "Waiting for replica to enter recovery mode..."
  timeout 30 bash -c "
  until $INSTALL_DIR/bin/psql -p $replica_port -d postgres -Atc \"SELECT pg_is_in_recovery();\" 2>/dev/null | grep -q ^t$; do
    sleep 1
  done
  "

  if [[ $? -ne 0 ]]; then
    echo "ERROR: Replica did not enter recovery within timeout."
    exit 1
  fi

  echo "Creating 10 tables..."
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

# Run sysbench workload and simulate crash-restart and failover
for phase in {1..4}; do
  echo "============================"
  echo "Phase $phase: Workload Start"
  echo "============================"

  if [[ $phase -eq 1 ]]; then
    echo "Running on primary (normal state)"
    WORKLOAD_PORT=$PORT

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
    --threads=2 \
    --tables=10 \
    --time=30 \
    --report-interval=10 \
    run

  echo "============================"
  echo "Phase $phase: Workload End"
  echo "============================"

done
  sleep 5

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
  "$INSTALL_DIR/bin/pg_ctl" -D "$replica_dir" stop
  echo "Test complete for --wal-segsize = ${segsize_mb}MB"
  echo
}

for segsize in "${WAL_SEG_SIZES[@]}"; do
  run_test "$segsize"
done

echo "All WAL segsize streaming replication + encryption crash tests complete."

