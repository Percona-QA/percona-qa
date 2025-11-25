#!/bin/bash

# Set variable
PGDATA=$INSTALL_DIR/data
LOG_FILE=$PGDATA/server.log

# initialize the database
initialize_server() {
    PG_PIDS=$(lsof -ti :5432 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $PGDATA
    mkdir $PGDATA
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -l $LOG_FILE
    $INSTALL_DIR/bin/createdb sbtest
    $INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_global_key_provider('key1','global_keyring');"
    $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_global_key_provider('key1','global_keyring');"
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
}

initialize_server
start_server

echo "Create Table T1"
$INSTALL_DIR/bin/psql -d sbtest -c "CREATE TABLE t1 (id SERIAL PRIMARY KEY,name VARCHAR(100),t2_id INT) using tde_heap;"
$INSTALL_DIR/bin/psql -d sbtest -c "INSERT INTO t1(name) VALUES ('Mohit'),('Rohit')"

echo "Convert T1 into non-encrypted table by changing access method to heap"
$INSTALL_DIR/bin/psql -d sbtest -c "ALTER TABLE t1 SET ACCESS METHOD heap;"

echo "Initiate TDE uninstallation procedure"
$INSTALL_DIR/bin/psql -d sbtest -c "DROP EXTENSION pg_tde;"

sed -i 's/^shared_preload_libraries/#&/' $PGDATA/postgresql.conf
echo "Restart server"
restart_server

$INSTALL_DIR/bin/psql -d sbtest -c "SELECT * FROM t1"
