#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
wal_encrypt_flag=off

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ $PG_PID != "" ]]; then
         kill -9 $PG_PID
    fi
    rm -rf $PGDATA
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

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: wal_key$RAND_KEY"
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key$RAND_KEY','global_keyring');"
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key$RAND_KEY','global_keyring');"
        sleep 2
    done
}
run_sysbench_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --time=25 --report-interval=5 run
}

crash_server() {
    PG_PID=$1

    if [ $wal_encrypt_flag == "on" ]; then
        wal_encrypt_flag="off"
    else
        wal_encrypt_flag="on"
    fi
    echo "Altering WAL encryption to use $wal_encrypt_flag..."
    $INSTALL_DIR/bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$wal_encrypt_flag';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

main() {
    initialize_server
    start_server
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring_global.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring_local.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --table-size=1000 prepare
    rotate_wal_key 20 &

    
    for X in $(seq 1 5); do
        # Run Tests
        run_sysbench_load > /dev/null 2>&1 &
        sleep 20
        crash_server $PG_PID
        sleep 1
        start_server
    done
}

main
