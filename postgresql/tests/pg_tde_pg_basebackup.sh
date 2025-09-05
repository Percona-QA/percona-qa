#!/bin/bash

# Setup paths and variables
INSTALL_DIR=$HOME/postgresql/bld_17.6/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
SECONDARY_DATA=$INSTALL_DIR/secondary_data
PRIMARY_LOGFILE=$PRIMARY_DATA/primary.log
SECONDARY_LOGFILE=$SECONDARY_DATA/secondary.log
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="/tmp/keyring.file"
SYSBENCH="/usr/bin/sysbench"
SYSBENCH_TABLES=50
SYSBENCH_RECORDS=1000
THREADS=10

PORT_PRIMARY=5432
PORT_SECONDARY=5433
REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres
DB_USER=$(whoami)
export PGCTLTIMEOUT=300

# Clean slate
pkill -9 postgres

echo "Removing Previous Data Directory..."
rm -rf "$PRIMARY_DATA" "$SECONDARY_DATA"
rm -f /tmp/keyring.file*
rm -f /tmp/*.log

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
        echo "Rotating WAL key: wal_key_$RAND_KEY"
	$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('global_provider$RAND_KEY','${KEYFILE}_${RAND_KEY}');"
        $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key_$RAND_KEY','global_provider${RAND_KEY}');"
        $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key_$RAND_KEY','global_provider${RAND_KEY}');"
    done
}

rotate_table_key() {
  duration=$1
  end_time=$((SECONDS + duration))

  while [ $SECONDS -lt $end_time ]; do
	  RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
	  echo "Rotating Database master key: database_key_$RAND_KEY"
	  $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_add_database_key_provider_file('local_provider$RAND_KEY','${KEYFILE}_${RAND_KEY}');"
	  $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_create_key_using_database_key_provider('database_key$RAND_KEY','local_provider$RAND_KEY');"
	  $PSQL -d $DB_NAME -p $PORT_PRIMARY -c "SELECT pg_tde_set_key_using_database_key_provider('database_key$RAND_KEY','local_provider$RAND_KEY');"
  done
}

echo "=> Step 1: Start primary"
echo "#########################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 3
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('global_provider','$KEYFILE');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_database_key_provider_file('local_provider','$KEYFILE');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_create_key_using_database_key_provider('table_key','local_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_key_using_database_key_provider('table_key','local_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
#Restart primary
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" restart
sleep 3

# Create replication user
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

# Create tables
$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_PRIMARY \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS \
  /usr/share/sysbench/oltp_write_only.lua prepare

echo "=> Rotate Keys and Run Load in Parallel while pg_basebackup takes backup of primary server"
rotate_wal_key 60 > //tmp/rotate_wal.log 2>&1 &
rotate_table_key 60 > /tmp/rotate_table.log 2>&1 &

$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PORT_PRIMARY \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS --time=60 --report-interval=5 \
  /usr/share/sysbench/oltp_write_only.lua run > /tmp/sysbench_run.log 2>&1 &

echo "Sleeping for 2 seconds"
sleep 2

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
mkdir $SECONDARY_DATA
chmod 700 $SECONDARY_DATA
cp -R $PRIMARY_DATA/pg_tde $SECONDARY_DATA/
$PG_BASEBACKUP -D "$SECONDARY_DATA" -X stream -R -E -h localhost -p $PORT_PRIMARY -U $REPL_USER

echo "=> Step 3: Start Secondary Server"
echo "################################"
# Configure secondary
cat >> "$SECONDARY_DATA/postgresql.conf" <<EOF
port = $PORT_SECONDARY
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
log_filename = 'secondary.log'
EOF
rm -f $SECONDARY_DATA/log/primary.log
$PG_CTL -D "$SECONDARY_DATA" -o "-p $PORT_SECONDARY" -l "$SECONDARY_LOGFILE" start

echo "=> Step 4: Verify Data on both Primary and Secondary Server"
echo "###########################################################"

tables=$($PSQL -t -A -p $PORT_PRIMARY -d $DB_NAME -c \
  "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'sbtest%';")

mismatch=0

for tbl in $tables; do
    cnt_primary=$($PSQL -t -A -p $PORT_PRIMARY -d $DB_NAME -c "SELECT COUNT(*) FROM $tbl;")
    cnt_secondary=$($PSQL -t -A -p $PORT_SECONDARY -d $DB_NAME -c "SELECT COUNT(*) FROM $tbl;")

    echo "Table: $tbl | Primary: $cnt_primary | Secondary: $cnt_secondary"

    if [ "$cnt_primary" != "$cnt_secondary" ]; then
        echo "Row count mismatch for table $tbl"
        mismatch=1
	break
    fi
done

if [ $mismatch -ne 0 ]; then
    echo "Replication validation failed: row counts do not match."
    exit 1
else
    echo "All table row counts match between primary and secondary."
fi



