#!/bin/bash

# Config paths
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_TDE_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PG_TDE_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
SYSBENCH="/usr/bin/sysbench"

DATA_A=$INSTALL_DIR/data_A
DATA_B=$INSTALL_DIR/data_B
LOG_A=$DATA_A/server.log
LOG_B=$DATA_B/server.log
PORT_A=5432
PORT_B=5433
REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres

KEYFILE=/tmp/primary_keyfile
KEY_NAME=key1

# Clean slate
pkill -9 postgres || true
rm -rf "$DATA_A" "$DATA_B" "$KEYFILE"

# Initialize both nodes
init_node() {
  local dir=$1
  local port=$2
  $INSTALL_DIR/bin/initdb -D "$dir"
  cat >> "$dir/postgresql.conf" <<EOF
port = $port
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
io_method = 'sync'
wal_level = replica
wal_compression = on
wal_log_hints = on
wal_keep_size = 512MB
max_replication_slots = 2
max_wal_senders = 2
hot_standby = on
listen_addresses = 'localhost'
logging_collector = on
log_directory = 'log'
log_filename = 'primary.log'
EOF
  echo "host replication $REPL_USER 127.0.0.1/32 trust" >> "$dir/pg_hba.conf"
  echo "host all all 127.0.0.1/32 trust" >> "$dir/pg_hba.conf"
}

init_node "$DATA_A" "$PORT_A"

# Start A as initial primary
$PG_CTL -D "$DATA_A" -o "-p $PORT_A" -l "$LOG_A" start
sleep 3

# Setup TDE and WAL encryption
$PSQL -p $PORT_A -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT_A -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PORT_A -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME','file_provider');"
$PSQL -p $PORT_A -d $DB_NAME -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME','file_provider');"
$PSQL -p $PORT_A -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
$PG_CTL -D "$DATA_A" -o "-p $PORT_A" -l "$LOG_A" restart
sleep 2

# Setup repl user and table
$PSQL -p $PORT_A -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"
$PSQL -p $PORT_A -d $DB_NAME -c "CREATE TABLE t1(id INT, val TEXT);"

# Take basebackup for B
$PG_TDE_BASEBACKUP -D "$DATA_B" -X stream -E -R -h localhost -p $PORT_A -U $REPL_USER

# Configure replica
cat > "$DATA_B/postgresql.conf" <<EOF
port = $PORT_B
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
io_method = 'sync'
hot_standby = on
logging_collector = on
log_directory = 'log'
log_filename = 'replica.log'
wal_level = replica
wal_log_hints = on
wal_compression = on
wal_keep_size= 512MB
max_wal_senders = 2
EOF

# Start B as replica
$PG_CTL -D "$DATA_B" -o "-p $PORT_B" -l "$LOG_B" start
sleep 5
$PSQL -p $PORT_B -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
$PG_CTL -D "$DATA_B" -o "-p $PORT_B" -l "$LOG_B" restart
sleep 2
$SYSBENCH /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$PORT_A \
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

  echo "👉 Starting sysbench workload on port $current_primary_port..."
  run_sysbench $current_primary_port &
  sleep 30

  echo "❌ Simulating crash on $current_primary_port..."
  $PG_CTL -D "$current_primary_dir" -m immediate stop

  echo "⬆️ Promoting standby on port $standby_port..."
  rm -f "$standby_dir/postgresql.auto.conf"
  $PG_CTL -D "$standby_dir" promote
  sleep 5
  run_sysbench $standby_port &
  sleep 30

  echo "🔁 Rewinding old primary..."
  cp "$current_primary_dir/postgresql.conf" /tmp/postgresql_bk.conf
  $PG_TDE_REWIND --target-pgdata="$current_primary_dir" \
    --source-server="host=localhost port=$standby_port user=$REPL_USER dbname=$DB_NAME"

  cp /tmp/postgresql_bk.conf "$current_primary_dir/postgresql.conf"
  touch "$current_primary_dir"/standby.signal
  echo "primary_conninfo = 'host=localhost port=$standby_port user=$REPL_USER password=$REPL_PASS'" >> "$current_primary_dir/postgresql.conf"

  $PG_CTL -D "$current_primary_dir" -o "-p $current_primary_port" -l "$current_primary_dir/server.log" start
  sleep 5

  $PSQL -p $current_primary_port -d $DB_NAME -c "SELECT COUNT(*) FROM sbtest1;"
  $PSQL -p $standby_port -d $DB_NAME -c "SELECT COUNT(*) FROM sbtest1;"

  $PSQL -p $current_primary_port -d $DB_NAME -c "SELECT * FROM pg_stat_wal_receiver;"
  $PSQL -p $standby_port -d $DB_NAME -c "SELECT * FROM pg_stat_replication;"
}

# Loop: Alternate roles
for i in {1..3}; do
  echo -e "\n=================== Iteration $i ==================="
  if (( $i % 2 == 1 )); then
    failover_iteration "$DATA_A" "$PORT_A" "$DATA_B" "$PORT_B"
  else
    failover_iteration "$DATA_B" "$PORT_B" "$DATA_A" "$PORT_A"
  fi
done

echo "✅ Test complete"
