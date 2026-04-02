#!/bin/bash

#############################################
# Install pg_backrest
# ###########################################
install_pgbackrest

#############################################
# CONFIG
#############################################
PG_BACKREST=$(command -v pgbackrest)
BACKREST_REPO=/tmp/pgbackrest_repo
BACKREST_CONFIG=/etc/pgbackrest
BACKREST_LOGS=/tmp/pgbackrest_logs
KEYRING=/tmp/keyring.per
STANZA=demo

#############################################
# Variables
#############################################
RESTORE_FULL=/tmp/restore_full
RESTORE_DELTA=/tmp/restore_delta
RESTORE_STANDBY=/tmp/restore_standby
RESTORE_PITR_TIME=/tmp/restore_pitr
RESTORE_PITR_LSN=/tmp/restore_pitr_lsn
RESTORE_PITR_XID=/tmp/restore_pitr_xid
RESTORE_SELECTIVE=/tmp/restore_selective
RESTORE_FORCE=/tmp/restore_force

#############################################
echo "Cleanup"
#############################################
old_server_cleanup $PGDATA
rm -rf $RESTORE_FULL || true
rm -rf $RESTORE_DELTA || true
rm -rf $RESTORE_STANDBY || true
rm -rf $RESTORE_PITR_TIME || true
rm -rf $RESTORE_PITR_LSN || true
rm -rf $RESTORE_PITR_XID || true
rm -rf $RESTORE_SELECTIVE || true
rm -rf $RESTORE_FORCE || true
rm -rf $KEYRING || true
rm -rf $BACKREST_REPO $BACKREST_LOGS || true
sudo rm -rf $BACKREST_CONFIG || true

#############################################
echo "Initialize PG Server"
#############################################
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA

cat >> $PGDATA/postgresql.conf <<EOF
wal_level=replica
archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "$PG_BACKREST --stanza=$STANZA archive-push %%p"'
EOF

#############################################
echo "Configure pgBackRest"
#############################################
sudo mkdir -p $BACKREST_CONFIG
mkdir -p $BACKREST_REPO $BACKREST_LOGS
chmod 755 $BACKREST_LOGS

sudo tee $BACKREST_CONFIG/pgbackrest.conf > /dev/null <<EOF
[global]
repo1-path=$BACKREST_REPO
repo1-retention-full=2
process-max=4
start-fast=y
log-path=$BACKREST_LOGS

[$STANZA]
pg1-path=$PGDATA
pg1-port=$PORT
EOF

#############################################
echo "Start PG Server"
#############################################
start_pg $PGDATA $PORT

#############################################
echo "Setup pg_tde"
#############################################
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$KEYRING');"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('table_key','global_keyring');"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('table_key','global_keyring');"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg $PGDATA $PORT

#############################################
echo "Create STANZA"
#############################################
$PG_BACKREST --stanza=$STANZA stanza-create

$INSTALL_DIR/bin/psql -p $PORT -d postgres <<SQL
CREATE TABLE t1(a int);
INSERT INTO t1 SELECT generate_series(1,100000);

CREATE DATABASE testdb;
\c testdb
CREATE EXTENSION pg_tde;
CREATE TABLE t2(a int);
INSERT INTO t2 SELECT generate_series(1,50000);
SQL

#############################################
echo "SCENARIO 1: BACKUP CHAIN"
#############################################
echo "FULL BACKUP"
$PG_BACKREST --stanza=$STANZA --type=full backup

echo "DIFF BACKUP"
$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 SELECT generate_series(100001,200000);"
$PG_BACKREST --stanza=$STANZA --type=diff backup

echo "INCR BACKUP"
$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 SELECT generate_series(200001,300000);"
$PG_BACKREST --stanza=$STANZA --type=incr backup

echo "DIFF BACKUP"
$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 SELECT generate_series(300001,400000);"
$PG_BACKREST --stanza=$STANZA --type=diff backup

echo "INCR BACKUP"
$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 SELECT generate_series(400001,500000);"
$PG_BACKREST --stanza=$STANZA --type=incr backup

##############################################
echo "SCENARIO 2: RESUME BACKUP"
#############################################
echo "Simulating interrupted backup"
for i in {1..3}; do
  $PG_BACKREST --stanza=$STANZA backup &
  BKP_PID=$!
  sleep 3
  kill -9 $BKP_PID
done

echo "Resuming backup"
$PG_BACKREST --stanza=$STANZA backup --resume

#############################################
echo "SCENARIO 3: FULL RESTORE"
#############################################
mkdir -p $RESTORE_FULL
RESTORE_FULL_PORT=5540

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=/tmp/restore_full \
  --type=default \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_FULL/postgresql.conf <<EOF
port = $RESTORE_FULL_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_FULL'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_FULL/postmaster.pid
start_pg $RESTORE_FULL $RESTORE_FULL_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_FULL_PORT -d postgres -c "SELECT count(*) FROM t1;"
$INSTALL_DIR/bin/psql -p $RESTORE_FULL_PORT -d testdb -c "SELECT count(*) FROM t2;"

stop_pg $RESTORE_FULL $RESTORE_FULL_PORT

#############################################
echo "SCENARIO 4: DELTA RESTORE"
#############################################
echo "Introduce divergence in PGDATA"
$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 SELECT generate_series(500001,600000);"

# Force WAL + checkpoint so data is written
$INSTALL_DIR/bin/psql -p $PORT -c "CHECKPOINT;"

cp -r $PGDATA $RESTORE_DELTA
RESTORE_DELTA_PORT=5541

rm -f $RESTORE_DELTA/postmaster.pid

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_DELTA \
  --delta \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_DELTA/postgresql.conf <<EOF
port = $RESTORE_DELTA_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_DELTA'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

