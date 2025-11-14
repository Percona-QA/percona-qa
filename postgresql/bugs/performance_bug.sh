#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
TABLES=1000

# Increase the waiting time period of PG_CTL so that it waits for the server
# to start and does not give up
export PGCTLTIMEOUT=300

# Initialize the database
initialize_server() {
    PG_PIDS=$(lsof -ti :5433 -ti :5434 2>/dev/null)
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
wal_level = 'logical'
default_table_access_method = 'tde_heap'
SQL

    cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL
}

start_primary() {
    $INSTALL_DIR/bin/pg_ctl -D $PRIMARY_DATA start -l $PRIMARY_LOGFILE > $PRIMARY_LOGFILE 2>&1
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE USER repuser replication;"
}

stop_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir stop
}

start_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir start
}

start_replica() {
    $INSTALL_DIR/bin/pg_tde_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=5433
    sleep 5
    cat >> "$REPLICA_DATA/postgresql.conf" <<SQL
port=5434
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
unix_socket_directories = '/tmp'
SQL
    $INSTALL_DIR/bin/pg_ctl -D $REPLICA_DATA -l $REPLICA_LOGFILE start
}

enable_pg_tde() {
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_add_database_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_key_provider');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_key_provider');"
}

verify_streaming_replication() {
    echo "Creating verification table on primary..."
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "CREATE TABLE verify_replication(id INT PRIMARY KEY, val TEXT);"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "INSERT INTO verify_replication VALUES (1, 'streaming_test');"

    echo "Waiting for replication to apply..."
    sleep 20

    echo "Checking data on replica..."
    result=$($INSTALL_DIR/bin/psql -d postgres -p 5434 -Atc "SELECT val FROM verify_replication WHERE id=1;" 2>/dev/null)

    if [[ "$result" == "streaming_test" ]]; then
        echo "Streaming replication is working correctly"
    else
        echo "Streaming replication failed or is delayed"
        exit 1
    fi
}

run_workload_during_conversion() {
    echo "Running workload on primary..."

    sysbench /usr/share/sysbench/oltp_write_only.lua \
        --pgsql-user=$(whoami) \
        --pgsql-db=postgres \
        --db-driver=pgsql \
        --pgsql-port=5433 \
        --threads=10 \
        --tables=$TABLES \
        --table-size=1000 \
        --time=60 \
        run > /tmp/workload.log 2>&1 &
}

# Actual test starts here...

echo "1=>Create Data Directory"
initialize_server

echo "2=>Start Primary Server"
start_primary

echo "3=>Start Replica Server"
start_replica

echo "4=>Enable pg_tde on Primary Server"
enable_pg_tde

echo "Create some tables on Primary Node"
time sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=postgres --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=1000 prepare

echo "5=>Verifying Streaming Replication"
verify_streaming_replication

echo "6=>Run workload in parallel on Primary Server"
run_workload_during_conversion
sleep 30

$INSTALL_DIR/bin/psql -d postgres -p 5432 -c "CHECKPOINT"
echo "7=>Stop and Start Replica while load is running on primary"
stop_server $REPLICA_DATA

echo "Starting Replica Server"
start_server $REPLICA_DATA
