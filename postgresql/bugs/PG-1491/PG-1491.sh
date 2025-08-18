#!/bin/bash

# Set variable
export INSTALL_DIR=$HOME/postgresql/bld_tde/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
export DB_NAME="sbtest"
export PARTITION_PARENT="partitioned_table"
# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
       kill -9 $PG_PID
    fi
    rm -rf $PGDATA || true
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
log_statement = 'all'
log_directory = '$PGDATA'
SQL
}
start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    sleep 1
    $INSTALL_DIR/bin/createdb $DB_NAME
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_add_global_key_provider_file('global_provider','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_create_key_using_global_key_provider('table_key','global_provider');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c"SELECT pg_tde_set_key_using_global_key_provider('table_key','global_provider');"
    PG_PID=$(lsof -ti :5432)
}
# Create a partitioned table and partitions
create_partitioned_table() {
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        CREATE TABLE IF NOT EXISTS $PARTITION_PARENT (
            id SERIAL,
            data TEXT,
            created_at DATE NOT NULL,
            PRIMARY KEY (id, created_at)
        ) PARTITION BY RANGE (created_at)"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c " CREATE TABLE t1(a int);"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "SELECT pg_tde_is_encrypted('$PARTITION_PARENT');"
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "SELECT pg_tde_is_encrypted('t1');"
}

# Create initial setup
initialize_server
start_server
create_partitioned_table

partition_table_encrypt_status=$($INSTALL_DIR/bin/psql -d $DB_NAME -t -A -c "SELECT pg_tde_is_encrypted('$PARTITION_PARENT')")
normal_table_encrypt_status=$($INSTALL_DIR/bin/psql -d $DB_NAME -t -A -c "SELECT pg_tde_is_encrypted('t1')")

if [ "$partition_table_encrypt_status" == "" ]; then
    echo "Test passed Successfully"
else
    exit 1
fi
