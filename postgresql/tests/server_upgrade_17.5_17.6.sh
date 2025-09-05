#!/bin/bash

INSTALL_DIR_LOWER=$HOME/postgresql/bld_tde/install
INSTALL_DIR_HIGHER=$HOME/postgresql/bld_17.6/install
LOWER_VERSION=17.5.3
HIGHER_VERSION=17.6.1
DATADIR_LOWER=$INSTALL_DIR_LOWER/data_$LOWER_VERSION
DATADIR_HIGHER=$INSTALL_DIR_HIGHER/data_$HIGHER_VERSION
PORT=5432
KEYRING_FILE=/tmp/keyring.file

main_test() {

# Step 1: Kill any running PG server on port 5432
echo "=> Checking for running PostgreSQL on port $PORT"
PG_PID=$(sudo lsof -ti :$PORT || true)
if [ -n "$PG_PID" ]; then
  echo "=> Killing process $PG_PID"
  kill -9 $PG_PID
fi

# Step 2: Remove keyring file
echo "=> Removing keyring file"
rm -rf "$KEYRING_FILE" $DATADIR_LOWER $DATADIR_HIGHER

# Step 3: Start Server on LOWER_VERSION
$INSTALL_DIR_LOWER/bin/initdb -D $DATADIR_LOWER

# Configure postgresql.conf
echo "shared_preload_libraries = 'pg_tde'" >> "$DATADIR_LOWER/postgresql.conf"
echo "default_table_access_method = 'tde_heap'" >> "$DATADIR_LOWER/postgresql.conf"
echo "listen_addresses = '*'" >> "$DATADIR_LOWER/postgresql.conf"
echo "port = $PORT" >> "$DATADIR_LOWER/postgresql.conf"
echo "logging_collector = on" >> "$DATADIR_LOWER/postgresql.conf"
echo "log_directory = '$DATADIR_LOWER'" >> "$DATADIR_LOWER/postgresql.conf"
echo "log_filename = 'server_$LOWER_VERSION.log'" >> "$DATADIR_LOWER/postgresql.conf"
echo "log_statement = 'all'" >> "$DATADIR_LOWER/postgresql.conf"

$INSTALL_DIR_LOWER/bin/pg_ctl -D $DATADIR_LOWER start

# Enable TDE
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "CREATE EXTENSION pg_tde"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider1','$KEYRING_FILE')"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('server_key', 'global_file_provider1')"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('table_key', 'global_file_provider1')"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key', 'global_file_provider1')"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('table_key', 'global_file_provider1')"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON'"

# Restart server to enable WAL encryption
$INSTALL_DIR_LOWER/bin/pg_ctl -D $DATADIR_LOWER restart
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SHOW pg_tde.wal_encrypt"
$INSTALL_DIR_LOWER/bin/psql -d postgres -p $PORT -c "SELECT version()"

echo "✅ PostgreSQL Server started on port $PORT"

sysbench /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$PORT \
  --pgsql-user=`whoami` \
  --pgsql-db=postgres \
  --db-driver=pgsql \
  --time=40 --threads=5 --tables=10 --table-size=1000 prepare

sleep 3

echo " Start the upgrade process...Stop server"
$INSTALL_DIR_LOWER/bin/pg_ctl -D $DATADIR_LOWER stop
cp -R $DATADIR_LOWER $DATADIR_HIGHER
rm -f $DATADIR_HIGHER/postgresql.conf

# Configure postgresql.conf
echo "shared_preload_libraries = 'pg_tde'" >> "$DATADIR_HIGHER/postgresql.conf"
echo "default_table_access_methos = 'tde_heap'" >> "$DATADIR_LOWER/postgresql.conf"
echo "listen_addresses = '*'" >> "$DATADIR_HIGHER/postgresql.conf"
echo "port = $PORT" >> "$DATADIR_HIGHER/postgresql.conf"
echo "logging_collector = on" >> "$DATADIR_HIGHER/postgresql.conf"
echo "log_directory = '$DATADIR_HIGHER'" >> "$DATADIR_HIGHER/postgresql.conf"
echo "log_filename = 'server_$HIGHER_VERSION.log'" >> "$DATADIR_HIGHER/postgresql.conf"
echo "log_statement = 'all'" >> "$DATADIR_HIGHER/postgresql.conf"

echo "Starting PG server $HIGHER_VERSION using $DATADIR_LOWER"
if ! "$INSTALL_DIR_HIGHER/bin/pg_ctl" -D "$DATADIR_HIGHER" -o "-p $PORT" -w start; then
    echo "❌ Failed to start PostgreSQL on port $PORT. Exiting as upgrade failed..."
    exit 1
else
    echo "Server successfully upgraded to $HIGHER_VERSION"
fi

$INSTALL_DIR_HIGHER/bin/psql -d postgres -p $PORT -c "SELECT version()"
$INSTALL_DIR_HIGHER/bin/psql -d postgres -p $PORT -c "SHOW pg_tde.wal_encrypt"
$INSTALL_DIR_HIGHER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_is_encrypted('sbtest1')"
$INSTALL_DIR_HIGHER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_is_encrypted('sbtest5')"
$INSTALL_DIR_HIGHER/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_is_encrypted('sbtest10')"

}


# Main test begins here
main_test
