#!/bin/bash

# Setup paths and variables
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_TDE_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PG_TDE_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
SYSBENCH="/usr/bin/sysbench"

PORT_PRIMARY=5432
PORT_REPLICA=5433
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

echo "host replication $REPL_USER 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

echo "=> Step 1: Start primary"
echo "#########################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 3
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','/tmp/primary_keyfile');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart primary
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" restart
sleep 3

# Create replication user
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

# Create tables
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE TABLE t1(id INT, name TEXT);"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES(101,'First Record Before BaseBackup');"

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
$PG_TDE_BASEBACKUP -D "$REPLICA_DATA" -X stream -R -h localhost -p $PORT_PRIMARY -U $REPL_USER

# Configure replica
cat > "$REPLICA_DATA/postgresql.conf" <<EOF
port = $PORT_REPLICA
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
hot_standby = on
logging_collector = on
log_directory = 'log'
log_filename = 'replica.log'
wal_level = replica
wal_compression = on
wal_keep_size= 512MB
max_wal_senders = 2
EOF

echo "=>Step 3: Start replica"
echo "########################"
$PG_CTL -D "$REPLICA_DATA" -o "-p $PORT_REPLICA" -l "$REPLICA_LOGFILE" start
sleep 5
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart replica
$PG_CTL -D "$REPLICA_DATA" -o "-p $PORT_REPLICA" -l "$REPLICA_LOGFILE" restart
sleep 5

echo "=>Step 4: Generate some WAL on primary"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES (102, 'Second Record After Setting Streaming Replication');"

$PG_CTL -D "$PRIMARY_DATA" -m immediate stop
sleep 3

echo "=> Step 5: Promote replica"
echo "##########################"
# Remove auto conf file which was created by pg_tde_basebackup
rm -f $REPLICA_DATA/postgresql.auto.conf
$PG_CTL -D "$REPLICA_DATA" promote

echo "=>Step 6: Use sysbench to generate WAL on promoted replica"
echo "##########################################################"
echo "Generating WAL with sysbench..."
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "INSERT INTO t1 VALUES(103,'Third Record Replicated Via PgRewind');"

# Backing up the Original config file
cp $PRIMARY_DATA/postgresql.conf /tmp/postgresql_bk.conf
echo "=> Step 8: Rewind old primary"
echo "############################"
echo "Rewinding old primary..."
$PG_TDE_REWIND --target-pgdata="$PRIMARY_DATA" \
  --source-server="host=localhost port=$PORT_REPLICA user=$REPL_USER dbname=$DB_NAME"

# Restoring the Original config file
cp /tmp/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

echo "=> Step 9: Configure old primary as standby"
echo "###########################################"
touch $PRIMARY_DATA/standby.signal
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$PORT_REPLICA user=$REPL_USER password=$REPL_PASS'
EOF

echo "=> Step 10: Start rewound primary"
echo "################################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 5

# Validate data on both servers
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM t1"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT * FROM t1"

tail -n 10 $PRIMARY_DATA/log/primary.log
