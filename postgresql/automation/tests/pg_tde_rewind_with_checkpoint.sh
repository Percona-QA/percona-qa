#!/bin/bash

# Binaries
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PSQL="$INSTALL_DIR/bin/psql"

# Directories
KEYFILE="/tmp/keyring.file"
SYSBENCH=$(command -v sysbench)

echo "Cleaning old directories"
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
rm -rf $KEYFILE || true

#######################################
# Step 1: Initialize primary
#######################################
echo "Initializing primary"

initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

echo "wal_level=replica" >> $PRIMARY_DATA/postgresql.conf
echo "archive_mode=on" >> $PRIMARY_DATA/postgresql.conf
echo "archive_command='cp %p $ARCHIVE_DIR/%f'" >> $PRIMARY_DATA/postgresql.conf
echo "restore_command='cp $ARCHIVE_DIR/%f %p'" >> $PRIMARY_DATA/postgresql.conf

echo "host replication all 127.0.0.1/32 trust" >> $PRIMARY_DATA/pg_hba.conf

start_pg $PRIMARY_DATA $PRIMARY_PORT

$PSQL -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"
# Restart primary
restart_pg $PRIMARY_DATA $PRIMARY_PORT

#######################################
# Step 2: Create replica via basebackup
#######################################
echo "Creating replica using pg_basebackup"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R $PRIMARY_DATA/pg_tde $REPLICA_DATA/
$PG_BASEBACKUP -D $REPLICA_DATA -R -X stream -c fast -E -h localhost -p $PRIMARY_PORT

cat > $REPLICA_DATA/postgresql.conf <<EOF
port=$REPLICA_PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
io_method = '$IO_METHOD'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
max_wal_senders=10
restore_command='cp $ARCHIVE_DIR/%f %p'
EOF

start_pg $REPLICA_DATA $REPLICA_PORT


#######################################
# Step 3: Create table on primary
#######################################
echo "Creating table and inserting data on primary"
$SYSBENCH /usr/share/sysbench/oltp_insert.lua --pgsql-user=$(whoami) --pgsql-db=postgres --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=100 --table-size=1000 prepare
$PSQL -p $PRIMARY_PORT -d postgres -c "CREATE TABLE t1(id INT) USING tde_heap;"
$PSQL -p $PRIMARY_PORT -d postgres -c "INSERT INTO t1 VALUES (1),(2),(3);"

echo "Checkpoint on primary"
$PSQL -p $PRIMARY_PORT -d postgres -c "CHECKPOINT;"

#######################################
# Step 4: Promote replica
#######################################
echo "Promoting replica"

$PG_CTL -D $REPLICA_DATA promote
sleep 3

#######################################
# Step 5: Diverging writes on replica
#######################################
echo "Inserting more data on promoted replica"

$PSQL -p $REPLICA_PORT -d postgres -c "INSERT INTO t1 VALUES (4),(5),(6);"
$SYSBENCH /usr/share/sysbench/oltp_read_write.lua --pgsql-user=$(whoami) --pgsql-db=postgres --db-driver=pgsql --pgsql-port=$REPLICA_PORT --threads=5 --tables=100 --time=60 --report-interval=10 run

#######################################
# Step 6: Shutdown both
#######################################
echo "Stopping primary and replica"

$PG_CTL -D $PRIMARY_DATA stop -m fast
$PG_CTL -D $REPLICA_DATA stop -m fast

cp $PRIMARY_DATA/postgresql.conf $RUN_DIR/
#######################################
# Step 7: Run pg_rewind
#######################################
echo "Running pg_rewind"

$PG_REWIND \
  --target-pgdata=$PRIMARY_DATA \
  --source-pgdata=$REPLICA_DATA -c

cp $RUN_DIR/postgresql.conf $PRIMARY_DATA/postgresql.conf

#######################################
# Step 8: Start rewound primary
#######################################
echo "Starting rewound primary"

start_pg $PRIMARY_DATA $PRIMARY_PORT

#######################################
# Step 9: Verify data
#######################################
echo "Querying table randomly after rewind"
for i in {1..10}; do
  RANDOM_TABLE=$((RANDOM % 100 + 1))
  COUNT=$($PSQL -p $PRIMARY_PORT -d postgres -At -c "SELECT count(*) FROM sbtest${RANDOM_TABLE};")
  if [ "$COUNT" -lt 0 ]; then
    echo "FAIL: sbtest$RANDOM_TABLE count $COUNT < 0"
    exit 1
  fi
done

echo "Test completed"
