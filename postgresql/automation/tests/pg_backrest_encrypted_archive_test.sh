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
PGBACKREST=$(command -v pgbackrest)
KEYRING="/tmp/keyring.file"
ARCHIVE_DIR="$RUN_DIR/pgbackrest_repo"
BACKREST_LOGS="$RUN_DIR/pgbackrest_logs"

#############################################
# CLEANUP
#############################################

echo "Cleaning environment"

old_server_cleanup "$PRIMARY_DATA"
rm -rf "$ARCHIVE_DIR" || true
rm -rf "$KEYRING" || true

#############################################
# INIT PRIMARY
#############################################

echo "Initializing server"

initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$BACKREST_LOGS"
chmod 755 $BACKREST_LOGS

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

#############################################
# Validate archived WALs
#############################################

echo "Archive information"

$PGBACKREST \
    --config="$RUN_DIR/pgbackrest.conf" \
    --stanza=demo \
    info

echo
echo "Archived WAL files:"
find "$ARCHIVE_DIR" -type f | grep -E '[0-9A-F]{24}' || true

ARCHIVED_COUNT=$(find "$ARCHIVE_DIR" -type f | grep -cE '[0-9A-F]{24}')

echo "Archived WAL count: $ARCHIVED_COUNT"

if [ "$ARCHIVED_COUNT" -eq 0 ]; then
    echo "ERROR: No WAL files archived"
    exit 1
fi

#############################################
# Take backup (optional sanity check)
#############################################

echo "Taking full backup"

$PGBACKREST \
    --config="$RUN_DIR/pgbackrest.conf" \
    --stanza=demo \
    backup

#############################################
# Verify backup exists
#############################################

$PGBACKREST \
    --config="$RUN_DIR/pgbackrest.conf" \
    --stanza=demo \
    info

#############################################
# Capture baseline data
#############################################

echo "Capturing baseline data"

BASELINE=$(
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -Atc "
SELECT
    count(*),
    min(id),
    max(id),
    md5(string_agg(id||payload, '' ORDER BY id))
FROM t1;"
)

echo "Baseline: $BASELINE"

#############################################
# Restore backup into fresh datadir
#############################################

RESTORE_DATA="$RUN_DIR/restore_data"
RESTORE_PORT=6543

echo "Preparing restore directory"

rm -rf "$RESTORE_DATA"
mkdir -p "$RESTORE_DATA"
chmod 700 "$RESTORE_DATA"

echo "Restoring backup"

$PGBACKREST \
    --config="$RUN_DIR/pgbackrest.conf" \
    --stanza=demo \
    --pg1-path="$RESTORE_DATA" \
    restore

#############################################
# Copy pg_tde metadata
#############################################

cp -R "$PRIMARY_DATA/pg_tde" "$RESTORE_DATA/"

cat > "$RESTORE_DATA/postgresql.conf" <<EOF

port=$RESTORE_PORT
unix_socket_directories='$RUN_DIR'
shared_preload_libraries='pg_tde'

logging_collector=on
log_directory='$RESTORE_DATA'
log_filename='restore.log'
listen_addresses='localhost'
EOF

rm -f "$RESTORE_DATA/postmaster.pid"

#############################################
# Start restored instance
#############################################

echo "Starting restored cluster"

start_pg "$RESTORE_DATA" "$RESTORE_PORT"

#############################################
# Validate restored data
#############################################

echo "Validating restored data"

RESTORED=$(
$PSQL -h $RUN_DIR -p $RESTORE_PORT -d postgres -Atc "
SELECT
    count(*),
    min(id),
    max(id),
    md5(string_agg(id||payload, '' ORDER BY id))
FROM t1;"
)

echo "Restored: $RESTORED"

if [ "$BASELINE" != "$RESTORED" ]; then
    echo
    echo "ERROR: Restored data does not match original data"
    echo "Original : $BASELINE"
    echo "Restored : $RESTORED"
    exit 1
fi

#############################################
# Additional validation
#############################################

PRIMARY_COUNT=$(
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -Atc \
"SELECT count(*) FROM t1;"
)

RESTORE_COUNT=$(
$PSQL -h $RUN_DIR -p $RESTORE_PORT -d postgres -Atc \
"SELECT count(*) FROM t1;"
)

if [ "$PRIMARY_COUNT" != "$RESTORE_COUNT" ]; then
    echo
    echo "ERROR: Row count mismatch"
    echo "Primary : $PRIMARY_COUNT"
    echo "Restore : $RESTORE_COUNT"
    exit 1
fi

echo
echo "Primary count : $PRIMARY_COUNT"
echo "Restore count : $RESTORE_COUNT"

stop_pg "$RESTORE_DATA" "$RESTORE_PORT"

echo
echo "TEST PASSED"
