INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde/install
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

echo "Initialize the Data Directory"
initialize_server

echo "Start server"
$INSTALL_DIR/bin/pg_ctl -D $DATA_DIR start > /dev/null 2>&1

echo "Create database abc"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE DATABASE abc"

echo "Create extension pg_tde"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d abc -c"CREATE EXTENSION pg_tde;"

echo "Create a Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$DATA_DIR/keyring.file')"

echo "Create a Default Principal key using the Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_default_principal_key_using_global_key_provider('principal_key_of_abc','global_keyring')"

echo "Restart server"
$INSTALL_DIR/bin/pg_ctl -D $DATA_DIR restart
exit_status=$?

if [ $exit_status -eq 0 ]; then
    echo "Test passed ✅"
else
    echo "Test failed ❌"
fi
