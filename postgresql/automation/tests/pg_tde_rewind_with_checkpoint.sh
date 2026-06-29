#!/bin/bash

# -------------------------------------------------------------------------
# pg_tde_rewind test with WAL encryption
#
# Test objective:
#   Verify pg_tde_rewind correctly rewinds an old primary after
#   standby promotion while WAL encryption is enabled.
# -------------------------------------------------------------------------

PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PSQL="$INSTALL_DIR/bin/psql"

KEYFILE="$RUN_DIR/keyring.file"

echo "Cleaning previous environment"

old_server_cleanup "$PRIMARY_DATA"
old_server_cleanup "$REPLICA_DATA"
rm -f "$KEYFILE" "$ARCHIVE_DIR" || true
mkdir -p "$ARCHIVE_DIR"

##############################################################################
# Initialize Primary
##############################################################################

initialize_server "$PRIMARY_DATA" "$PRIMARY_PORT"
enable_pg_tde "$PRIMARY_DATA"

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
wal_level = replica
max_wal_senders = 5
listen_addresses='*'

archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "cp %%p $ARCHIVE_DIR/%%f"'
restore_command='$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p "cp $ARCHIVE_DIR/%%f %%p"'
EOF

echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

$PSQL -p $PRIMARY_PORT postgres <<EOF
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');
SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');
SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');
ALTER SYSTEM SET pg_tde.wal_encrypt='ON';
EOF

restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

##############################################################################
# Create Streaming Replica
##############################################################################

mkdir "$REPLICA_DATA"
chmod 700 "$REPLICA_DATA"
cp -R "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA"

$PG_BASEBACKUP -D "$REPLICA_DATA" -R -X stream -E -c fast -h localhost -p "$PRIMARY_PORT"

cat > "$REPLICA_DATA/postgresql.conf" <<EOF
port=$REPLICA_PORT
shared_preload_libraries='pg_tde'
default_table_access_method='tde_heap'
listen_addresses='*'
unix_socket_directories = '$RUN_DIR'
max_wal_senders = 5
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'replica.log'
log_statement = 'all'

archive_mode=on
archive_command='$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "cp %%p $ARCHIVE_DIR/%%f"'
EOF

start_pg "$REPLICA_DATA" "$REPLICA_PORT"

##############################################################################
# Generate Initial Data
##############################################################################

echo "Creating encrypted table"
$PSQL -p $PRIMARY_PORT postgres <<EOF

CREATE TABLE t1(
    id integer PRIMARY KEY,
    value text
) USING tde_heap;

INSERT INTO t1
SELECT g,
       md5(g::text)
FROM generate_series(1,10000) g;

CHECKPOINT;
SELECT pg_switch_wal();

EOF

wait_for_replica_catchup $PRIMARY_PORT $REPLICA_PORT

##############################################################################
# Promote Replica
##############################################################################

echo "Promoting standby"
$PG_CTL -D "$REPLICA_DATA" promote -w

##############################################################################
# Divergent Changes
##############################################################################

echo "Generating divergent WAL"
$PSQL -p $REPLICA_PORT postgres <<EOF

INSERT INTO t1
SELECT g,
       md5(g::text)
FROM generate_series(10001,20000) g;

ALTER TABLE t1 ADD COLUMN updated boolean DEFAULT false;

UPDATE t1
SET updated=true
WHERE id % 10 = 0;

CHECKPOINT;
SELECT pg_switch_wal();

EOF

##############################################################################
# Stop Old Primary
##############################################################################

echo "Stopping old primary"
$PG_CTL -D "$PRIMARY_DATA" stop -m fast
echo "Stopping promoted primary"
$PG_CTL -D "$REPLICA_DATA" stop -m fast

##############################################################################
# Take backup of postgresql.conf before pg_rewind
# ############################################################################
cp $PRIMARY_DATA/postgresql.conf $RUN_DIR/postgresql.conf

##############################################################################
# Rewind
##############################################################################
echo "Running pg_tde_rewind"

$PG_REWIND \
    --target-pgdata="$PRIMARY_DATA" \
    --source-pgdata="$REPLICA_DATA" -c

##############################################################################
# Configure Old Primary as Standby
##############################################################################

##############################################################################
# Restore postgresql.conf from backup as pg_rewind replaces the config file
# from source node into target node
##############################################################################
mv $RUN_DIR/postgresql.conf $PRIMARY_DATA/postgresql.conf
sed -i "s/port=5433/port=$REPLICA_PORT/" "$PRIMARY_DATA/postgresql.auto.conf"
touch "$PRIMARY_DATA/standby.signal"

##############################################################################
# Start Promoted Primary
##############################################################################
echo "Starting promoted primary"
start_pg "$REPLICA_DATA" "$REPLICA_PORT"

##############################################################################
# Start Rewound Node
##############################################################################
echo "Starting rewound node"
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"
wait_for_replica_catchup $REPLICA_PORT $PRIMARY_PORT

##############################################################################
# Verification
##############################################################################

echo "Checking replay status"

RECOVERY=$($PSQL -At -p $PRIMARY_PORT postgres \
    -c "SELECT pg_is_in_recovery();")

[[ "$RECOVERY" == "t" ]] || {
    echo "Node is not running as standby"
    exit 1
}

COUNT=$($PSQL -At -p $PRIMARY_PORT postgres \
    -c "SELECT count(*) FROM t1;")

[[ "$COUNT" == "20000" ]] || {
    echo "Unexpected row count: $COUNT"
    exit 1
}

echo "Testing replication after rewind"

$PSQL -p $REPLICA_PORT postgres \
    -c "INSERT INTO t1 VALUES (20001, 'after_rewind', true);"

wait_for_replica_catchup $REPLICA_PORT $PRIMARY_PORT

COUNT=$($PSQL -At -p $PRIMARY_PORT postgres \
    -c "SELECT count(*) FROM t1;")

[[ "$COUNT" == "20001" ]] || {
    echo "Streaming replication failed after rewind"
    exit 1
}

echo
echo "======================================================"
echo "PASS: pg_tde_rewind works correctly with WAL encryption"
echo "======================================================"
