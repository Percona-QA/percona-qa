#!/bin/bash

#############################################
# Install pgBackRest
#############################################
install_pgbackrest

#############################################
# Install patroni
#############################################
install_patroni_and_etcd

#############################################
# CONFIG
#############################################
PSQL="$INSTALL_DIR/bin/psql"
PGBACKREST=$(command -v pgbackrest)

KEYRING="$RUN_DIR/keyring.file"
ARCHIVE_DIR="$RUN_DIR/pgbackrest_repo"
BACKREST_LOGS="$RUN_DIR/pgbackrest_logs"

PATRONI_NODE1="$PATRONI_BASE/node1"
PATRONI_NODE2="$PATRONI_BASE/node2"
PATRONI_NODE3="$PATRONI_BASE/node3"

PRIMARY_DATA="$PATRONI_NODE1/data"
PRIMARY_PORT=5432

#############################################
# Helper
#############################################

patroni_psql()
{
    local port=${1:-5432}
    shift

    PGPASSWORD=postgres
    export PGPASSWORD

    "$PSQL" \
        -h 127.0.0.1 \
        -p "$port" \
        -U postgres \
        -d postgres \
        "$@"
}

#############################################
# CLEANUP
#############################################

echo "Cleaning environment"

rm -rf "$ARCHIVE_DIR" || true
rm -rf "$BACKREST_LOGS" || true
rm -rf "$KEYRING" || true

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$BACKREST_LOGS"

cleanup_patroni_cluster

#############################################
# START PATRONI CLUSTER
#############################################

initialize_patroni_cluster 3
start_patroni_cluster 3
wait_for_patroni_leader
wait_for_patroni_replicas 2

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
checksum-page=n

[demo]
pg1-path=$PRIMARY_DATA
pg1-port=$PRIMARY_PORT
pg1-socket-path=/tmp
pg1-user=postgres
EOF

#############################################
# Configure leader for pgBackRest
#############################################

echo "Configuring leader for pgBackRest archiving"
patroni_psql 5432 -c "ALTER SYSTEM SET archive_mode = 'on';"

patroni_psql 5432 -c "
ALTER SYSTEM SET archive_command =
'$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-push %p';
"

patroni_psql 5432 -c "
ALTER SYSTEM SET restore_command =
'$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-get %f %p';
"

patroni_psql 5432 -c "ALTER SYSTEM SET archive_timeout = '10s';"

#############################################
# Enable pg_tde
#############################################

echo "Enabling pg_tde"
patroni_psql 5432 -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"

patroni_psql 5432 -c "
SELECT pg_tde_add_global_key_provider_file(
'global_keyring',
'$KEYRING'
);
"

patroni_psql 5432 -c "
SELECT pg_tde_create_key_using_global_key_provider(
'table_key',
'global_keyring'
);
"

patroni_psql 5432 -c "
SELECT pg_tde_set_default_key_using_global_key_provider(
'table_key',
'global_keyring'
);
"

#############################################
# Enable WAL encryption
#############################################

echo "Enabling WAL encryption"
patroni_psql 5432 -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';"

echo "Restarting leader"
patronictl -c "$PATRONI_NODE1/patroni.yml" restart qa-cluster node1 --force

sleep 10

wait_for_patroni_leader
wait_for_patroni_replicas 2

#############################################
# Create stanza
#############################################

cat > "$RUN_DIR/.pgpass" <<EOF
127.0.0.1:5432:*:postgres:postgres
EOF

chmod 600 "$RUN_DIR/.pgpass"
export PGPASSFILE="$RUN_DIR/.pgpass"

echo "Creating pgBackRest stanza"

$PGBACKREST \
--config="$RUN_DIR/pgbackrest.conf" \
--stanza=demo \
stanza-create

#############################################
# Generate encrypted workload
#############################################

echo "Generating workload"

patroni_psql 5432 <<EOF
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
# Take full backup
#############################################
echo "Taking full backup"

$PGBACKREST \
--config="$RUN_DIR/pgbackrest.conf" \
--stanza=demo \
backup

echo "Backup information"

$PGBACKREST \
--config="$RUN_DIR/pgbackrest.conf" \
--stanza=demo \
info

#############################################
# Stop Patroni leader
#############################################
patronictl -c "$PATRONI_NODE1/patroni.yml" pause qa-cluster 

echo "Stopping Patroni leader"
pkill -f "$PATRONI_NODE1/patroni.yml"
sleep 5

#############################################
# Restore backup into leader data directory
#############################################
echo "Restoring backup into Patroni leader data directory"

rm -rf "$PRIMARY_DATA"
mkdir -p "$PRIMARY_DATA"
chmod 700 "$PRIMARY_DATA"

$PGBACKREST \
--config="$RUN_DIR/pgbackrest.conf" \
--stanza=demo \
--pg1-path="$PRIMARY_DATA" \
restore

touch "$PRIMARY_DATA/recovery.signal"

#############################################
# Ensure pg_tde preload
#############################################
echo "Ensuring pg_tde preload"

cat >> "$PRIMARY_DATA/postgresql.auto.conf" <<EOF
shared_preload_libraries='pg_tde'
restore_command = '/usr/bin/pgbackrest --stanza=demo --config=/tmp/pgtest/pgbackrest.conf archive-get %f %p'
EOF

rm -f "$PRIMARY_DATA/postmaster.pid"

#############################################
# Start Patroni leader again
#############################################
echo "Starting Patroni leader after restore"

patroni "$PATRONI_NODE1/patroni.yml" \
> "$PATRONI_NODE1/patroni.log" 2>&1 &

#############################################
# Wait for leader
#############################################
patronictl -c "$PATRONI_NODE1/patroni.yml" resume qa-cluster
wait_for_patroni_leader

echo
echo "Verifying restored leader"

for i in {1..120}; do
    if patroni_psql 5432 -tAc "SELECT 1" >/dev/null 2>&1; then
        echo "PostgreSQL is ready"
        break
    fi

    if [ $i -eq 120 ]; then
        echo "PostgreSQL failed to become ready"
        tail -100 "$PATRONI_NODE1/patroni.log" || true
        exit 1
    fi

    sleep 2
done

patroni_psql 5432 -c "SELECT count(*) FROM t1;"

#############################################
# Observe replica recovery
#############################################
echo
echo "Waiting for replicas to reconnect"
sleep 30

echo
echo "Patroni cluster state"

patronictl -c "$PATRONI_NODE1/patroni.yml" list

echo
echo "Replication status on restored leader"

patroni_psql 5432 -c "
SELECT
application_name,
client_addr,
state,
sync_state,
sent_lsn,
replay_lsn
FROM pg_stat_replication;
"

echo
echo "Replica recovery status"

patroni_psql 5433 -c "
SELECT
pg_is_in_recovery(),
pg_last_wal_replay_lsn();
"

patroni_psql 5434 -c "
SELECT
pg_is_in_recovery(),
pg_last_wal_replay_lsn();
"
