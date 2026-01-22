#!/bin/bash

# Setup paths and variables
PG_TDE_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
PG_TDE_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="$RUN_DIR/primary_keyfile"

REPL_USER=repl_user
REPL_PASS=repl_pass
DB_NAME=postgres
DB_USER=$(whoami)

# Wiping all previous server data
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
rm -rf $KEYFILE

# Step 1: Init primary
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

echo "host replication $REPL_USER 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"

echo "=> Step 1: Start primary"
echo "#########################"
start_pg $PRIMARY_DATA $PRIMARY_PORT
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart primary
restart_pg $PRIMARY_DATA $PRIMARY_PORT

# Create replication user
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

# Create tables
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "CREATE TABLE t1(a int, b TEXT);"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "INSERT INTO t1 VALUES(101,'First Record before BaseBackup');"

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
mkdir $REPLICA_DATA
chmod 700 $REPLICA_DATA
cp -R $PRIMARY_DATA/pg_tde $REPLICA_DATA/
$PG_TDE_BASEBACKUP -D "$REPLICA_DATA" -X stream -E -R -h localhost -p $PRIMARY_PORT -U $REPL_USER

# Configure replica
cat > "$REPLICA_DATA/postgresql.conf" <<EOF
port = $REPLICA_PORT
unix_socket_directories = '$RUN_DIR'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
hot_standby = on
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
wal_level = replica
wal_compression = on
wal_keep_size= 512MB
max_wal_senders = 2
EOF

echo "=>Step 3: Start replica"
echo "########################"
start_pg $REPLICA_DATA $REPLICA_PORT
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
# Restart replica
restart_pg $REPLICA_DATA $REPLICA_PORT

echo "=>Step 4: Generate some WAL on primary"
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "INSERT INTO t1 VALUES(102,'Second Record after Streaming Replication');"

echo "=> Step 5: Promote replica"
echo "##########################"
rm -f $REPLICA_DATA/postgresql.auto.conf
$INSTALL_DIR/bin/pg_ctl -D "$REPLICA_DATA" promote
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "INSERT INTO t1 VALUES(103,'Third Record after Replica Promotion causing Split Brain');"

echo "=>Step 6: Stop primary (simulate crash)"
echo "#######################################"
echo "Simulating primary crash..."
$INSTALL_DIR/bin/pg_ctl -D "$PRIMARY_DATA" -m immediate stop
sleep 2

echo "=> Step 7: Rotate Server and Table Key"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key2','file_provider');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT pg_tde_create_key_using_global_key_provider('key3','file_provider');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT pg_tde_set_server_key_using_global_key_provider('key2','file_provider');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT pg_tde_set_key_using_global_key_provider('key3','file_provider');"

echo "=>Step 8: Generate WAL on promoted replica"
echo "##########################################################"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "INSERT INTO t1 VALUES(104,'Fourth Record Via PGRewind');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "CREATE TABLE rewind_test (id INT PRIMARY KEY, val TEXT);"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "INSERT INTO rewind_test VALUES (1, 'A'), (2, 'B'), (3,'C');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "UPDATE rewind_test SET val='C' where id=2;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "DELETE FROM rewind_test where id=3;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "TRUNCATE rewind_test;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "DROP TABLE rewind_test;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "CREATE TABLE alter_test (id int);"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "ALTER TABLE alter_test ADD COLUMN val text;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT pg_tde_is_encrypted('alter_test');"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "CREATE DATABASE mohit"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "DROP DATABASE mohit"

# Backing up the Original config file
cp $PRIMARY_DATA/postgresql.conf /tmp/postgresql_bk.conf
echo "=> Step 9: Rewind old primary"
echo "############################"
echo "Rewinding old primary..."
$PG_TDE_REWIND --target-pgdata="$PRIMARY_DATA" \
  --source-server="host=localhost port=$REPLICA_PORT user=$REPL_USER dbname=$DB_NAME"

# Restoring the Original config file
mv /tmp/postgresql_bk.conf $PRIMARY_DATA/postgresql.conf

echo "=> Step 10: Configure old primary as standby"
echo "###########################################"
touch $PRIMARY_DATA/standby.signal
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$REPLICA_PORT user=$REPL_USER password=$REPL_PASS'
EOF

echo "=> Step 11: Start rewound primary"
echo "################################"
start_pg $PRIMARY_DATA $PRIMARY_PORT

# Done
echo -e "\n✅ Old primary successfully rewound and rejoined as standby."
$PSQL -p $PRIMARY_PORT -d $DB_NAME -c "SELECT * FROM pg_stat_wal_receiver;"
$PSQL -p $REPLICA_PORT -d $DB_NAME -c "SELECT * FROM pg_stat_replication;"

$PSQL -p $REPLICA_PORT -d $DB_NAME -c "INSERT INTO t1 VALUES(105,'New Data from New Primary');"
sleep 2
COUNT=$($PSQL -p $PRIMARY_PORT -d $DB_NAME -t -A -c "SELECT count(*) FROM t1 WHERE a = 105")

if [ "$COUNT" -eq 1 ]; then
    echo "Replication is working!"
else
    echo "ERROR:Replication Failed!"
    exit 1
fi
