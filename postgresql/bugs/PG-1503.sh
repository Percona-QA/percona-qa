#!/bin/bash

###########################################################################################################
# PG-1503 - Deleting a Global key provider must not be allowed when we have active keys on the database   #
###########################################################################################################

DATA_DIR=$INSTALL_DIR/data

initialize_server() {
    PG_PIDS=$(lsof -ti :5432 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $DATA_DIR || true
    $INSTALL_DIR/bin/initdb -D $DATA_DIR > /dev/null 2>&1
    cat > "$DATA_DIR/postgresql.conf" <<SQL
port=5432
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$DATA_DIR'
log_filename = 'server.log'
log_statement = 'all'
SQL
}

# Setup
echo "=> Initialize Data Directory"
initialize_server
echo "..Successfully created data directory"

# Actual testing starts here
echo "Start PG server"
$INSTALL_DIR/bin/pg_ctl -D $DATA_DIR start > /dev/null 2>&1

echo "Create pg_tde extension"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde"

echo "Create a Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$DATA_DIR/keyring.file')"

echo "Create a Principal key using the Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('local_key_of_db1_using_global_key_provider','global_keyring')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_global_key_provider('local_key_of_db1_using_global_key_provider','global_keyring')"

echo "Create encrypted table"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap"

echo "Insert a record"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES(1)"

echo "Delete the Global Key Provider. Must Fail"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_delete_global_key_provider('global_keyring')"
ret_code=$?

if [ $ret_code -ne 0 ]; then
    echo "Success!"
else
    echo "FAIL: Command unexpectedly succeeded"
    exit 1
fi

