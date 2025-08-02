#!/bin/bash

# Paths and ports
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
PG_RESETWAL="$INSTALL_DIR/bin/pg_resetwal"
PSQL="$INSTALL_DIR/bin/psql"
PORT=5432
LOG="$PRIMARY_DATA/server.log"

echo "Cleaning up..."
pkill -9 postgres
rm -rf "$PRIMARY_DATA"
mkdir -p "$PRIMARY_DATA"

echo "Initializing new cluster with encrypted WAL..."
$INSTALL_DIR/bin/initdb -D "$PRIMARY_DATA" --wal-segsize=16

# Enable encryption
echo "shared_preload_libraries = 'pg_tde'" >> "$PRIMARY_DATA/postgresql.conf"
echo "port = $PORT" >> "$PRIMARY_DATA/postgresql.conf"

echo "Starting PostgreSQL..."
$PG_CTL -D "$PRIMARY_DATA" -l "$LOG" start
sleep 3

echo "Creating some tables and generating WAL..."
$PSQL -p $PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -p $PORT -d postgres -c "CREATE TABLE t1 (id serial, data text);"
$PSQL -p $PORT -d postgres -c "INSERT INTO t1 (data) SELECT repeat('x', 1000) FROM generate_series(1,10000);"
$PSQL -p $PORT -d postgres -c "CHECKPOINT;"

echo "Stopping PostgreSQL..."
$PG_CTL -D "$PRIMARY_DATA" stop

echo "Resetting WAL forcibly using pg_resetwal..."
$PG_RESETWAL -D "$PRIMARY_DATA"

echo "Attempting to start PostgreSQL after WAL reset..."
$PG_CTL -D "$PRIMARY_DATA" -l "$LOG" start || echo "Server failed to start as expected due to TDE"


$PSQL -p $PORT -d postgres -c "SELECT count(*) FROM t1;"


echo "Done."
