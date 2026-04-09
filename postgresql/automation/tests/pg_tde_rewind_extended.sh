#!/bin/bash

#############################################
# CONFIG
#############################################
KEYFILE="$RUN_DIR/keyring.file"
KEY_ROTATION=${KEY_ROTATION:-1}
CRASH_MODE=${CRASH_MODE:-1}
TABLESPACE_TEST=${TABLESPACE_TEST:-1}
CHANGE_KEY_PROVIDER=${CHANGE_KEY_PROVIDER:-1}
TABLESPACE_FILE="$RUN_DIR/ts1_primary"
TABLESPACE_FILE_REPL="$RUN_DIR/ts1_replica"
SYSBENCH=$(command -v sysbench)

#############################################
# BINARIES
#############################################
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PSQL="$INSTALL_DIR/bin/psql"

#############################################
# CLEANUP
#############################################
echo "Cleaning environment"
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
rm -rf "$ARCHIVE_DIR" "$KEYFILE" "$TABLESPACE_FILE" "$TABLESPACE_FILE_REPL" || true
mkdir -p "$ARCHIVE_DIR"

#############################################
# START VAULT SERVER
# ###########################################
start_vault_server

#############################################
# INIT PRIMARY
#############################################
echo "Initializing primary"
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

cat >> $PRIMARY_DATA/postgresql.conf <<EOF
wal_level=replica
archive_mode=on
archive_command='cp %p $ARCHIVE_DIR/%f'
restore_command='cp $ARCHIVE_DIR/%f %p'
EOF

echo "host replication all 127.0.0.1/32 trust" >> $PRIMARY_DATA/pg_hba.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT

