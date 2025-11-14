#!/bin/bash

# Config
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
DATA_DIR_BASE=$INSTALL_DIR/data
ARCHIVE_DIR=$INSTALL_DIR/wal_archive
BASE_BACKUP_DIR=$INSTALL_DIR/base_backup
PITR_RECOVERY_DIR=$INSTALL_DIR/pitr_restore
LOG_DIR=$INSTALL_DIR/logs
PORT=5432

PG_CTL=$INSTALL_DIR/bin/pg_ctl
PSQL=$INSTALL_DIR/bin/psql
PG_TDE_BASEBACKUP=$INSTALL_DIR/bin/pg_tde_basebackup

# Cleanup
echo "Cleaning up previous data..."
pkill -9 postgres || true
rm -f /tmp/keyring.per
rm -rf "$DATA_DIR_BASE" "$ARCHIVE_DIR" "$BASE_BACKUP_DIR" "$PITR_RECOVERY_DIR" "$LOG_DIR"
mkdir -p "$ARCHIVE_DIR" "$LOG_DIR"

echo "Step 1: Initialize DB with WAL archiving..."
$INSTALL_DIR/bin/initdb -D "$DATA_DIR_BASE"
cat >> "$DATA_DIR_BASE/postgresql.conf" <<EOF
port = $PORT
shared_preload_libraries = 'pg_tde'
io_method = 'sync'
wal_level = replica
archive_mode = on
archive_command = 'cp %p $ARCHIVE_DIR/%f'
logging_collector = on
log_directory = '$LOG_DIR'
log_filename = 'server.log'
log_statement = 'all'
EOF

$PG_CTL -D "$DATA_DIR_BASE" -l "$LOG_DIR/server.log" start
sleep 2

echo "Step 2: Enable WAL encryption (assuming TDE is set up)..."
$PSQL -p $PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '/tmp/keyring.per');"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('wal_key', 'global_provider');"
$PSQL -p $PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = ON;"
$PG_CTL -D "$DATA_DIR_BASE" -m fast restart
sleep 2

echo "Step 3: Create multiple tables..."
for i in {1..50}; do
  $PSQL -p $PORT -d postgres -c "CREATE TABLE t_$i (id SERIAL PRIMARY KEY, val TEXT) USING tde_heap;"
done

echo "Step 4: Take base backup..."
$PG_TDE_BASEBACKUP -D "$BASE_BACKUP_DIR" -Fp -Xs -v -p $PORT

echo "Step 5: Load heavy write data..."
declare -A TARGET_TIMES

for iter in {1..3}; do
  echo "  --> Iteration $iter: Writing to tables..."
  for t in {1..50}; do
    $PSQL -p $PORT -d postgres -c "INSERT INTO t_$t(val) SELECT 'data_iter${iter}_row' FROM generate_series(1,100);" &
  done
  wait

  echo "  --> Forcing WAL switch and capturing recovery timestamp..."
  $PSQL -p $PORT -d postgres -c "SELECT pg_switch_wal();" > /dev/null
  sleep 2
  ts=$($PSQL -p $PORT -At -d postgres -c "SELECT now();")
  TARGET_TIMES[$iter]=$ts
  echo "    -> Captured recovery target time $iter: ${TARGET_TIMES[$iter]}"
done

echo "Step 5: Simulate crash..."
pkill -9 postgres
sleep 2

# Recovery iterations
for i in {1..2}; do
  echo "==============================="
  echo " Recovery iteration $i"
  echo "==============================="

  rm -rf "$PITR_RECOVERY_DIR"
  cp -r "$BASE_BACKUP_DIR" "$PITR_RECOVERY_DIR"
  chmod 700 "$PITR_RECOVERY_DIR"

  echo "  --> Configuring PITR with recovery_target_time = ${TARGET_TIMES[$i]}"
  cat >> "$PITR_RECOVERY_DIR/postgresql.conf" <<EOF
port = $PORT
restore_command = 'cp $ARCHIVE_DIR/%f %p'
recovery_target_time = '${TARGET_TIMES[$i]}'
EOF
  touch "$PITR_RECOVERY_DIR/recovery.signal"

  echo "  --> Starting server for PITR..."
  $PG_CTL -D "$PITR_RECOVERY_DIR" -l "$LOG_DIR/pitr_$i.log" start
  sleep 5

  echo "  --> Checking table row counts after PITR..."
  for t in {1..5}; do
    $PSQL -p $PORT -d postgres -c "SELECT COUNT(*) FROM t_$t;"
  done

  echo "  --> Promote server after PITR..."
  $PG_CTL -D "$PITR_RECOVERY_DIR" promote
  sleep 2

  echo "  --> Inserting post-PITR data..."
  $PSQL -p $PORT -d postgres -c "INSERT INTO t_$i(val) VALUES('post-pitr-$i');"

  echo "Step 5: Simulate crash..."
  pkill -9 postgres
  sleep 2

done

echo "✅ Completed all PITR stress test iterations."

