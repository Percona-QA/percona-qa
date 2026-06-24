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
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg $PRIMARY_DATA $PRIMARY_PORT

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

$PSQL -p "$PRIMARY_PORT" <<EOF
CREATE TABLE t1 (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, f1 TEXT) USING tde_heap;
INSERT INTO t1 (f1) SELECT repeat('abcdeF', 1000) FROM generate_series(1, 1000000);

CREATE TABLE t2 (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, f1 TEXT) USING tde_heap;
INSERT INTO t2 (f1) SELECT repeat('abcdeF', 1000) FROM generate_series(1, 10000);
CHECKPOINT;
EOF

#############################################
# PROMOTE REPLICA
#############################################
echo "Promoting replica"
$PG_CTL -D $REPLICA_DATA promote
sleep 2

$PSQL -p "$PRIMARY_PORT" <<EOF
UPDATE t1 SET f1='YYYYYYY' WHERE id % 10 = 0;
EOF

########################################################
# Verify multiple segments
########################################################
RELNODE=$($PSQL -p "$REPLICA_PORT" -Atc "SELECT pg_relation_filenode('t1');")
DBOID=$($PSQL -p "$REPLICA_PORT" -Atc "SELECT oid FROM pg_database WHERE datname=current_database();")
ls -lh "$REPLICA_DATA/base/$DBOID/$RELNODE"*

########################################################
# Divergence
########################################################

stop_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

echo "Generating divergence..."

$PSQL -p "$REPLICA_PORT" <<EOF
INSERT INTO t2 (f1) SELECT repeat('ghijk', 100) FROM generate_series(1, 1000);
CHECKPOINT;
EOF

stop_pg "$REPLICA_DATA" "$REPLICA_PORT"

####################################################################
# BACKUP CONFIGS (pg_tde_rewind is going to overwrite config files)
####################################################################
cp $PRIMARY_DATA/postgresql.conf $RUN_DIR/postgresql_bk.conf

#############################################
# REWIND
#############################################
echo "Running rewind"
$PG_REWIND --target-pgdata=$PRIMARY_DATA \
           --source-pgdata=$REPLICA_DATA -c --debug

#############################################
# RESTORE CONFIGS
#############################################
mv $RUN_DIR/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"
start_pg "$REPLICA_DATA" "$REPLICA_PORT"

#############################################
# VALIDATION
#############################################
echo "Validating data"

SRC_COUNT=$($PSQL -p "$REPLICA_PORT" -Atc "SELECT count(*) FROM t1;")
TGT_COUNT=$($PSQL -p "$PRIMARY_PORT" -Atc "SELECT count(*) FROM t1;")

echo "Source count : $SRC_COUNT"
echo "Target count : $TGT_COUNT"

if [ "$SRC_COUNT" != "$TGT_COUNT" ]; then
   echo "FAILED: row count mismatch"
   exit 1
fi

echo "🎉 All runs completed successfully"
