#!/bin/bash

# Paths and ports
PG_TDE_RESETWAL="$INSTALL_DIR/bin/pg_tde_resetwal"
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="$RUN_DIR/keyfile.pem"

echo "Cleaning up previous data..."
old_server_cleanup $PGDATA

echo "Initializing new cluster with encrypted WAL..."
initialize_server $PGDATA $PORT "--wal-segsize=16"
enable_pg_tde $PGDATA

start_pg $PGDATA $PORT

echo "Creating some tables and generating WAL..."
$PSQL -p $PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_add_database_key_provider_file('key_provider1','$KEYFILE');"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('key1','key_provider1');"
$PSQL -p $PORT -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('key1','key_provider1');"
$PSQL -p $PORT -d postgres -c "CREATE TABLE t1 (id serial, data text);"
$PSQL -p $PORT -d postgres -c "INSERT INTO t1 (data) SELECT repeat('x', 1000) FROM generate_series(1,10000);"
$PSQL -p $PORT -d postgres -c "CHECKPOINT;"

echo "Stopping PostgreSQL..."
stop_pg $PGDATA

echo "Resetting WAL forcibly using pg_tde_resetwal..."
$PG_TDE_RESETWAL -D "$PGDATA"

echo "Attempting to start PostgreSQL after WAL reset..."
start_pg $PGDATA $PORT
$PSQL -p $PORT -d postgres -c "SELECT count(*) FROM t1;"
