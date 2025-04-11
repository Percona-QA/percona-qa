#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
#export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde_17.4/install
export INSTALL_DIR=/home/mohit.joshi/percona-postgresql17
export PRIMARY_DATA=$INSTALL_DIR/primary_data
export REPLICA_DATA=$INSTALL_DIR/replica_data
export PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
export REPLICA_LOGFILE=$REPLICA_DATA/server.log
export DB_NAME=mohit

# initate the database
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
SQL

    cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL
}

start_primary() {
    $INSTALL_DIR/bin/pg_ctl -D $PRIMARY_DATA start -l $PRIMARY_LOGFILE > $PRIMARY_LOGFILE 2>&1
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE USER repuser replication;"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE DATABASE $DB_NAME;"
    #$INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"CREATE EXTENSION IF NOT EXISTS pg_tde;" > /dev/null
    #$INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"SELECT pg_tde_add_key_provider_file('local_keyring','$PRIMARY_DATA/keyring.file');" > /dev/null
    #$INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"SELECT pg_tde_set_principal_key('principal_key_sbtest','local_keyring');" > /dev/null
    #$INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"SELECT pg_tde_add_global_key_provider_file('local_keyring','$PRIMARY_DATA/keyring.file');" > /dev/null
    #$INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"SELECT pg_tde_set_server_principal_key('principal_key_sbtest','local_keyring');" > /dev/null
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
}

start_replica() {
    $INSTALL_DIR/bin/pg_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=5433
    sleep 5
    cat >> "$REPLICA_DATA/postgresql.conf" <<SQL
port=5434
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
SQL
    $INSTALL_DIR/bin/pg_ctl -D $REPLICA_DATA -l $REPLICA_LOGFILE start
    
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql -d $DB_NAME -p 5433 -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
        sleep 1
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating Global master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c "SELECT pg_tde_set_server_principal_key('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."
    done
}

run_sysbench_load(){
    time=$1
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=100 --time=$time --report-interval=1 --events=1870000000 run &
    sysbench /usr/share/sysbench/oltp_delete.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=100 --time=$time --table-size=1000 &
    sysbench /usr/share/sysbench/oltp_update_index.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=100 --time=$time --table-size=1000 &

}

enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d $DB_NAME  -p 5433 -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

rotate_master_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_principal_key('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continue..."
    done
}

crash_replica_server() {
    REPLICA_PID=$( lsof -ti :5434)
    echo "Killing the Replica Server with PID=$REPLICA_PID..."
    kill -9 $REPLICA_PID
}

crash_primary_server() {
    PRIMARY_PID=$( lsof -ti :5433)
    echo "Killing the Primary Server with PID=$PRIMARY_PID"
    kill -9 $PRIMARY_PID
}

# Actual test starts here...

echo "1=>Create Data Directory"
initialize_server

echo "2=>Start Primary Server"
start_primary

echo "3=>Start Replica Server"
start_replica

enable_tde_and_recreate_load() {
echo "4=>Enable pg_tde on Primary Server"
$INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
$INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_add_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_principal_key('local_key','local_key_provider');"
$INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_server_principal_key('global_key','global_key_provider');"

echo "Create some tables on Primary Node"
sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=100 --table-size=1000 prepare
sysbench /usr/share/sysbench/bulk_insert.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=100 --table-size=1000
}

enable_tde_and_recreate_load

echo "Running Sysbench Load"
run_sysbench_load 300 > /dev/null 2>&1 &
pid1=$!
#rotate_wal_key 60 >/dev/null 2>&1 &
#pid2=$!
#enable_disable_wal_encryption 60 2>&1 > /dev/null &
#pid3=$!
#rotate_master_key 60 >/dev/null 2>&1  &
#pid4=$!
alter_encrypt_unencrypt_tables 300   > /dev/null 2>&1 &
pid5=$!

for i in $(seq 1 5); do
    sleep 30
    crash_replica_server
    sleep 30
    echo "Restarting Replica Server"
    restart_server $REPLICA_DATA
    sleep 15
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"DROP DATABASE mohit"
    enable_tde_and_recreate_load
    crash_primary_server
    sleep 30
    echo "Restarting Primary Server"
    restart_server $PRIMARY_DATA
done

wait $pid1
wait $pid5

echo "Verify table and data between primary and replica node..."
sleep 30
error_flag=0
for i in $(seq 1 10); do
    PRIMARY_COUNT=$($INSTALL_DIR/bin/psql -d postgres -p 5433 -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    REPLICA_COUNT=$($INSTALL_DIR/bin/psql -d postgres -p 5434 -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    if [ "$PRIMARY_COUNT" -ne "$REPLICA_COUNT" ]; then
        echo "Mismatch in table sbtest$i: Primary($PRIMARY_COUNT) != Replica($REPLICA_COUNT)"
        exit 1
    else
        echo "Rows match in table sbtest$i: Primary($PRIMARY_COUNT) = Replica($REPLICA_COUNT)"
    fi
done

