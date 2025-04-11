#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."

    done
}

run_sysbench_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --time=60 --report-interval=1 --events=1870000000 run
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

start_vault_server(){
    killall vault > /dev/null 2>&1
    echo "=> Starting vault server"
    if [ ! -d $SCRIPT_DIR/vault ]; then
    mkdir $SCRIPT_DIR/vault
    fi
    rm -rf $SCRIPT_DIR/vault/*
    $SCRIPT_DIR/vault_test_setup.sh --workdir=$SCRIPT_DIR/vault --setup-pxc-mount-points --use-ssl > /dev/null 2>&1
    vault_url=$(grep 'vault_url' "${SCRIPT_DIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    secret_mount_point=$(grep 'secret_mount_point' "${SCRIPT_DIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    token=$(grep 'token' "${SCRIPT_DIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    vault_ca=$(grep 'vault_ca' "${SCRIPT_DIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    echo ".. Vault server started"
}

change_key_provider(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        provider_type=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "vault_v2" || echo "file")
        if [ $provider_type == "vault_v2" ]; then
            provider_name=vault_keyring
            provider_config="'$token','$vault_url','$secret_mount_point','$vault_ca'"
        elif [ $provider_type == "file" ]; then
            provider_name=file_keyring
            provider_config="'/tmp/keyring.file'"
        fi
        $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_change_database_key_provider_$provider_type('$provider_name',$provider_config)"
        sleep 1
    done
}

run_parallel_tests() {
    run_sysbench_load &
    change_key_provider 60 &
}


main() {
    initialize_server
    start_vault_server
    start_server
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('file_keyring','/tmp/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring','$token','$vault_url','$secret_mount_point','$vault_ca');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','file_keyring');"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --table-size=1000 prepare
    for X in $(seq 1 5); do
        # Run Tests
        run_parallel_tests &
        sleep 10
        crash_server $PG_PID
        #stop_server
        sleep 5
        start_server
    done
}

main
if grep -iq "invalid" "$LOG_FILE"; then
    echo "ERROR Found: Unable to read redo logs: $LOG_FILE"
    exit 1
else
