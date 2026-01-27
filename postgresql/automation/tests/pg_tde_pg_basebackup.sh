#!/bin/bash

# Setup paths and variables
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_TDE_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="/tmp/keyring.file"
SYSBENCH="$(command -v sysbench)"
SYSBENCH_TABLES=50
SYSBENCH_RECORDS=1000
THREADS=10

REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres
DB_USER=$(whoami)
export PGCTLTIMEOUT=300

# Define Functions

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating WAL key: wal_key_$RAND_KEY"
	$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('global_provider$RAND_KEY','${KEYFILE}_${RAND_KEY}');"
        $PSQL -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key_$RAND_KEY','global_provider${RAND_KEY}');"
        $PSQL -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key_$RAND_KEY','global_provider${RAND_KEY}');"
    done
}

rotate_table_key() {
  duration=$1
  end_time=$((SECONDS + duration))

  while [ $SECONDS -lt $end_time ]; do
	  RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
	  echo "Rotating Database master key: database_key_$RAND_KEY"
	  $PSQL -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_add_database_key_provider_file('local_provider$RAND_KEY','${KEYFILE}_${RAND_KEY}');"
	  $PSQL -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_database_key_provider('database_key$RAND_KEY','local_provider$RAND_KEY');"
	  $PSQL -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_key_using_database_key_provider('database_key$RAND_KEY','local_provider$RAND_KEY');"
  done
}

# Actual test begins here...

# Clean slate
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
rm -f $KEYFILE

echo "Step 1: Init Primary Server"
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

# Configure Primary Server
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
wal_level = replica
wal_compression = on
wal_log_hints = on
wal_keep_size = 512MB
max_replication_slots = 2
max_wal_senders = 2
EOF


echo "Step 2: Start Primary Server"
start_pg $PRIMARY_DATA $PRIMARY_PORT

$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('global_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_add_database_key_provider_file('local_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_database_key_provider('table_key','local_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_set_key_using_database_key_provider('table_key','local_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

# Restart Primary Server (to enable WAL encryption)
restart_pg $PRIMARY_DATA $PRIMARY_PORT

# Create replication user
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

# Create tables
$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PRIMARY_PORT \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS \
  /usr/share/sysbench/oltp_write_only.lua prepare

echo "=> Rotate Keys and Run Load in Parallel while pg_tde_basebackup takes backup of primary server"
rotate_wal_key 60 > $RUN_DIR/rotate_wal.log 2>&1 &
rotate_table_key 60 > $RUN_DIR/rotate_table.log 2>&1 &

$SYSBENCH --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=$PRIMARY_PORT \
  --pgsql-user=$DB_USER --pgsql-db=$DB_NAME \
  --threads=$THREADS --tables=$SYSBENCH_TABLES --table-size=$SYSBENCH_RECORDS --time=60 --report-interval=5 \
  /usr/share/sysbench/oltp_write_only.lua run > /tmp/sysbench_run.log 2>&1 &

echo "Sleeping for 2 seconds"
sleep 2

echo "Step 3: Take Base Backup for Replica Server"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R $PRIMARY_DATA/pg_tde $REPLICA_DATA/
$PG_TDE_BASEBACKUP -D "$REPLICA_DATA" -X stream -E -R -h localhost -p $PRIMARY_PORT -U $REPL_USER

# Configure Replica Server
write_postgresql_conf "$REPLICA_DATA" "$REPLICA_PORT" "replica"
enable_pg_tde $REPLICA_DATA
rm -f $REPLICA_DATA/server.log

echo "# Step 4: Start Replica Server"
start_pg $REPLICA_DATA $REPLICA_PORT

echo "# Step 5: Verify Data on both Primary and Replica Server"

tables=$($PSQL -t -A -p $PRIMARY_PORT -d $DB_NAME -c \
  "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'sbtest%';")

mismatch=0

for tbl in $tables; do
    cnt_primary=$($PSQL -t -A -p $PRIMARY_PORT -d $DB_NAME -c "SELECT COUNT(*) FROM $tbl;")
    cnt_secondary=$($PSQL -t -A -p $REPLICA_PORT -d $DB_NAME -c "SELECT COUNT(*) FROM $tbl;")

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
