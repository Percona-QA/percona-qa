#!/bin/bash

# Set variables
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
DB_NAME=test_db
WAL_ENCRYPT=OFF
TABLES=5

# initialize primary
initialize_server() {
    PG_PIDS=$(lsof -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $PRIMARY_DATA $REPLICA_DATA
    $INSTALL_DIR/bin/initdb -D $PRIMARY_DATA > /dev/null 2>&1
    cat > "$PRIMARY_DATA/postgresql.conf" <<SQL
port=5433
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$PRIMARY_DATA'
log_filename = 'server.log'
log_statement = 'all'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
SQL

    cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL
}

start_primary() {
    $INSTALL_DIR/bin/pg_ctl -D $PRIMARY_DATA start -l $PRIMARY_LOGFILE > $PRIMARY_LOGFILE 2>&1
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "CREATE USER repuser replication;"
}

start_replica() {
    $INSTALL_DIR/bin/pg_tde_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=replica_slot -C --port=5433
    sleep 5
    cat > "$REPLICA_DATA/postgresql.conf" <<SQL
port=5434
shared_preload_libraries=pg_tde
listen_addresses='*'
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
SQL
    $INSTALL_DIR/bin/pg_ctl -D $REPLICA_DATA -l $REPLICA_LOGFILE start
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
}

crash_primary_server() {
    PRIMARY_PID=$(lsof -ti :5433)
    echo "Killing Primary Server with PID=$PRIMARY_PID"
    kill -9 $PRIMARY_PID
}

crash_replica_server() {
    REPLICA_PID=$(lsof -ti :5434)
    echo "Set pg_tde.wal_encrypt=ON"
    echo "pg_tde.wal_encrypt = ON" >> $REPLICA_DATA/postgresql.conf
    echo "Killing Replica Server with PID=$REPLICA_PID"
    kill -9 $REPLICA_PID
}

enable_tde_and_set_keys() {
    PORT=$1
    $INSTALL_DIR/bin/psql -d postgres -p $PORT -c"CREATE DATABASE $DB_NAME;"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c"SELECT pg_tde_create_key_using_global_key_provider('global_key','global_key_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_key','global_key_provider');"
}
# Existing functions for workload, rotation, etc. (no change)

# === Test execution starts ===

echo "1=> Create Data Directory"
initialize_server

echo "2=> Start Primary Server"
start_primary

echo "3=> Start First Replica Server"
start_replica

echo "5=> Enable pg_tde on Primary Server"
enable_tde_and_set_keys 5433

echo "Create some tables on Primary Node"
sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=1000 prepare
sysbench /usr/share/sysbench/bulk_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=1000

for i in $(seq 1 5); do
    if grep -Eq "FATAL:.*invalid magic number" $REPLICA_DATA/server.log; then
        exit 1
    fi
    echo "####TRIAL $i##########"
    crash_replica_server
    sleep 10
    echo "Restarting Replica Server"
    restart_server $REPLICA_DATA
    sleep 10

    crash_primary_server
    sleep 10
    echo "Restarting Primary Server"
    restart_server $PRIMARY_DATA
    sleep 10
done

echo "Verifying tables and data between primary and replicas..."
sleep 10
for i in $(seq 1 $TABLES); do
    PRIMARY_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p 5433 -t -A -c "SELECT COUNT(*) FROM sbtest$i;")
    REPLICA_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p 5434 -t -A -c "SELECT COUNT(*) FROM sbtest$i;")

    if [ "$PRIMARY_COUNT" -ne "$REPLICA_COUNT" ]; then
        echo "Mismatch detected in table sbtest$i!"
        echo "Primary($PRIMARY_COUNT) Replica($REPLICA_COUNT) "
        exit 1
    else
        echo "Rows match in table sbtest$i: Primary=$PRIMARY_COUNT Replica=$REPLICA_COUNT "
    fi
done
