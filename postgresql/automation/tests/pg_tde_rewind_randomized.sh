#!/bin/bash

#############################################
# LOOP RUNNER
#############################################
for i in {1..3}; do
  echo "========================================="
  echo "🚀 RUN $i"
  echo "========================================="

#############################################
# CONFIG
#############################################
KEYFILE="$RUN_DIR/keyring.rand"
SYSBENCH=$(command -v sysbench)

PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PSQL="$INSTALL_DIR/bin/psql"

#############################################
# RANDOM HELPERS
#############################################
rand_bool() {
  (( RANDOM % 2 ))
}

maybe_restart() {
  local datadir=$1
  local port=$2

  if rand_bool; then
    echo "Random restart on $datadir"
    restart_pg "$datadir" "$port"
  else
    echo "Skipping restart on $datadir"
  fi
}

#############################################
# WAIT FOR ARCHIVE
#############################################
wait_for_archive() {
  local port=$1

  local wal=$($PSQL -p "$port" -t -A -c \
    "SELECT pg_walfile_name(pg_current_wal_lsn());")

  wal=$(echo "$wal" | tr -d '[:space:]')

  echo "⏳ Waiting for WAL archive: $wal"

  timeout=180

  while [ $timeout -gt 0 ]; do
    if [ -f "$ARCHIVE_DIR/$wal" ]; then
      echo "✅ WAL archived: $wal"
      return 0
    fi

    sleep 1
    timeout=$((timeout-1))
  done

  echo "❌ WAL not archived: $wal"
  return 1
}

#############################################
# FORCE ARCHIVE STABILITY
#############################################
force_wal_archive() {
  local port=$1

  echo "📦 Forcing WAL archival on port $port"

  $PSQL -p "$port" -c "SELECT pg_switch_wal();"
  $PSQL -p "$port" -c "CHECKPOINT;"

  wait_for_archive "$port"
}

#############################################
# ADVANCED RANDOM HELPERS
#############################################

random_wal_boundary() {
  local port=$1

  case $((RANDOM % 4)) in
    0)
      echo "CHECKPOINT"
      $PSQL -p $port -c "CHECKPOINT;"
      ;;
    1)
      echo "WAL SWITCH"
      $PSQL -p $port -c "SELECT pg_switch_wal();"
      ;;
    2)
      echo "CHECKPOINT + WAL SWITCH"
      $PSQL -p $port -c "SELECT pg_switch_wal();"
      $PSQL -p $port -c "CHECKPOINT;"
      ;;
    3)
      echo "Skipping WAL boundary ops"
      ;;
  esac
}

random_stop() {
  local datadir=$1
  local port=$2

  #############################################
  # ENSURE WAL IS ARCHIVED BEFORE STOP
  #############################################
  force_wal_archive "$port"

  case $((RANDOM % 3)) in
    0) mode="smart" ;;
    1) mode="fast" ;;
    2) mode="immediate" ;;  # crash
  esac

  echo "🛑 Stopping $datadir with mode=$mode"
  $PG_CTL -D $datadir stop -m $mode || true
}

maybe_rotate_key() {
  local port=$1

  if rand_bool; then
    local key="key_$RANDOM"
    echo "🔑 Rotating key -> $key"

    $PSQL -p $port -c "SELECT pg_tde_create_key_using_global_key_provider('$key','file_provider');"
    $PSQL -p $port -c "SELECT pg_tde_set_key_using_global_key_provider('$key','file_provider');"
  fi

  if rand_bool; then
    local server_key="server_key_$RANDOM"
    echo "🔑 Rotating server_key -> $server_key"

    $PSQL -p $port -c "SELECT pg_tde_create_key_using_global_key_provider('$server_key','file_provider');"
    $PSQL -p $port -c "SELECT pg_tde_set_server_key_using_global_key_provider('$server_key','file_provider');"
  fi
}

