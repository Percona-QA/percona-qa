#!/bin/bash

# Set variable
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
        kill -9 $PG_PID
    fi
    if [ -d $LOG_FILE ]; then
        rm -rf $LOG_FILE
    fi
    if [ -d $PGDATA ]; then
        rm -rf $PGDATA
    fi
    if [ -f $PGDATA/keyring.file ]; then
        rm $PGDATA/keyring.file
    fi
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
SQL
}

start_server() {
    echo "Going to start the server"
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
}

restart_server() {
    echo "Going to restart the server"
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE restart
}

initialize_server
start_server

echo "Enabling TDE and setting Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('provider1','$PGDATA/keyring1.file')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('key1','provider1')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_global_key_provider('key1','provider1')"

$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_change_global_key_provider_file('provider1','$PGDATA/keyring2.file')"

restart_server

$INSTALL_DIR/bin/psql -d postgres -c"DROP EXTENSION pg_tde CASCADE"
