#!/bin/bash

# Set variable
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ $PG_PID != "" ]]; then
         kill -9 $PG_PID
    fi
    sudo rm -rf $PGDATA
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
default_table_access_method='tde_heap'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -o "-p 5432" -l $LOG_FILE
    PG_PID=$( lsof -ti :5432)
    if [[ -z "$PG_PID" ]]; then
        echo "ERROR: PostgreSQL server failed to start: $LOG_FILE"
        exit 1
    fi
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
}
alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql -d sbtest -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
        sleep 1
    done
}
rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','global_keyring');"
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','global_keyring');"
        sleep 2
    done
}
run_sysbench_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --time=25 --report-interval=1 --events=1870000000 run
}
enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))
    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 2
    done
}
crash_server() {
    PG_PID=$1
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

main() {
    initialize_server
    start_server
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key_sbtest','global_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_sbtest','global_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --table-size=1000 prepare
    enable_disable_wal_encryption 60 &
    rotate_wal_key 60 &

    for X in $(seq 1 5); do
        # Run Tests
        run_sysbench_load &
        sleep 20
        crash_server $PG_PID
        sleep 1
        start_server
        sleep 9
    done
}

main

