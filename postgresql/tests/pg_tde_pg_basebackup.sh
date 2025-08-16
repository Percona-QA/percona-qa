#!/bin/bash

# Setup paths and variables
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
SECONDARY_DATA=$INSTALL_DIR/secondary_data
PRIMARY_LOGFILE=$PRIMARY_DATA/primary.log
SECONDARY_LOGFILE=$SECONDARY_DATA/secondary.log
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="/tmp/keyring.file"
SYSBENCH="/usr/bin/sysbench"
SYSBENCH_TABLES=500
SYSBENCH_RECORDS=1000
THREADS=10

PORT_PRIMARY=5432
PORT_SECONDARY=5433
REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres
DB_USER=$(whoami)

# Clean slate
pkill -9 postgres
rm -rf "$PRIMARY_DATA" "$SECONDARY_DATA" $KEYFILE

# Step 1: Init primary
$INSTALL_DIR/bin/initdb -D "$PRIMARY_DATA"

# Configure primary
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
port = $PORT_PRIMARY
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level = replica
wal_compression = on
wal_log_hints = on
wal_keep_size = 512MB
max_replication_slots = 2
max_wal_senders = 2
listen_addresses = 'localhost'
logging_collector = on
log_directory = 'log'
log_filename = 'primary.log'
EOF

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating Global master key: principal_key_test$RAND_KEY"
        $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','file_provider');"
        $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','file_provider');"
    done
}

echo "=> Step 1: Start primary"
echo "#########################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 3
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"
#$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
#Restart primary
#$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" restart
#sleep 3

# Create replication user
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

# Create tables
$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_PRIMARY \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS \
  /usr/share/sysbench/oltp_write_only.lua prepare > /dev/null 2>&1 &

rotate_wal_key 10 &

echo "Sleeping for 5 seconds"
sleep 2

#$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_REPLICA \
#  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
#  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS --time=200 --report-interval=5 \
#  /usr/share/sysbench/oltp_write_only.lua run

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
$PG_BASEBACKUP -D "$SECONDARY_DATA" -X stream -R -h localhost -p $PORT_PRIMARY -U $REPL_USER


echo "=>Step 3: Start Secondary Server"
echo "########################"
$PG_CTL -D "$SECONDARY_DATA" -o "-p $PORT_SECONDARY" -l "$SECONDARY_LOGFILE" start
