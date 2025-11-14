#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -l $LOG_FILE
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
}

create_tables(){
    echo "Creating Table t1 and t2 in database sbtest"
    $INSTALL_DIR/bin/psql  -d sbtest -c "DROP TABLE IF EXISTS t1;"
    $INSTALL_DIR/bin/psql  -d sbtest -c "DROP TABLE IF EXISTS t2;"
    $INSTALL_DIR/bin/psql  -d sbtest -c "CREATE TABLE t1(a int) USING tde_heap;"
    $INSTALL_DIR/bin/psql  -d sbtest -c "INSERT INTO t1 VALUES(1);"

    $INSTALL_DIR/bin/psql  -d sbtest -c "CREATE TABLE t2(a int) USING heap;"
    $INSTALL_DIR/bin/psql  -d sbtest -c "INSERT INTO t2 VALUES(100);"
}

read_tables(){
    echo "Reading non-encrypted table"
    $INSTALL_DIR/bin/psql  -d sbtest -c "SELECT * FROM t2" || echo "table could not be read"
    echo "Reading encrypted table"
    $INSTALL_DIR/bin/psql  -d sbtest -c "SELECT * FROM t1" || echo "table could not be read"
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql  -d sbtest -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"

        sleep 1

    done
}

rotate_master_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d sbtest -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."

    done
}

create_sysbench_tables(){
	sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=mohit.joshi --db-driver=pgsql --threads=5 --tables=10 --table-size=1000 prepare
}

run_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=mohit.joshi --db-driver=pgsql --threads=5 --tables=10 --time=60 --report-interval=1 --events=1870000000 run
}
# Main script execution
main() {
    echo "Starting Encryption tests..."
    echo "1. Creating Data Directory"
    initialize_server
    echo "2. Starting Server"
    start_server
    echo "3. Creating Tables"
    create_sysbench_tables
    echo "4. Run Load"
    run_load &
    PID1=$!
    rotate_master_key 60 > $INSTALL_DIR/rotate.log 2>&1 &
    PID2=$!
    alter_encrypt_unencrypt_tables 60 > $INSTALL_DIR/alter_enc_dct.log 2>&1 &
    PID3=$!

    wait $PID1
    wait $PID2
    wait $PID3

    for i in $(seq 1 10); do
        $INSTALL_DIR/bin/psql  -d sbtest -c "SELECT COUNT(*) FROM sbtest$i" 2> /dev/null || echo "Table does not exists yet"
    done
    stop_server
    sed -i 's/^shared_preload_libraries/#&/' $PGDATA/postgresql.conf
    echo "Starting server with encryption disabled"
    restart_server
    for i in $(seq 1 10); do
        $INSTALL_DIR/bin/psql  -d sbtest -c "SELECT COUNT(*) FROM sbtest$i" 2> /dev/null || echo "Table does not exists yet"
    done

    echo "Tests completed successfully! 🚀"
}

# Run the main function
main