maybe_relfilenode_churn() {
  local port=$1

  if rand_bool; then
    echo "REINDEX"
    $PSQL -p $port -c "REINDEX TABLE t1;" || true
  fi

  if rand_bool; then
    echo "CREATE INDEX CONCURRENTLY"
    $PSQL -p $port -c "CREATE INDEX CONCURRENTLY idx_t1_$RANDOM ON t1(id);" || true
  fi

  if rand_bool; then
    echo "CLUSTER"
    $PSQL -p $port -c "CLUSTER t1;" || true
  fi
}

maybe_divergence_chaos() {
  local port=$1

  if rand_bool; then
    echo "VACUUM FULL"
    $PSQL -p $port -c "VACUUM FULL t1;" || true
  fi

  if rand_bool; then
    echo "TRUNCATE + refill"
    $PSQL -p $port -c "TRUNCATE t1;"
    $PSQL -p $port -c "INSERT INTO t1 SELECT generate_series(1,5000);"
  fi

  if rand_bool; then
    col="c_$RANDOM"
    echo "ALTER TABLE add column $col"
    $PSQL -p $port -c "ALTER TABLE t1 ADD COLUMN $col INT;" || true
  fi
}

#############################################
# CLEANUP
#############################################
echo "Cleaning environment"
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
rm -rf "$ARCHIVE_DIR" "$KEYFILE" || true
mkdir -p "$ARCHIVE_DIR"

#############################################
# INIT PRIMARY
#############################################
echo "Initializing primary"
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

cat >> $PRIMARY_DATA/postgresql.conf <<EOF
wal_level=replica
wal_log_hints = on
archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "cp %%p $ARCHIVE_DIR/%%f"'
restore_command='$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p "cp $ARCHIVE_DIR/%%f %%p"'

archive_timeout='10s'
EOF

echo "host replication all 127.0.0.1/32 trust" >> $PRIMARY_DATA/pg_hba.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT

