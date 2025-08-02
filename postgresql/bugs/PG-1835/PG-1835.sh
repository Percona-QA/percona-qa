#!/bin/bash

# Config
INSTALL_DIR=$HOME/postgresql/bld_tde/install
DATA_DIR=$INSTALL_DIR/pg_resetwal_test_data
LOGFILE=$DATA_DIR/server.log
PG_CTL=$INSTALL_DIR/bin/pg_ctl
INITDB=$INSTALL_DIR/bin/initdb
PSQL=$INSTALL_DIR/bin/psql
PG_RESETWAL=$INSTALL_DIR/bin/pg_resetwal
PORT=5432

# Cleanup from previous runs
PID=$(lsof -ti :$PORT)
if [ -n "$PID" ]; then
    kill -9 $PID
fi
rm -rf "$DATA_DIR" /tmp/keyring.per

echo "=> Initialise Data directory"
"$INSTALL_DIR/bin/initdb" -D "$DATA_DIR"

# Enable WAL encryption via postgresql.conf
echo "shared_preload_libraries = 'pg_tde'" >> $DATA_DIR/postgresql.conf
echo "default_table_access_method = 'tde_heap'" >> $DATA_DIR/postgresql.conf
echo "port = $PORT" >> $DATA_DIR/postgresql.conf

echo "=> Starting PostgreSQL"
$PG_CTL -D "$DATA_DIR" -l "$LOGFILE" start
sleep 2

echo "Creating TDE extension"
$PSQL -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
$PSQL -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '/tmp/keyring.per');"
$PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
$PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
$PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
$PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
$PSQL -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

echo "=> ReStarting PostgreSQL"
$PG_CTL -D "$DATA_DIR" -l "$LOGFILE" restart
sleep 2

echo "=> Creating test table and inserting data"
$PSQL -p 5432 -d postgres -c "CREATE TABLE test(id INT, val TEXT);"
$PSQL -p 5432 -d postgres -c "INSERT INTO test VALUES (1, 'before reset');"

echo "=> Stopping PostgreSQL"
$PG_CTL -D "$DATA_DIR" stop
sleep 2

echo "=> Running pg_resetwal on encrypted WAL cluster"
$PG_RESETWAL -D "$DATA_DIR"

echo ">>> Restarting PostgreSQL after WAL reset"
$PG_CTL -D "$DATA_DIR" -l "$LOGFILE" start
sleep 2

echo ">>> Inserting data after reset"
$PSQL -p 5432 -d postgres -c "INSERT INTO test VALUES (2, 'after reset');"

echo ">>> Querying table to verify data"
$PSQL -p 5432 -d postgres -c "SELECT * FROM test;"

echo ">>> Done. Check $LOGFILE for details."

# Optionally show WAL timeline
echo ">>> Current timeline after reset:"
$PSQL -p 5432 -d postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"

echo ">>> Stopping PostgreSQL"
$PG_CTL -D "$DATA_DIR" stop

