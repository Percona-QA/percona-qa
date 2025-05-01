#!/bin/bash

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
    rm -rf $PGDATA || true
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
default_table_access_method='tde_heap'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -l $LOG_FILE
    PG_PID=$(lsof -ti :5432)
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
    PG_PID=$(lsof -ti :5432)
}

run_sysbench_load(){
    duration=$1
    tables=$2
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=$tables --time=$duration --report-interval=1 --events=1870000000 run
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
    provider_type=file

    while [ $SECONDS -lt $end_time ]; do
        if [ $provider_type == "vault_v2" ]; then
            provider_type=file
        elif [ $provider_type == "file" ]; then
            provider_type=vault_v2
        fi
        if [ $provider_type == "vault_v2" ]; then
            provider_name=local_vault
            provider_config="'$token','$vault_url','$secret_mount_point','$vault_ca'"
        elif [ $provider_type == "file" ]; then
            provider_name=local_keyring
            provider_config="'$PGDATA/keyring.file'"
        fi
        $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_${provider_type}('$provider_name',$provider_config)"
        $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','$provider_name')"
        sleep 1
    done
}

# Actual tests starts from here..
echo "Initialize the Data directory"
initialize_server
echo "Start vault server"
start_vault_server
echo "Start the server"
start_server
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE sbtest"
$INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_global_key_provider('principal_key_sbtest','global_keyring');"
echo "Create sysbench tables"
sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=50 --table-size=1000 prepare
# Run sysbench for 20 sec for 50 tables
run_sysbench_load 20 50 &
change_key_provider 40 &
for i in $(seq 1 3); do
    sleep 10
    crash_server $PG_PID
    sleep 5
    cp -r $PGDATA $INSTALL_DIR/data_bk
    start_server
done

for i in $(seq 1 10); do
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT count(*) FROM sbtest${i}"
done
