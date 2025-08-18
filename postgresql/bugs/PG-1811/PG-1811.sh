#!/bin/bash

# Setup paths and variables
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_REWIND="$INSTALL_DIR/bin/pg_rewind"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
SYSBENCH="/usr/bin/sysbench"
SYSBENCH_TABLES=1000
SYSBENCH_RECORDS=1000
THREADS=10
export PGCTLTIMEOUT=600

PORT_PRIMARY=5433
PORT_REPLICA=5434
REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres
DB_USER=$(whoami)

# Clean slate
pkill -9 postgres
rm -rf "$PRIMARY_DATA" "$REPLICA_DATA"
rm -rf /tmp/primary_keyfile

# Step 1: Init primary
$INSTALL_DIR/bin/initdb -D "$PRIMARY_DATA"

# Configure primary
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
port = $PORT_PRIMARY
wal_level = replica
wal_log_hints = on
wal_keep_size = 2048MB
max_replication_slots = 2
max_wal_senders = 10
listen_addresses = 'localhost'
logging_collector = on
log_directory = 'log'
log_filename = 'primary.log'
EOF

echo "host replication $REPL_USER 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

echo "=> Step 1: Start primary"
echo "#########################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 3
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','/tmp/primary_keyfile');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_provider');"
#$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart primary
#$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" restart
#sleep 3

# Create replication user
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
$PG_BASEBACKUP -D "$REPLICA_DATA" -X stream -R -h localhost -p $PORT_PRIMARY -U $REPL_USER

# Configure replica
cat > "$REPLICA_DATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
port = $PORT_REPLICA
hot_standby = on
logging_collector = on
log_directory = 'log'
log_filename = 'replica.log'
wal_keep_size=1024MB
max_wal_senders = 10
EOF

echo "=>Step 3: Start replica"
echo "########################"
$PG_CTL -D "$REPLICA_DATA" -o "-p $PORT_REPLICA" -l "$REPLICA_LOGFILE" start
sleep 5
#$PSQL -p $PORT_REPLICA -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart replica
#$PG_CTL -D "$REPLICA_DATA" -o "-p $PORT_REPLICA" -l "$REPLICA_LOGFILE" restart
#sleep 5

echo "=>Step 3: Stop primary (simulate crash)"
echo "#######################################"
echo "Simulating primary crash..."
$PG_CTL -D "$PRIMARY_DATA" -m immediate stop

echo "=> Step 4: Promote replica"
echo "##########################"
rm -f $REPLICA_DATA/postgresql.auto.conf
$PG_CTL -D "$REPLICA_DATA" promote
sleep 5

echo "=>Step 6: Use sysbench to generate WAL on promoted replica"
echo "##########################################################"
echo "Generating WAL with sysbench..."
$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_REPLICA \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS \
  /usr/share/sysbench/oltp_write_only.lua prepare

$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_REPLICA \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS --time=200 --report-interval=5 \
  /usr/share/sysbench/oltp_write_only.lua run

# Backing up the Original config file
cp $PRIMARY_DATA/postgresql.conf /tmp/postgresql_bk.conf
echo "=> Step 7: Rewind old primary"
echo "############################"
echo "Rewinding old primary..."
$PG_REWIND --target-pgdata="$PRIMARY_DATA" \
  --source-server="host=localhost port=$PORT_REPLICA user=$REPL_USER dbname=$DB_NAME"

# Restoring the Original config file
mv /tmp/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

echo "=> Step 8: Configure old primary as standby"
echo "###########################################"
touch $PRIMARY_DATA/standby.signal
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$PORT_REPLICA user=$REPL_USER password=$REPL_PASS'
EOF

echo "=> Step 9: Start rewound primary"
echo "################################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start

# Wait until PostgreSQL is ready
echo "Waiting for PostgreSQL to become available on port $PORT_PRIMARY..."
until $INSTALL_DIR/bin/pg_isready -p $PORT_PRIMARY -d $DB_NAME -q; do
    sleep 1
done

# Done
echo -e "\n✅ Old primary successfully rewound and rejoined as standby."
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM pg_stat_wal_receiver;"

# Tail logs
tail -n 10 "$PRIMARY_DATA/log/primary.log"
