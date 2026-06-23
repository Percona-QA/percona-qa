#!/bin/bash

#############################################
# Install pgBackRest
#############################################
install_pgbackrest

#############################################
# CONFIG
#############################################

PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PSQL="$INSTALL_DIR/bin/psql"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PGBACKREST=$(command -v pgbackrest)
KEYRING="/tmp/keyring.file"
ARCHIVE_DIR="$RUN_DIR/pgbackrest_repo"
BACKREST_LOGS="$RUN_DIR/pgbackrest_logs"

#############################################
# CLEANUP
#############################################

echo "Cleaning environment"

old_server_cleanup "$PRIMARY_DATA"
old_server_cleanup "$REPLICA_DATA"
rm -rf "$ARCHIVE_DIR" || true
rm -rf "$KEYRING" || true
mkdir -p "$ARCHIVE_DIR"
mkdir -p "$BACKREST_LOGS"
chmod 755 $BACKREST_LOGS

#############################################
# INIT PRIMARY
#############################################

echo "Initializing server"

initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

#############################################
# Configure pgBackRest
#############################################

cat > "$RUN_DIR/pgbackrest.conf" <<EOF
[global]
repo1-path=$ARCHIVE_DIR
repo1-retention-full=2
start-fast=y
log-path=$BACKREST_LOGS
archive-header-check=n

[demo]
pg1-path=$PRIMARY_DATA
pg1-port=$PRIMARY_PORT
pg1-socket-path=$RUN_DIR
EOF

echo "Configuring PostgreSQL for pgBackRest archiving"

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF

archive_mode = on
archive_command = '$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-push %p'
restore_command = '$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-get %f %p'
archive_timeout = 10s
max_wal_senders = 5
wal_level = replica
EOF

#############################################
# START SERVER
#############################################

start_pg $PRIMARY_DATA $PRIMARY_PORT

#############################################
# ENABLE ENCRYPTION
# ###########################################
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$KEYRING');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('table_key','global_keyring');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('table_key','global_keyring');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
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

archive_mode=on
archive_command = '$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-push %p'

archive_timeout='10s'
EOF

start_pg $REPLICA_DATA $REPLICA_PORT

#############################################
# Create stanza
#############################################

echo "Creating pgBackRest stanza"

$PGBACKREST \
    --config="$RUN_DIR/pgbackrest.conf" \
    --stanza=demo \
    stanza-create

#############################################
# Generate WAL workload
#############################################

echo "Generating workload"

$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres <<EOF
CREATE TABLE t1 (
    id BIGSERIAL,
    payload TEXT
) USING tde_heap;

INSERT INTO t1(payload)
SELECT repeat(md5(random()::text), 20)
FROM generate_series(1,100000);

CHECKPOINT;
SELECT pg_switch_wal();

INSERT INTO t1(payload)
SELECT repeat(md5(random()::text), 20)
FROM generate_series(1,100000);

CHECKPOINT;
SELECT pg_switch_wal();

INSERT INTO t1(payload)
SELECT repeat(md5(random()::text), 20)
FROM generate_series(1,100000);

CHECKPOINT;
SELECT pg_switch_wal();
EOF

#############################################
# Wait for archiving
#############################################

echo "Waiting for WAL archiving"
sleep 15


$INSTALL_DIR/bin/pg_ctl \
    -D "$REPLICA_DATA" \
    promote

sleep 2

$PSQL -h $RUN_DIR -p "$REPLICA_PORT" -d postgres <<EOF
INSERT INTO t1(payload)
SELECT repeat(md5(random()::text),20)
FROM generate_series(1,500000);

CHECKPOINT;
SELECT pg_switch_wal();
EOF

################################################
# Create Divergence
################################################
$PSQL -h $RUN_DIR -p "$PRIMARY_PORT" -d postgres <<EOF
INSERT INTO t1(payload)
SELECT repeat(md5(random()::text),20)
FROM generate_series(1,500000);

CREATE TABLE t2 (
    id BIGSERIAL,
    payload TEXT
) USING tde_heap;

INSERT INTO t2(payload)
SELECT repeat(md5(random()::text),20)
FROM generate_series(1,500000);

CHECKPOINT;
SELECT pg_switch_wal();
EOF

stop_pg $PRIMARY_DATA
stop_pg $REPLICA_DATA $REPLICA_PORT

####################################################################
# BACKUP CONFIGS (pg_tde_rewind is going to overwrite config files)
####################################################################
cp $PRIMARY_DATA/postgresql.conf $RUN_DIR/postgresql_bk.conf
$PG_REWIND --target-pgdata=$PRIMARY_DATA \
           --source-pgdata=$REPLICA_DATA -c --debug

#############################################
# RESTORE CONFIGS
#############################################
mv $RUN_DIR/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT
start_pg $REPLICA_DATA $REPLICA_PORT

echo "Validating data"
$PSQL -h $RUN_DIR -p $REPLICA_PORT -d postgres -c "SELECT count(*), min(id), max(id) FROM t1;"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT count(*), min(id), max(id) FROM t1;"

# Verify t2 does not exist after rewind
if $PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -tAc \
    "SELECT 1 FROM pg_class WHERE relname='t2'" | grep -q 1
then
    echo "ERROR: t2 exists after pg_rewind"
    exit 1
fi

echo "TEST PASSED"