$PSQL -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_database_key_provider_file('local_file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_database_key_provider_vault_v2('local_vault_provider','$vault_url','$secret_mount_point','$token_file','$vault_ca');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1','global_file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','global_file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('key2','local_file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('key2','local_file_provider');"

#restart_pg $PRIMARY_DATA $PRIMARY_PORT

if [ "$TABLESPACE_TEST" -eq 1 ]; then
  mkdir -p $TABLESPACE_FILE
  $PSQL -p $PRIMARY_PORT -c "CREATE TABLESPACE ts1 LOCATION '$TABLESPACE_FILE';"
fi

#############################################
# CREATE REPLICA
#############################################
echo "Creating replica"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA/"

if [ "$TABLESPACE_TEST" -eq 1 ]; then
  mkdir -p $TABLESPACE_FILE_REPL
  $PG_BASEBACKUP -D $REPLICA_DATA -R -X stream -c fast -E --tablespace-mapping=$TABLESPACE_FILE=$TABLESPACE_FILE_REPL -h localhost -p $PRIMARY_PORT
else
  $PG_BASEBACKUP -D $REPLICA_DATA -R -X stream -c fast -E -h localhost -p $PRIMARY_PORT
fi

cat > $REPLICA_DATA/postgresql.conf <<EOF
port=$REPLICA_PORT
unix_socket_directories='$RUN_DIR'
listen_addresses='*'
logging_collector=on
log_directory='$REPLICA_DATA'
log_filename='server.log'
log_statement='all'
default_table_access_method='tde_heap'
shared_preload_libraries='pg_tde'
restore_command='cp $ARCHIVE_DIR/%f %p'
EOF

start_pg $REPLICA_DATA $REPLICA_PORT

run_test() {

  ###########################################
  # Base table + sysbench prepare
  ###########################################
  $PSQL -p $PRIMARY_PORT -c "CREATE TABLE t1(id INT) USING tde_heap;"
  $PSQL -p $PRIMARY_PORT -c "INSERT INTO t1 SELECT generate_series(1,1000);"

  echo "Preparing sysbench data on primary"
  $SYSBENCH /usr/share/sysbench/oltp_read_write.lua \
    --pgsql-user=$(whoami) \
    --pgsql-db=postgres \
    --db-driver=pgsql \
    --pgsql-port=$PRIMARY_PORT \
    --threads=5 \
    --tables=10 \
    --table-size=10000 \
    prepare

  $PSQL -p $PRIMARY_PORT -c "CHECKPOINT;"

  restart_pg $PRIMARY_DATA $PRIMARY_PORT
  restart_pg $REPLICA_DATA $REPLICA_PORT

  ###########################################
  # Promote replica
  ###########################################
  $PG_CTL -D $REPLICA_DATA promote
  sleep 3

  restart_pg $PRIMARY_DATA $PRIMARY_PORT
  restart_pg $REPLICA_DATA $REPLICA_PORT

  echo "Running divergence workload"

  ###########################################
  # Core corruption triggers
  ###########################################
  $PSQL -p $REPLICA_PORT -c "INSERT INTO t1 SELECT generate_series(1,500000);"
  $PSQL -p $REPLICA_PORT -c "UPDATE t1 SET id=id+1;"
  $PSQL -p $REPLICA_PORT -c "DELETE FROM t1 WHERE id%2=0;"

  $PSQL -p $REPLICA_PORT -c "CREATE INDEX idx_t1 ON t1(id);"
  $PSQL -p $REPLICA_PORT -c "REINDEX TABLE t1;"

  ###########################################
  # ADVANCED SCENARIOS
  ###########################################
  echo "Running advanced workload scenarios"

  # Multi-table mixed workload
  for i in {1..10}; do
    $PSQL -p $REPLICA_PORT -c "CREATE TABLE mt_$i(id INT, val TEXT) USING tde_heap;"
    $PSQL -p $REPLICA_PORT -c "INSERT INTO mt_$i SELECT g, md5(random()::text) FROM generate_series(1,10000) g;"
  done

  $PSQL -p $REPLICA_PORT -c "UPDATE mt_1 SET val = md5(random()::text);"
  $PSQL -p $REPLICA_PORT -c "DELETE FROM mt_2 WHERE id % 3 = 0;"
  $PSQL -p $REPLICA_PORT -c "VACUUM FULL mt_3;"

  # TOAST-heavy table
  $PSQL -p $REPLICA_PORT -c "
    CREATE TABLE toast_test(id INT, data TEXT) USING tde_heap;
  "
  $PSQL -p $REPLICA_PORT -c "
    INSERT INTO toast_test
    SELECT g, repeat(md5(random()::text), 1000)
    FROM generate_series(1,5000) g;
  "

  # Partitioned table
  $PSQL -p $REPLICA_PORT -c "
    CREATE TABLE part_test(id INT, created DATE)
    PARTITION BY RANGE(created) USING tde_heap;
  "
  $PSQL -p $REPLICA_PORT -c "
    CREATE TABLE part_test_1 PARTITION OF part_test
    FOR VALUES FROM ('2024-01-01') TO ('2024-06-01');
  "
  $PSQL -p $REPLICA_PORT -c "
    INSERT INTO part_test SELECT g, '2024-02-01' FROM generate_series(1,10000) g;
  "

  # UNLOGGED + TEMP tables
  $PSQL -p $REPLICA_PORT -c "CREATE UNLOGGED TABLE u1(id INT);"
  $PSQL -p $REPLICA_PORT -c "INSERT INTO u1 SELECT generate_series(1,10000);"
  $PSQL -p $REPLICA_PORT -c "CREATE TEMP TABLE temp1(id INT); INSERT INTO temp1 VALUES (1),(2);"

  # Indexes
  $PSQL -p $REPLICA_PORT -c "CREATE INDEX idx_partial ON t1(id) WHERE id > 100;"
  $PSQL -p $REPLICA_PORT -c "CREATE INDEX idx_expr ON t1((id * 2));"

  # WAL pressure
  $PSQL -p $REPLICA_PORT -c "
    INSERT INTO t1 SELECT generate_series(1,200000);
    CHECKPOINT;
  "

  # Concurrent sysbench
  echo "Running concurrent sysbench"
  for i in {1..3}; do
    (
      $SYSBENCH /usr/share/sysbench/oltp_read_write.lua \
        --pgsql-user=$(whoami) \
        --pgsql-db=postgres \
        --db-driver=pgsql \
        --pgsql-port=$REPLICA_PORT \
        --threads=2 \
        --tables=10 \
        --time=20 run
    ) &
  done

  ###########################################
  # Key rotation
  ###########################################
  if [ "$KEY_ROTATION" -eq 1 ]; then
  (
    duration=20
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
	    RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
	    echo "Rotating master key: principal_key_test$RAND_KEY"
            $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_create_key_using_database_key_provider('key$RAND_KEY','local_file_provider');"
            $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_set_key_using_database_key_provider('key$RAND_KEY','local_file_provider');"
	    RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
            $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('key$RAND_KEY','global_file_provider');"
            $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('key$RAND_KEY','global_file_provider');"
	    RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
	    $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_create_key_using_database_key_provider('key$RAND_KEY','local_vault_provider');"
	    $PSQL -p $REPLICA_PORT -c "SELECT pg_tde_set_key_using_database_key_provider('key$RAND_KEY','local_vault_provider');"
    done
  ) &
  fi

  ############################################
  # Change Key provider
  ############################################
  if [ "$CHANGE_KEY_PROVIDER" -eq 1 ]; then
  (
    start_time=20
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
      provider_type=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "vault_v2" || echo "file")
      if [ $provider_type == "vault_v2" ]; then
        provider_name=local_vault_provider
        provider_config="'$vault_url','$secret_mount_point','$token_file','$vault_ca'"
      elif [ $provider_type == "file" ]; then
        provider_name=local_file_provider
        provider_config="'$KEYFILE'"
      fi
      $PSQL -p $REPLICA_PORT -c"SELECT pg_tde_change_database_key_provider_$provider_type('$provider_name',$provider_config)"
      sleep 1
    done
  ) &
  fi

  wait

  ###########################################
  # Tablespace test
  ###########################################
  if [ "$TABLESPACE_TEST" -eq 1 ]; then
    $PSQL -p $REPLICA_PORT -c "ALTER TABLE t1 SET TABLESPACE ts1;"
  fi

  ###########################################
  # Stress workload
  ###########################################
  $SYSBENCH /usr/share/sysbench/oltp_read_write.lua \
    --pgsql-user=$(whoami) \
    --pgsql-db=postgres \
    --db-driver=pgsql \
    --pgsql-port=$REPLICA_PORT \
    --threads=5 \
    --tables=10 \
    --time=30 run

  ###########################################
  # Crash simulation
  ###########################################
  if [ "$CRASH_MODE" -eq 1 ]; then
    echo "Simulating crash on replica"

    crash_pg $REPLICA_DATA

    echo "Restarting replica for crash recovery"
    start_pg $REPLICA_DATA $REPLICA_PORT

    echo "Stopping replica cleanly after recovery"
    stop_pg $REPLICA_DATA
  fi

  ###########################################
  # Rewind
  ###########################################
  stop_both
  sleep 5
  rewind_and_start

  ###########################################
  # Validation
  ###########################################
  $PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM t1;"

  echo "Deep validation"
  $PSQL -p $PRIMARY_PORT -c "SET enable_seqscan=off;SELECT * FROM t1 ORDER BY id LIMIT 10;"
  $PSQL -p $PRIMARY_PORT -c "REINDEX TABLE t1;"
  $PSQL -p $PRIMARY_PORT -c "VACUUM FULL t1;"

  # Validate sysbench tables
  $PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM sbtest1;"
  $PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM sbtest5;"
}

#############################################
# HELPERS
#############################################
stop_both() {
  echo "Stopping servers"
  $PG_CTL -D $PRIMARY_DATA stop -m fast || true
  $PG_CTL -D $REPLICA_DATA stop -m fast || true
}

rewind_and_start() {
  echo "Running pg_rewind"
  $PG_REWIND --target-pgdata=$PRIMARY_DATA \
             --source-pgdata=$REPLICA_DATA -c

  start_pg $PRIMARY_DATA $PRIMARY_PORT

  # Restart twice to expose latent corruption
  restart_pg $PRIMARY_DATA $PRIMARY_PORT
  restart_pg $PRIMARY_DATA $PRIMARY_PORT
}

#############################################
# EXECUTION
#############################################
run_test

echo "✅ Test completed"
