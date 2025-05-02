#!/bin/bash

INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde/install
data_dir=$INSTALL_DIR/data

initialize_server() {
    PG_PIDS=$(lsof -ti :5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $data_dir
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
    $INSTALL_DIR/bin/pg_ctl -D $data_dir start 
    $INSTALL_DIR/bin/psql  -d postgres -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
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
    # This is an improvement ticket to fix this
    sudo cat /tmp/certs/client_certificate_jane_doe.pem | sudo tee -a /tmp/certs/client_key_jane_doe.pem
    
    kmip_server_address="0.0.0.0"
    kmip_server_port=5696
    kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
    kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
    kmip_server_ca="/tmp/certs/root_certificate.pem"

    # Sleep for 30 sec to fully initialize the KMIP server
    sleep 30
}

setup_key_provider() {
    key_provider_type=$1
    if [ $key_provider_type == "kmip" ]; then
        start_kmip_server
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_database_key_provider_kmip('keyring_kmip','$kmip_server_address', $kmip_server_port,'$kmip_server_ca','$kmip_client_key');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key','keyring_kmip');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_global_key_provider_kmip('keyring_kmip','$kmip_server_address', $kmip_server_port,'$kmip_server_ca','$kmip_client_key');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_principal_key','keyring_kmip');" > /dev/null
    elif [ $key_provider_type == "vault" ]; then
        start_vault_server
    elif [ $key_provider_type == "file" ]; then
        echo "Using Key Provider Type = file"
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$data_dir/keyring.file');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('key1','local_keyring');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$data_dir/keyring.file');" > /dev/null
        $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('key2','global_keyring');" > /dev/null
    fi
}


initialize_server
start_server
setup_key_provider kmip
