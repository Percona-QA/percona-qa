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
KEYRING=/tmp/keyring.file

REPL_USER=repl_user
REPL_PASS=repl_pass

STANZA=demo
SYSBENCH=$(command -v sysbench)

#############################################
echo "Cleanup old setup"
#############################################
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA

sudo rm -rf $BACKREST_CONFIG || true
rm -rf $BACKREST_REPO $BACKREST_LOGS || true
rm -rf $KEYRING || true

mkdir -p $BACKREST_REPO $BACKREST_LOGS
chmod 755 $BACKREST_LOGS

#############################################
echo "Initialize PRIMARY"
#############################################
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

cat >> $PRIMARY_DATA/postgresql.conf <<EOF
wal_level=replica
archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "$PG_BACKREST --stanza=$STANZA archive-push %%p"'
EOF

echo "host replication $REPL_USER 127.0.0.1/32 md5" >> "$PRIMARY_DATA/pg_hba.conf"
#echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

#############################################
echo "Configure pgBackRest"
#############################################
sudo mkdir -p $BACKREST_CONFIG

sudo tee $BACKREST_CONFIG/pgbackrest.conf > /dev/null <<EOF
[global]
repo1-path=$BACKREST_REPO
repo1-retention-full=2
process-max=2
start-fast=y
log-path=$BACKREST_LOGS

[$STANZA]
pg1-path=$PRIMARY_DATA
pg1-port=$PRIMARY_PORT
EOF

#############################################
echo "Start PRIMARY"
#############################################
start_pg $PRIMARY_DATA $PRIMARY_PORT

#############################################
echo "Create replication user"
#############################################
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$REPL_PASS';"

#############################################
echo "Setup pg_tde"
#############################################
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$KEYRING');"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('table_key','global_keyring');"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('table_key','global_keyring');"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

restart_pg $PRIMARY_DATA $PRIMARY_PORT
#############################################
echo "Create pgBackRest stanza + FULL backup"
#############################################
$PG_BACKREST --stanza=$STANZA stanza-create
$PG_BACKREST --stanza=$STANZA --type=full backup

#############################################
echo "Create STANDBY using pgBackRest"
#############################################
$PG_BACKREST --stanza=$STANZA restore \
  --type=standby \
  --pg1-path=$REPLICA_DATA \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $REPLICA_DATA/postgresql.conf <<EOF
port = $REPLICA_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
max_wal_senders = 5
io_method = '$IO_METHOD'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level=replica
hot_standby=on
primary_conninfo='host=localhost port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASS'

EOF

#############################################
echo "Start STANDBY"
#############################################
start_pg $REPLICA_DATA $REPLICA_PORT

sleep 5

#############################################
echo "Prepare workload on Primary"
#############################################
$SYSBENCH /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$PRIMARY_PORT \
  --pgsql-user=$USER \
  --pgsql-db=postgres \
  --db-driver=pgsql \
  --tables=50 --table-size=1000 prepare

########################################################
echo "Create Differential Backup after initial data prep"
########################################################
$PG_BACKREST --stanza=$STANZA --type=diff backup

# Rotate the default key
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('table_key2','global_keyring');"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('table_key2','global_keyring');"

#############################################
echo "Start workload + backup loop"
#############################################

(
while true; do
  $SYSBENCH /usr/share/sysbench/oltp_write_only.lua \
    --pgsql-host=localhost \
    --pgsql-port=$PRIMARY_PORT \
    --pgsql-user=$USER \
    --pgsql-db=postgres \
    --db-driver=pgsql \
    --time=60 --threads=10 --tables=50 run
done
) &

WORKLOAD_PID=$!

(
while true; do 
  $PG_BACKREST --stanza=$STANZA --type=incr backup
  sleep 5
done
) &

BACKUP_PID=$!

sleep 30

#############################################
echo "Crash Primary Server"
#############################################
kill -9 $(head -1 $PRIMARY_DATA/postmaster.pid)
sleep 5

#############################################
echo "PROMOTE STANDBY"
#############################################
$INSTALL_DIR/bin/pg_ctl -D $REPLICA_DATA promote
sleep 5

$SYSBENCH /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$REPLICA_PORT \
  --pgsql-user=$USER \
  --pgsql-db=postgres \
  --db-driver=pgsql \
  --time=60 --threads=10 --tables=50 run

#############################################
echo "Rebuild old PRIMARY using DELTA"
#############################################

rm $PRIMARY_DATA/postmaster.pid

$PG_BACKREST --stanza=$STANZA restore \
  --delta \
  --type=standby \
  --pg1-path=$PRIMARY_DATA \
  --recovery-option=restore_command="$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"$PG_BACKREST --stanza=$STANZA archive-get %%f %%p\""

cat > $PRIMARY_DATA/postgresql.conf <<EOF

port=$PRIMARY_PORT
unix_socket_directories='$RUN_DIR'
listen_addresses='*'
logging_collector=on
log_directory='log'
log_filename='server.log'
shared_preload_libraries='pg_tde'
default_table_access_method='tde_heap'
wal_level=replica
hot_standby=on
primary_conninfo='host=localhost port=$REPLICA_PORT user=$REPL_USER password=$REPL_PASS'

EOF

#############################################
echo "Start rebuilt PRIMARY as STANDBY"
#############################################
start_pg $PRIMARY_DATA $PRIMARY_PORT

sleep 30

#############################################
echo "Validation"
#############################################
$INSTALL_DIR/bin/psql -p $REPLICA_PORT -d postgres -c "CREATE TABLE mohit (a int) using tde_heap;"
$INSTALL_DIR/bin/psql -p $REPLICA_PORT -d postgres -c "INSERT INTO mohit VALUES (100);"
$INSTALL_DIR/bin/psql -p $REPLICA_PORT -d postgres -c "SELECT count(*) FROM sbtest1;"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT count(*) FROM sbtest1;"
$INSTALL_DIR/bin/psql -p $REPLICA_PORT -d postgres -c "SELECT count(*) FROM sbtest10;"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT count(*) FROM sbtest10;"
$INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d postgres -c "SELECT * FROM mohit;"

#############################################
echo "Cleanup background jobs"
#############################################
kill $WORKLOAD_PID || true

echo "Test completed successfully"
