#!/bin/bash

INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde/install
data_dir=$INSTALL_DIR/data
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/setup_kmip.sh"

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $data_dir start 
    $INSTALL_DIR/bin/psql  -d postgres -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
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
start_kmip_server
setup_key_provider kmip
