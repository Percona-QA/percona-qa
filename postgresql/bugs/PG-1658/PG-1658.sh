#!/bin/bash

INSTALL_DIR=$HOME/postgresql/bld_tde/install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir=$INSTALL_DIR/data
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/start_server.sh"
rm /tmp/key_holder.pem

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $data_dir start
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde;"
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
    sleep 2
}

# Setup
initialize_server
start_server

# Actual testing starts here

echo "..Add a Global key provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('file_provider','/tmp/key_holder.pem');"

echo "..Create a Global Default Principal key"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"

echo "..Create encrypted table"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES(1);"

echo "..Restart server"
restart_server $data_dir

$INSTALL_DIR/bin/psql -d postgres -c"DROP TABLE t1;"

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_default_key()"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('file_provider')"