$PSQL -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('server_key','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('server_key','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg $PRIMARY_DATA $PRIMARY_PORT

#############################################
# BASE DATA
#############################################
$PSQL -p $PRIMARY_PORT -c "CREATE TABLE t1(id INT) USING tde_heap;"
$PSQL -p $PRIMARY_PORT -c "INSERT INTO t1 SELECT generate_series(1,10000);"
$PSQL -p $PRIMARY_PORT -c "CHECKPOINT;"

force_wal_archive "$PRIMARY_PORT"

#############################################
# CREATE REPLICA
#############################################
echo "Creating replica"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA/"

$PG_BASEBACKUP -D $REPLICA_DATA -R -X stream -c fast -E -h localhost -p $PRIMARY_PORT

cat > $REPLICA_DATA/postgresql.conf <<EOF
port=$REPLICA_PORT
unix_socket_directories='$RUN_DIR'
shared_preload_libraries='pg_tde'
listen_addresses='*'

logging_collector=on
log_directory='$REPLICA_DATA'
log_filename='server.log'
log_statement='all'

max_wal_senders=5
wal_level=replica
wal_log_hints = on

archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "cp %%p $ARCHIVE_DIR/%%f"'
restore_command='$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p "cp $ARCHIVE_DIR/%%f %%p"'

archive_timeout='10s'
EOF

start_pg $REPLICA_DATA $REPLICA_PORT

#############################################
# RANDOM RESTART BEFORE PROMOTION
#############################################
maybe_restart $PRIMARY_DATA $PRIMARY_PORT
maybe_restart $REPLICA_DATA $REPLICA_PORT

#############################################
# FORCE WAL STABILITY BEFORE PROMOTION
#############################################
force_wal_archive "$PRIMARY_PORT"

#############################################
# PROMOTE REPLICA
#############################################
echo "Promoting replica"
$PG_CTL -D $REPLICA_DATA promote
sleep 2
force_wal_archive "$REPLICA_PORT"

#############################################
# WORKLOAD
#############################################
if rand_bool; then
  echo "⚡ MINIMAL workload"
  $PSQL -p $REPLICA_PORT -c "INSERT INTO t1 VALUES (999999);"

  maybe_rotate_key $REPLICA_PORT
  random_wal_boundary $REPLICA_PORT

else
  echo "🔥 HEAVY workload"

  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "UPDATE t1 SET id=id+1;"
  fi

  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "DELETE FROM t1 WHERE id%3=0;"
  fi

  maybe_rotate_key $REPLICA_PORT
  maybe_relfilenode_churn $REPLICA_PORT
  maybe_divergence_chaos $REPLICA_PORT

  if rand_bool; then
        $SYSBENCH /usr/share/sysbench/oltp_insert.lua \
      --pgsql-host=localhost \
      --pgsql-port=$REPLICA_PORT \
      --pgsql-user=$(whoami) \
      --pgsql-db=postgres \
      --db-driver=pgsql \
      --threads=2 \
      --tables=20 \
      --table-size=1000 prepare

    $SYSBENCH /usr/share/sysbench/oltp_read_write.lua \
      --pgsql-user=$(whoami) \
      --pgsql-db=postgres \
      --db-driver=pgsql \
      --pgsql-port=$REPLICA_PORT \
      --threads=2 \
      --tables=20 \
      --time=10 run
  fi

  random_wal_boundary $REPLICA_PORT
fi

#############################################
# ENSURE WAL ARCHIVED AFTER DIVERGENCE
#############################################
force_wal_archive "$REPLICA_PORT"

#############################################
# ASYMMETRY
#############################################
$PSQL -p $REPLICA_PORT -c "CREATE TABLE target_only(id INT) USING tde_heap;"
$PSQL -p $REPLICA_PORT -c "INSERT INTO target_only VALUES (1),(2);"

$PSQL -p $PRIMARY_PORT -c "CREATE TABLE source_only(id INT) USING tde_heap;"
$PSQL -p $PRIMARY_PORT -c "INSERT INTO source_only VALUES (10),(20);"

#############################################
# EXTRA CHAOS BEFORE REWIND
#############################################
maybe_rotate_key $PRIMARY_PORT
maybe_divergence_chaos $PRIMARY_PORT
maybe_relfilenode_churn $PRIMARY_PORT
random_wal_boundary $PRIMARY_PORT

force_wal_archive "$PRIMARY_PORT"

#############################################
# RANDOM RESTART BEFORE REWIND
#############################################
maybe_restart $PRIMARY_DATA $PRIMARY_PORT
maybe_restart $REPLICA_DATA $REPLICA_PORT

#############################################
# REWIND
#############################################
echo "Running rewind"
random_stop "$PRIMARY_DATA" "$PRIMARY_PORT"

#############################################
# ENSURE REPLICA WAL SAFE BEFORE STOP
#############################################
force_wal_archive "$REPLICA_PORT"
stop_pg "$REPLICA_DATA" "$REPLICA_PORT"

####################################################################
# BACKUP CONFIGS (pg_tde_rewind is going to overwrite config files)
####################################################################
cp $PRIMARY_DATA/postgresql.conf $RUN_DIR/postgresql_bk.conf
cp $PRIMARY_DATA/postgresql.auto.conf $RUN_DIR/postgresql.auto.conf

$PG_REWIND --target-pgdata=$PRIMARY_DATA \
           --source-pgdata=$REPLICA_DATA -c --debug

#############################################
# RESTORE CONFIGS
#############################################
mv $RUN_DIR/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf
mv $RUN_DIR/postgresql.auto.conf $PRIMARY_DATA/postgresql.auto.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT

#############################################
# POST REWIND
#############################################
restart_pg $PRIMARY_DATA $PRIMARY_PORT
start_pg $REPLICA_DATA $REPLICA_PORT

#############################################
# VALIDATION
#############################################

# Disabling Validation due to several upstream Bugs
# PG-2357, PG-2330
#echo "Validating data"
#$PSQL -p $REPLICA_PORT -c "SELECT count(*), min(id), max(id) FROM t1;"
#$PSQL -p $PRIMARY_PORT -c "SELECT count(*), min(id), max(id) FROM t1;"
#$PSQL -p $REPLICA_PORT -c "SELECT count(*) FROM target_only;"
#$PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM target_only;"

echo "✅ RUN $i completed"

done

echo "🎉 All runs completed successfully"
