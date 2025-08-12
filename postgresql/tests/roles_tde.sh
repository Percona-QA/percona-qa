#!/bin/bash

##############################################################################
#                                                                            #
# This script is written to test Various Roles using different Key Providers #
#                                                                            #
##############################################################################

INSTALL_DIR=$HOME/postgresql/bld_tde/install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir=$INSTALL_DIR/data
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/setup_kmip.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/setup_vault.sh"

start_server() {
    data_dir=$1
    $INSTALL_DIR/bin/pg_ctl -D $data_dir start 
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
}

# Setup
initialize_server
start_server $data_dir
start_kmip_server
start_vault_server

# Actual testing starts here
echo "=>Test: Switching Providers with Data Validation"
$INSTALL_DIR/bin/psql  -d postgres -c"CREATE DATABASE sbtest4"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_add_database_key_provider_kmip('kmip_keyring','0.0.0.0',5696,'/tmp/certs/root_certificate.pem','/tmp/certs/client_certificate_jane_doe.pem','/tmp/certs/client_key_jane_doe.pem');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_set_key_using_database_key_provider('kmip_key','kmip_keyring');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring','$token','$vault_url','$secret_mount_point','$vault_ca');"
$INSTALL_DIR/bin/psql  -d sbtest4 -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key','vault_keyring');"

$INSTALL_DIR/bin/psql -d sbtest4 -c"CREATE TABLE t1(a INT, b varchar) USING tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest4 -c"INSERT INTO t1 VALUES(100,'Mohit');"
$INSTALL_DIR/bin/psql -d sbtest4 -c"INSERT INTO t1 VALUES(200,'Rohit');"
$INSTALL_DIR/bin/psql -d sbtest4 -c"UPDATE t1 SET b='Sachin' WHERE a=100;"
$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"

$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT pg_tde_change_database_key_provider_kmip('kmip_keyring','0.0.0.0',5696,'/tmp/certs/root_certificate.pem','/tmp/certs/client_certificate_jane', '/tmp/certs/client_key_jane_doe.pem');"

$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"
restart_server $data_dir
$INSTALL_DIR/bin/psql -d sbtest4 -c"SELECT * FROM t1;"
