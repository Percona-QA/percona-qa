#!/bin/bash

# Config
INSTALL_DIR=$HOME/postgresql/bld_17.6/install
DATA_DIR_BASE=$INSTALL_DIR/data
ARCHIVE_DIR=$INSTALL_DIR/wal_archive
BASE_BACKUP_DIR=$INSTALL_DIR/base_backup
PITR_RECOVERY_DIR=$INSTALL_DIR/pitr_restore
LOG_DIR=$INSTALL_DIR/logs

rm -rf "$DATA_DIR_BASE" "$ARCHIVE_DIR" "$BASE_BACKUP_DIR" "$PITR_RECOVERY_DIR" "$LOG_DIR"
mkdir $ARCHIVE_DIR $LOG_DIR

PG_CTL=$INSTALL_DIR/bin/pg_ctl
PSQL=$INSTALL_DIR/bin/psql
PG_BASEBACKUP=$INSTALL_DIR/bin/pg_basebackup

PORT=5432
pkill -9 postgres

echo "Step 1: Init DB and Enable Archiving..."
rm -rf "$DATA_DIR_BASE"
$INSTALL_DIR/bin/initdb -D "$DATA_DIR_BASE"

cat >> "$DATA_DIR_BASE/postgresql.conf" <<EOF
port = $PORT
logging_collector = on
log_directory = '$LOG_DIR'
wal_level = replica
archive_mode = on
archive_command = 'cp %p $ARCHIVE_DIR/%f'
EOF

$PG_CTL -D "$DATA_DIR_BASE" -l "$LOG_DIR/server.log" start
sleep 3

echo "Step 2: Create tables and insert initial data..."
$PSQL -p $PORT -c "CREATE TABLE accounts(id INT PRIMARY KEY, balance INT);" postgres
$PSQL -p $PORT -c "INSERT INTO accounts VALUES (1, 100), (2, 200);" postgres

echo "Step 3: Take Base Backup..."
$PG_BASEBACKUP -D "$BASE_BACKUP_DIR" -Fp -Xs -P -v -p $PORT

echo "Step 4: Generate more data and capture recovery target timestamp..."
$PSQL -p $PORT -c "INSERT INTO accounts VALUES (3, 300);" postgres

# Capture recovery target timestamp after INSERT
TARGET_TIME=$($PSQL -p $PORT -At -c "SELECT now();" postgres)
echo "Captured recovery target timestamp: $TARGET_TIME"

sleep 1
$PSQL -p $PORT -c "INSERT INTO accounts VALUES (4, 400);" postgres
TARGET_TIME2=$($PSQL -p $PORT -At -c "SELECT now();" postgres)
echo "Captured recovery target timestamp: $TARGET_TIME2"

sleep 1
$PSQL -p $PORT -c "INSERT INTO accounts VALUES (5, 500);" postgres
TARGET_TIME3=$($PSQL -p $PORT -At -c "SELECT now();" postgres)
echo "Captured recovery target timestamp: $TARGET_TIME3"

# Force WAL switch and give time for archiving
$PSQL -p $PORT -c "SELECT pg_switch_wal();" postgres
sleep 3

echo "Step 5: Stop and simulate crash..."
$PG_CTL -D "$DATA_DIR_BASE" -m immediate stop

echo "Step 6: Perform PITR to captured timestamp..."
rm -rf "$PITR_RECOVERY_DIR"
cp -r "$BASE_BACKUP_DIR" "$PITR_RECOVERY_DIR"
chmod 700 "$PITR_RECOVERY_DIR"

# Configure PITR settings
cat >> "$PITR_RECOVERY_DIR/postgresql.conf" <<EOF
port = $PORT
restore_command = 'cp $ARCHIVE_DIR/%f %p'
recovery_target_time = '$TARGET_TIME2'
EOF

touch "$PITR_RECOVERY_DIR/recovery.signal"

echo "Step 7: Start restored server..."
$PG_CTL -D "$PITR_RECOVERY_DIR" -l "$LOG_DIR/pitr.log" start
sleep 5

echo "Step 8: Check recovered data..."
$PSQL -p $PORT -c "SELECT * FROM accounts;" postgres

