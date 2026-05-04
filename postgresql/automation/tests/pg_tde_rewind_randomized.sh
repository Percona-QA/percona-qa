#!/bin/bash

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
    echo "🔁 Random restart on $datadir"
    restart_pg "$datadir" "$port"
  else
    echo "⏭️ Skipping restart on $datadir"
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
archive_mode=on
archive_command='cp %p $ARCHIVE_DIR/%f'
restore_command='cp $ARCHIVE_DIR/%f %p'
EOF

echo "host replication all 127.0.0.1/32 trust" >> $PRIMARY_DATA/pg_hba.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT

$PSQL -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('server_key','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key','file_provider');"

#############################################
# BASE DATA
#############################################
$PSQL -p $PRIMARY_PORT -c "CREATE TABLE t1(id INT) USING tde_heap;"
$PSQL -p $PRIMARY_PORT -c "INSERT INTO t1 SELECT generate_series(1,10000);"
$PSQL -p $PRIMARY_PORT -c "CHECKPOINT;"

#############################################
# CREATE REPLICA
#############################################
echo "Creating replica"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA/"

$PG_BASEBACKUP -D $REPLICA_DATA -R -X stream -c fast -E -h localhost -p $PRIMARY_PORT

cat >> $REPLICA_DATA/postgresql.conf <<EOF
port=$REPLICA_PORT
unix_socket_directories='$RUN_DIR'
shared_preload_libraries='pg_tde'
restore_command='cp $ARCHIVE_DIR/%f %p'
EOF

start_pg $REPLICA_DATA $REPLICA_PORT

#############################################
# 1. RANDOMIZED RESTART BEFORE PROMOTION
#############################################
#maybe_restart $PRIMARY_DATA $PRIMARY_PORT
# Bug PG-2329
restart_pg $PRIMARY_DATA $PRIMARY_PORT
maybe_restart $REPLICA_DATA $REPLICA_PORT

#############################################
# PROMOTE REPLICA
#############################################
$PG_CTL -D $REPLICA_DATA promote
sleep 2

#############################################
# 2. MINIMAL vs HEAVY PATH
#############################################
if rand_bool; then
  echo "⚡ Running MINIMAL path (partial WAL exposure)"
  $PSQL -p $REPLICA_PORT -c "INSERT INTO t1 VALUES (999999);"
  $PSQL -p $REPLICA_PORT -c "CHECKPOINT;"
else
  echo "🔥 Running HEAVY workload"

  # Randomized workload intensity
  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "UPDATE t1 SET id=id+1;"
  fi

  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "DELETE FROM t1 WHERE id%3=0;"
  fi

  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "CREATE INDEX idx_t1 ON t1(id);"
  fi

  if rand_bool; then
    $PSQL -p $REPLICA_PORT -c "REINDEX TABLE t1;"
  fi

  if rand_bool; then
    $SYSBENCH /usr/share/sysbench/oltp_insert.lua \
      --pgsql-host=localhost \
      --pgsql-port=$REPLICA_PORT \
      --pgsql-user=$(whoami) \
      --pgsql-db=postgres \
      --db-driver=pgsql \
      --threads=5 \
      --tables=100 \
      --table-size=1000 prepare

    $SYSBENCH /usr/share/sysbench/oltp_read_write.lua \
      --pgsql-user=$(whoami) \
      --pgsql-db=postgres \
      --db-driver=pgsql \
      --pgsql-port=$REPLICA_PORT \
      --threads=2 \
      --tables=100 \
      --time=10 run
  fi
fi

#############################################
# 3. ASYMMETRY
#############################################
echo "Creating asymmetric objects"

# Exists only on TARGET (replica after promotion)
$PSQL -p $REPLICA_PORT -c "CREATE TABLE target_only(id INT) USING tde_heap;"
$PSQL -p $REPLICA_PORT -c "INSERT INTO target_only VALUES (1),(2);"

# Exists only on SOURCE (primary)
$PSQL -p $PRIMARY_PORT -c "CREATE TABLE source_only(id INT) USING tde_heap;"
$PSQL -p $PRIMARY_PORT -c "INSERT INTO source_only VALUES (10),(20);"

#############################################
# RANDOM RESTART BEFORE REWIND
#############################################
maybe_restart $PRIMARY_DATA $PRIMARY_PORT
maybe_restart $REPLICA_DATA $REPLICA_PORT

#############################################
# REWIND
#############################################
echo "Running rewind"
$PG_CTL -D $PRIMARY_DATA stop -m fast || true
$PG_CTL -D $REPLICA_DATA stop -m fast || true

$PG_REWIND --target-pgdata=$PRIMARY_DATA \
           --source-pgdata=$REPLICA_DATA -c

start_pg $PRIMARY_DATA $PRIMARY_PORT

#############################################
# 5. RANDOM POST-REWIND RESTARTS
#############################################
maybe_restart $PRIMARY_DATA $PRIMARY_PORT

#############################################
# VALIDATION
#############################################
echo "Validating data"

# Base table should exist
$PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM t1;"

# Source table must exist
echo "Checking source_only exists"
$PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM source_only;"

# Target-only table must NOT exist
echo "Checking target_only removed"
$PSQL -p $PRIMARY_PORT -c "SELECT to_regclass('target_only');"

#############################################
# FINAL CHECK
#############################################
$PSQL -p $PRIMARY_PORT -c "SET enable_seqscan=off; SELECT * FROM t1 LIMIT 5;"

echo "✅ Randomized rewind test completed"
