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

PORT_PRIMARY=5433
PORT_REPLICA=5434
REPL_USER=repl
REPL_PASS=replica
DB_NAME=postgres
DB_USER=$(whoami)

# Clean slate
pkill -9 postgres
rm -rf "$PRIMARY_DATA" "$REPLICA_DATA"

# Step 1: Init primary
$INSTALL_DIR/bin/initdb -D "$PRIMARY_DATA"

# Configure primary
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
port = $PORT_PRIMARY
wal_level = replica
wal_log_hints = on
wal_keep_size = 1024MB
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
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE TABLE t1(a int, b varchar(20));"

# Create replication user
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION SUPERUSER PASSWORD '$REPL_PASS';"

echo "=> Step 2: Take base backup for replica"
echo "#######################################"
$PG_BASEBACKUP -D "$REPLICA_DATA" -X stream -R -h localhost -p $PORT_PRIMARY -U $REPL_USER

# Configure replica
cat > "$REPLICA_DATA/postgresql.conf" <<EOF
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
sleep 2

echo "=> Check if replication is working"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "INSERT INTO t1 VALUES(1,'mohit');"
sleep 2

echo "=> Verify if rows get replicated"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "SELECT * FROM t1;"

echo "=>Step 4: Stop primary (simulate crash)"
echo "#######################################"
echo "Simulating primary crash..."
$PG_CTL -D "$PRIMARY_DATA" -m immediate stop

echo "=> Step 5: Promote replica"
echo "##########################"
$PG_CTL -D "$REPLICA_DATA" promote
sleep 5

echo "=>Step 6: Create table to generate WAL on promoted replica"
echo "##########################################################"
echo "Generating WAL..."
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "CREATE TABLE t2(a int, b varchar(20));"

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
sleep 5

echo "=> Check if replication is working"
$PSQL -p $PORT_REPLICA -d $DB_NAME -c "INSERT INTO t2 VALUES(2,'mohit');"
sleep 2

echo "=> Verify if rows get replicated"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM t2;"


# Done
echo -e "\n✅ Check status of Old Primary"
$PSQL -p $PORT_PRIMARY -d $DB_NAME -c "SELECT * FROM pg_stat_wal_receiver;"

# Tail logs
tail -n 10 "$PRIMARY_DATA/log/primary.log"
