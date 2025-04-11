#!/bin/bash

##############################################################################
#                                                                            #
# This script is written to test Various Roles using different Key Providers #
#                                                                            #
##############################################################################

INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde_17.4/install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir=$INSTALL_DIR/data

initialize_server() {
    PG_PIDS=$(lsof -ti :5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    $INSTALL_DIR/bin/initdb -D $data_dir > /dev/null 2>&1
    cat > "$data_dir/postgresql.conf" <<SQL
port=5432
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$data_dir'
log_filename = 'server.log'
log_statement = 'all'
SQL
}

start_server() {
    data_dir=$1
    $INSTALL_DIR/bin/pg_ctl -D $data_dir start 
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
}

start_kmip_server() {
    # Kill and existing kmip server
    sudo pkill -9 kmip
    # Start KMIP server
    sleep 5
    sudo docker run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
    if [ -d /tmp/certs ]; then
        echo "certs directory exists"
        rm -rf /tmp/certs
        mkdir /tmp/certs
    else
        echo "does not exist. creating certs dir"
        mkdir /tmp/certs
    fi
    sudo docker cp kmip:/opt/certs/root_certificate.pem /tmp/certs/
    sudo docker cp kmip:/opt/certs/client_key_jane_doe.pem /tmp/certs/
    sudo docker cp kmip:/opt/certs/client_certificate_jane_doe.pem /tmp/certs/

    sudo cat /tmp/certs/client_certificate_jane_doe.pem | sudo tee -a /tmp/certs/client_key_jane_doe.pem > /dev/null
    
    kmip_server_address="0.0.0.0"
    kmip_server_port=5696
    kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
    kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
    kmip_server_ca="/tmp/certs/root_certificate.pem"

    # Sleep for 20 sec to fully initialize the KMIP server
    sleep 20
}

start_vault_server() {
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

# Setup
initialize_server
start_server $data_dir
start_kmip_server
start_vault_server

# Actual testing starts here
echo "=>Scenario 4: Switching Providers with Data Validation"
$INSTALL_DIR/bin/psql  -d postgres -c"CREATE DATABASE sbtest4"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_add_key_provider_kmip('kmip_keyring','0.0.0.0',5696,'/tmp/certs/root_certificate.pem','/tmp/certs/client_key_jane_doe.pem');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_set_principal_key('kmip_key','kmip_keyring');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_add_key_provider_vault_v2('vault_keyring','$token','$vault_url','$secret_mount_point','$vault_ca');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_set_principal_key('vault_key','vault_keyring');"

$INSTALL_DIR/bin/psql -d sbtest4 -c"CREATE TABLE t1(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest4 -c"INSERT INTO t1 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d sbtest4 -c"INSERT INTO t1 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d sbtest4 -c"UPDATE t1 SET b='Sachin' WHERE a=100;"
$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"

$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT pg_tde_change_key_provider_kmip('kmip_keyring','0.0.0.0',5696,'/tmp/certs/root_certificate.pem','/tmp/certs/client_key_jane_doe.pem');"

$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"
restart_server $data_dir
$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"