start_pg $RESTORE_DELTA $RESTORE_DELTA_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_DELTA_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_DELTA $RESTORE_DELTA_PORT

#############################################
echo "SCENARIO 5: STANDBY RESTORE"
#############################################
mkdir -p $RESTORE_STANDBY
RESTORE_STANDBY_PORT=5542

$PG_BACKREST --stanza=$STANZA restore \
  --type=standby \
  --pg1-path=$RESTORE_STANDBY \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_STANDBY/postgresql.conf <<EOF
port = $RESTORE_STANDBY_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_STANDBY'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_STANDBY/postmaster.pid
start_pg $RESTORE_STANDBY $RESTORE_STANDBY_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_STANDBY_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_STANDBY $RESTORE_STANDBY_PORT

#############################################
echo "SCENARIO 6: PITR (TIME)"
#############################################
mkdir -p $RESTORE_PITR_TIME
RESTORE_PITR_TIME_PORT=5543
TARGET_TIME=$(date +"%Y-%m-%d %H:%M:%S")
sleep 1

$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 VALUES (999999);"
$INSTALL_DIR/bin/psql -p $PORT -c "SELECT pg_switch_wal();"
sleep 3

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_PITR_TIME \
  --type=time \
  --target="$TARGET_TIME" \
  --target-action=promote \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_PITR_TIME/postgresql.conf <<EOF
port = $RESTORE_PITR_TIME_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_PITR_TIME'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_PITR_TIME/postmaster.pid
start_pg $RESTORE_PITR_TIME $RESTORE_PITR_TIME_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_PITR_TIME_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_PITR_TIME $RESTORE_PITR_TIME_PORT

#############################################
echo "SCENARIO 7: PITR (LSN)"
#############################################
mkdir -p $RESTORE_PITR_LSN
RESTORE_PITR_LSN_PORT=5544

LSN=$($INSTALL_DIR/bin/psql -p $PORT -Atc "SELECT pg_current_wal_lsn();")

$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 VALUES (888888);"
$INSTALL_DIR/bin/psql -p $PORT -c "SELECT pg_switch_wal();"

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_PITR_LSN \
  --type=lsn \
  --target="$LSN" \
  --target-action=pause \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_PITR_LSN/postgresql.conf <<EOF
port = $RESTORE_PITR_LSN_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_PITR_LSN'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_PITR_LSN/postmaster.pid
start_pg $RESTORE_PITR_LSN $RESTORE_PITR_LSN_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_PITR_LSN_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_PITR_LSN $RESTORE_PITR_LSN_PORT

#############################################
echo "SCENARIO 8: PITR (XID)"
#############################################
mkdir -p $RESTORE_PITR_XID
RESTORE_PITR_XID_PORT=5545

XID=$($INSTALL_DIR/bin/psql -p $PORT -Atc "SELECT txid_current();")

$INSTALL_DIR/bin/psql -p $PORT -c "INSERT INTO t1 VALUES (777777);"
$INSTALL_DIR/bin/psql -p $PORT -c "SELECT pg_switch_wal();"

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_PITR_XID \
  --type=xid \
  --target="$XID" \
  --target-action=promote \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_PITR_XID/postgresql.conf <<EOF
port = $RESTORE_PITR_XID_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_PITR_XID'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_PITR_XID/postmaster.pid
start_pg $RESTORE_PITR_XID $RESTORE_PITR_XID_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_PITR_XID_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_PITR_XID $RESTORE_PITR_XID_PORT

#############################################
echo "SCENARIO 9: SELECTIVE DB RESTORE"
#############################################
mkdir -p $RESTORE_SELECTIVE
RESTORE_SELECTIVE_PORT=5546

#$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "DROP TABLE t1;"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "CHECKPOINT;"

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_SELECTIVE \
  --db-include=testdb \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_SELECTIVE/postgresql.conf <<EOF
port = $RESTORE_SELECTIVE_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_SELECTIVE'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_SELECTIVE/postmaster.pid
start_pg $RESTORE_SELECTIVE $RESTORE_SELECTIVE_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_SELECTIVE_PORT -d postgres -c "SELECT count(*) FROM t1;"
$INSTALL_DIR/bin/psql -p $RESTORE_SELECTIVE_PORT -d testdb -c "SELECT count(*) FROM t2;"
stop_pg $RESTORE_SELECTIVE $RESTORE_SELECTIVE_PORT

#############################################
echo "SCENARIO 10: FORCE RESTORE"
#############################################
mkdir -p $RESTORE_FORCE
RESTORE_FORCE_PORT=5547

$PG_BACKREST --stanza=$STANZA restore \
  --pg1-path=$RESTORE_FORCE \
  --force \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $RESTORE_FORCE/postgresql.conf <<EOF
port = $RESTORE_FORCE_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_FORCE'
log_filename = 'server.log'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
EOF

rm -f $RESTORE_FORCE/postmaster.pid
start_pg $RESTORE_FORCE $RESTORE_FORCE_PORT
$INSTALL_DIR/bin/psql -p $RESTORE_FORCE_PORT -d postgres -c "SELECT count(*) FROM t1;"
stop_pg $RESTORE_FORCE $RESTORE_FORCE_PORT

#############################################
echo "Validation on PG Server"
#############################################
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "SELECT count(*) FROM t1;"
$INSTALL_DIR/bin/psql -p $PORT -d testdb -c "SELECT count(*) FROM t2;"
$INSTALL_DIR/bin/psql -p $PORT -d postgres -c "SELECT count(*) FROM pg_tables;"

#############################################
echo "pgBackRest Info + Check"
#############################################
$PG_BACKREST --stanza=$STANZA info
$PG_BACKREST --stanza=$STANZA check

echo "Test completed successfully"
