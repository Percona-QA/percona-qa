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
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
port = $PORT_PRIMARY
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
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE TABLE t1(a int, b TEXT);"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES(101,'First Record before BaseBackup');"

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
$PG_BASEBACKUP -D "$REPLICA_DATA" -X stream -R -h localhost -p $PORT_PRIMARY -U $REPL_USER

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
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES(102,'Second Record after Streaming Replication');"

echo "=> Step 5: Promote replica"
echo "##########################"
rm -f $REPLICA_DATA/postgresql.auto.conf
$PG_CTL -D "$REPLICA_DATA" promote
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES(103,'Third Record after Replica Promotion causing Split Brain');"

echo "=>Step 6: Stop primary (simulate crash)"
echo "#######################################"
echo "Simulating primary crash..."
$PG_CTL -D "$PRIMARY_DATA" -m immediate stop
sleep 2

echo "=> Step 7: Rotate Server and Table Key"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key2','file_provider');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key3','file_provider');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT pg_tde_set_server_key_using_global_key_provider('key2','file_provider');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT pg_tde_set_key_using_global_key_provider('key3','file_provider');"

echo "=>Step 8: Use sysbench to generate WAL on promoted replica"
echo "##########################################################"
echo "Generating WAL with sysbench..."
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "INSERT INTO t1 VALUES(104,'Fourth Record Via PGRewind');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "CREATE TABLE rewind_test (id INT PRIMARY KEY, val TEXT);"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "INSERT INTO rewind_test VALUES (1, 'A'), (2, 'B'), (3,'C');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "UPDATE rewind_test SET val='C' where id=2;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "DELETE FROM rewind_test where id=3;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "TRUNCATE rewind_test;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "DROP TABLE rewind_test;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "CREATE TABLE alter_test (id int);"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "ALTER TABLE alter_test ADD COLUMN val text;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT pg_tde_is_encrypted('alter_test');"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "CREATE DATABASE mohit"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "DROP DATABASE mohit"

# Backing up the Original config file
cp $PRIMARY_DATA/postgresql.conf /tmp/postgresql_bk.conf
echo "=> Step 9: Rewind old primary"
echo "############################"
echo "Rewinding old primary..."
$PG_REWIND --target-pgdata="$PRIMARY_DATA" \
  --source-server="host=localhost port=$PORT_REPLICA user=$REPL_USER dbname=$DB_NAME"

# Restoring the Original config file
mv /tmp/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

echo "=> Step 10: Configure old primary as standby"
echo "###########################################"
touch $PRIMARY_DATA/standby.signal
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$PORT_REPLICA user=$REPL_USER password=$REPL_PASS'
EOF

echo "=> Step 11: Start rewound primary"
echo "################################"
$PG_CTL -D "$PRIMARY_DATA" -o "-p $PORT_PRIMARY" -l "$PRIMARY_LOGFILE" start
sleep 5

# Done
echo -e "\n✅ Old primary successfully rewound and rejoined as standby."
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM pg_stat_wal_receiver;"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT * FROM pg_stat_replication;"

$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT * FROM t1"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM t1"

# Tail logs
tail -10f "$PRIMARY_DATA/log/primary.log"
echo "######################################"
tail -10f "$REPLICA_DATA/log/replica.log"
