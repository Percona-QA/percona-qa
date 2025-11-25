#!/bin/bash

# Set variable
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/setup_kmip.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/setup_vault.sh"

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -o "-p 5432" -l $LOG_FILE
    PG_PID=$(lsof -ti :5432)
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
    done
}

run_sysbench_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --time=60 --report-interval=10 run
}

enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

crash_server() {
    PG_PID=$1
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

change_key_provider(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        provider_type=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "vault_v2" || echo "file")
        if [ $provider_type == "vault_v2" ]; then
            provider_name=vault_local_provider
            provider_config="'$vault_url','$secret_mount_point','/tmp/token_file','$vault_ca'"
        elif [ $provider_type == "file" ]; then
            provider_name=file_local_provider
            provider_config="'/tmp/keyring.file'"
        fi
        $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_change_database_key_provider_$provider_type('$provider_name',$provider_config)"
        sleep 1
    done
}

main() {
    initialize_server
    start_vault_server
    start_server
    if [ -f /tmp/keyring.file ]; then
	    rm -f /tmp/keyring.file
    fi
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('file_local_provider','/tmp/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('file_global_provider','/tmp/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_local_provider','$vault_url','$secret_mount_point','/tmp/token_file','$vault_ca');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','file_local_provider');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key_sbtest2','file_global_provider');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','file_local_provider');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_sbtest2','file_global_provider');"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --table-size=1000 prepare

    for X in $(seq 1 5); do
        # Run Tests
	run_sysbench_load &
	change_key_provider 15 &
        sleep 10
        crash_server $PG_PID
        sleep 5
        start_server
    done
}

main
