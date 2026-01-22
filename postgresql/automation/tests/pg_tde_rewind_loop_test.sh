#!/bin/bash

# Config paths
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_TDE_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PG_TDE_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
SYSBENCH="$(command -v sysbench)"

REPL_USER=repl_user
REPL_PASS=repl_pswd
DB_NAME=postgres

KEYFILE=/tmp/primary_keyfile
KEY_NAME=key1

# Clean slate
pkill -9 postgres || true
rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$KEYFILE"

# Initialize both nodes
initialize_server "$PRIMARY_DATA" "$PRIMARY_PORT"

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
wal_level = replica
wal_compression = on
wal_log_hints = on
wal_keep_size = 512MB
max_replication_slots = 2
max_wal_senders = 2
hot_standby = on
EOF

echo "host replication $REPL_USER 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

# Enable pg_tde
enable_pg_tde $PRIMARY_DATA

# Start node 1 as initial primary
start_pg $PRIMARY_DATA $PRIMARY_PORT

# Setup TDE and WAL encryption
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME','file_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME','file_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

# Restart node 1 to enable WAL encryption
restart_pg $PRIMARY_DATA $PRIMARY_PORT

# Setup repl user and table
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE TABLE verify_table( id bigserial PRIMARY KEY, ts timestamptz, source text );"

# Take basebackup for Replica Node
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R $PRIMARY_DATA/pg_tde $REPLICA_DATA
$PG_TDE_BASEBACKUP -D "$REPLICA_DATA" -X stream -E -R -h localhost -p $PRIMARY_PORT -U $REPL_USER

# Configure replica
cat > "$REPLICA_DATA/postgresql.conf" <<EOF
port = $REPLICA_PORT
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
unix_socket_directories = '$RUN_DIR'
io_method = 'sync'
hot_standby = on
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
wal_level = replica
wal_log_hints = on
wal_compression = on
wal_keep_size= 512MB
max_wal_senders = 2
EOF

# Start node 2 as Replica
start_pg $REPLICA_DATA $REPLICA_PORT
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

# Restart replica server to enable WAL encryption
restart_pg $REPLICA_DATA $REPLICA_PORT

$SYSBENCH /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$PRIMARY_PORT \
  --pgsql-user=$USER \
  --pgsql-db=$DB_NAME \
  --db-driver=pgsql \
  --time=40 --threads=5 --tables=100 --table-size=1000 prepare

# Helper to run sysbench on a port
run_sysbench() {
  local port=$1
  $SYSBENCH /usr/share/sysbench/oltp_insert.lua \
    --pgsql-host=localhost \
    --pgsql-port=$port \
    --pgsql-user=$USER \
    --pgsql-db=$DB_NAME \
    --db-driver=pgsql \
    --time=40 --threads=2 --tables=1 --table-size=1000 run
}

# Failover and rewind logic
failover_iteration() {
  local current_primary_dir=$1
  local current_primary_port=$2
  local standby_dir=$3
  local standby_port=$4

  echo "Starting sysbench workload on port $current_primary_port..."
  run_sysbench $current_primary_port &
  sleep 30

  echo "Simulating crash on $current_primary_port..."
  $PG_CTL -D "$current_primary_dir" -m immediate stop

  echo "Promoting standby on port $standby_port..."
  rm -f "$standby_dir/postgresql.auto.conf"
  $PG_CTL -D "$standby_dir" promote
  sleep 5
  $PSQL -p $standby_port -d $DB_NAME -c "INSERT INTO verify_table(ts, source) VALUES (clock_timestamp(), 'post_promotion');"
  run_sysbench $standby_port &
  sleep 30

  echo "Rewinding old primary..."
  cp "$current_primary_dir/postgresql.conf" $RUN_DIR/postgresql_bk.conf
  $PG_TDE_REWIND --target-pgdata="$current_primary_dir" \
    --source-server="host=localhost port=$standby_port user=$REPL_USER dbname=$DB_NAME"

  mv $RUN_DIR/postgresql_bk.conf "$current_primary_dir/postgresql.conf"
  touch "$current_primary_dir"/standby.signal
  echo "primary_conninfo = 'host=localhost port=$standby_port user=$REPL_USER password=$REPL_PASS'" >> "$current_primary_dir/postgresql.conf"

  # Starting old primary as standby
  start_pg $current_primary_dir $current_primary_port

  # Wait for receiver to connect
  echo "Waiting for WAL receiver to be active..."
  timeout 30 bash -c "
    until $PSQL -p $current_primary_port -d $DB_NAME -Atc \"SELECT status FROM pg_stat_wal_receiver\" | grep -q streaming; do
      sleep 1
  done"

  echo "Streaming active. Sleeping for apply..."
  sleep 5
  
  # Verification
  echo "Verifying replicated data..."
  local standby_markers=$($PSQL -p "$standby_port" -d "$DB_NAME" -Atc \
    "SELECT count(*) FROM verify_table WHERE source='post_promotion';")

  local rewound_markers=$($PSQL -p "$current_primary_port" -d "$DB_NAME" -Atc \
    "SELECT count(*) FROM verify_table WHERE source='post_promotion';")

  echo "Markers on promoted primary: $standby_markers"
  echo "Markers on rewound primary: $rewound_markers"

  if [[ "$standby_markers" -eq "$rewound_markers" ]]; then
    echo "PG rewind replication verification successful."
  else
    echo "PG rewind replication failed! Divergence detected."
    exit 1
  fi
}

# Loop: Alternate roles
for i in {1..3}; do
  echo -e "\n=================== Iteration $i ==================="
  if (( $i % 2 == 1 )); then
    failover_iteration "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"
  else
    failover_iteration "$REPLICA_DATA" "$REPLICA_PORT" "$PRIMARY_DATA" "$PRIMARY_PORT"
  fi
done

echo "✅ Test complete"
