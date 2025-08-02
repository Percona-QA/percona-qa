#!/bin/bash

# Config paths
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
ARCHIVE_DIR=$INSTALL_DIR/wal_archive
PG_BACKUP_DIR=/var/lib/pgbackrest
LOG_DIR=$INSTALL_DIR/logs
CONFIG_DIR=$HOME/pgbackrest_conf
PG_BACKREST_CONFIG=$CONFIG_DIR/pgbackrest.conf

# Ports
PRIMARY_PORT=5432
REPLICA_PORT=5433

# Binaries
PG_CTL=$INSTALL_DIR/bin/pg_ctl
PSQL=$INSTALL_DIR/bin/psql
PG_BASEBACKUP=$INSTALL_DIR/bin/pg_basebackup
PG_REWIND=$INSTALL_DIR/bin/pg_rewind
INITDB=$INSTALL_DIR/bin/initdb
PGBACKREST=pgbackrest

# Cleanup
echo "Cleaning up old dirs..."
pkill -9 postgres || true
rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$ARCHIVE_DIR" "$PG_BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR"
mkdir -p "$ARCHIVE_DIR" "$PG_BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR"

# Step 1: Create pgBackRest config
echo "Creating pgBackRest config..."
cat > $PG_BACKREST_CONFIG <<EOF
[global]
repo1-path=$PG_BACKUP_DIR
log-level-console=info
log-level-file=debug
log-path=$LOG_DIR
start-fast=y
archive-async=n

[db]
pg1-path=$PRIMARY_DATA
pg1-port=$PRIMARY_PORT
pg1-socket-path=/tmp
EOF
export PGBACKREST_CONFIG=$PG_BACKREST_CONFIG

# Step 2: Initialize primary
echo "Initializing primary..."
$INITDB -D "$PRIMARY_DATA"

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
port = $PRIMARY_PORT
wal_level = replica
max_wal_senders = 5
archive_mode = on
archive_command = 'pgbackrest --stanza=db archive-push %p'
logging_collector = on
log_directory = '$LOG_DIR'
EOF

echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

# Step 3: Start primary and configure stanza
echo "Starting primary..."
$PG_CTL -D "$PRIMARY_DATA" -l "$LOG_DIR/primary.log" start
sleep 5

echo "Creating pgBackRest stanza..."
$PGBACKREST --stanza=db stanza-create


exit 1

# Step 4: Workload setup on primary
echo "Creating initial tables and data..."
$PSQL -p $PRIMARY_PORT -c "CREATE TABLE big_data (id serial PRIMARY KEY, data text);" postgres
$PSQL -p $PRIMARY_PORT -c "INSERT INTO big_data (data) SELECT repeat('x', 10000) FROM generate_series(1, 50000);" postgres

# Force WAL switch
$PSQL -p $PRIMARY_PORT -c "SELECT pg_switch_wal();" postgres
sleep 3

# Step 5: Take full backup
echo "Taking full pgBackRest backup..."
$PGBACKREST --stanza=db backup

# Step 6: Setup replica
echo "Setting up streaming replica..."
$PG_BASEBACKUP -D "$REPLICA_DATA" -Fp -Xs -P -R -p $PRIMARY_PORT -h 127.0.0.1
echo "port = $REPLICA_PORT" >> "$REPLICA_DATA/postgresql.conf"
echo "primary_conninfo = 'host=127.0.0.1 port=$PRIMARY_PORT user=postgres'" >> "$REPLICA_DATA/postgresql.auto.conf"

echo "Starting replica..."
$PG_CTL -D "$REPLICA_DATA" -l "$LOG_DIR/replica.log" start
sleep 5

# Step 7: More workload and simulate crash
echo "Writing more data..."
$PSQL -p $PRIMARY_PORT -c "INSERT INTO big_data (data) SELECT repeat('y', 10000) FROM generate_series(1, 20000);" postgres
TARGET_TIME=$($PSQL -p $PRIMARY_PORT -At -c "SELECT now();" postgres)
echo "Captured recovery target timestamp: $TARGET_TIME"

sleep 2
echo "Crashing primary..."
$PG_CTL -D "$PRIMARY_DATA" -m immediate stop

# Step 8: Restore from PITR using pgBackRest
echo "Restoring primary from PITR..."
rm -rf "$PRIMARY_DATA"
$PGBACKREST --stanza=db --target="time:${TARGET_TIME}" restore

echo "Configuring restored primary..."
echo "port = $PRIMARY_PORT" >> "$PRIMARY_DATA/postgresql.conf"
echo "restore_command = 'pgbackrest --stanza=db archive-get %f %p'" >> "$PRIMARY_DATA/postgresql.conf"

touch "$PRIMARY_DATA/recovery.signal"

echo "Starting recovered primary..."
$PG_CTL -D "$PRIMARY_DATA" -l "$LOG_DIR/primary_restored.log" start
sleep 5

# Step 9: Run pg_rewind on replica to sync with new timeline
echo "Rewinding replica..."
$PG_CTL -D "$REPLICA_DATA" -m immediate stop
$PG_REWIND -D "$REPLICA_DATA" --source-server="port=$PRIMARY_PORT user=postgres"
echo "primary_conninfo = 'host=127.0.0.1 port=$PRIMARY_PORT user=postgres'" > "$REPLICA_DATA/postgresql.auto.conf"

echo "Starting rewound replica..."
$PG_CTL -D "$REPLICA_DATA" -l "$LOG_DIR/replica_rewound.log" start
sleep 5

# Step 10: Validate data
echo "Validating data..."
$PSQL -p $PRIMARY_PORT -c "SELECT count(*) FROM big_data;" postgres
$PSQL -p $REPLICA_PORT -c "SELECT count(*) FROM big_data;" postgres

echo "✅ PITR + pgBackRest + pg_rewind + Streaming Replication test completed!"

