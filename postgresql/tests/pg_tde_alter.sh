#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"

# Cleanup
rm -rf $PGDATA/keyring.file

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    PG_PID=$( lsof -ti :5432)
}

enable_tde() {
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_provider','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_database_key_provider_file('local_provider','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key1','global_provider');"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key2','local_provider');"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key1','global_provider');"
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key2','local_provider');"
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
    $INSTALL_DIR/bin/pg_isready -p 5432 -t 60 >> $LOG_FILE 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Primary Server is Running..."
    else
        echo "❌ Primary Server is NOT Running..."
        exit 1
    fi
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql  -d postgres -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;" || true
        $INSTALL_DIR/bin/psql  -d postgres -c "ALTER TABLE sbtest${RAND_TABLE}_r SET ACCESS METHOD $HEAP_TYPE;" || true
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','global_provider');"
    done
}

create_tables(){
    count=$1
    echo "Creating $count encrypted tables with 1000 records..."
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=$count --table-size=1000 prepare
}

run_read_write_load(){
    total_duration=$1
    count=$2
    end_time=$((SECONDS + total_duration))

    while [ $SECONDS -lt $end_time ]; do
        sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=$count --time=60 --report-interval=5 run
        sleep 1
    done
}


enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

crash_server() {
    PG_PID=$1
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

read_tables(){
    echo "Reading original and renamed tables"
    for i in $(seq 1 10);do
        $INSTALL_DIR/bin/psql -d postgres -c "SELECT COUNT(*) FROM sbtest$i" || echo "Table does not exists yet"
    done
}

main() {
    initialize_server
    start_server
    enable_tde
    create_tables 10

    for X in $(seq 1 3); do
        # Run Tests
	echo "=> Running sysbench read/write load"
	run_read_write_load 21 10 /dev/null 2>&1 &
	echo "=> Running encrypt/decrypt tables"
	alter_encrypt_unencrypt_tables 20 > $INSTALL_DIR/alter_e_d.log 2>&1 &
	echo "=> Sleeping for 20 seconds"
        sleep 20
	echo "Killing server with PID: $PG_PID"
        crash_server $PG_PID
	echo "Starting server...."
	start_server
	echo "Server started with PID: $PG_PID"
    done

    read_tables
}

main
