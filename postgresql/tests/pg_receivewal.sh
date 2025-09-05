#!/bin/bash

# CONFIGURATION
INSTALL_DIR="$HOME/postgresql/bld_17.6/install"
PGDATA="$INSTALL_DIR/data"
LOGFILE=$PGDATA/server.log
ARCHIVE_DIR="$INSTALL_DIR/wal_archive"
BACKUP_DIR="$INSTALL_DIR/base_backup"
PORT=5432
REPL_USER="repl_user"
REPL_PASS="secret"
SLOT="pitr_slot"

# Cleanup from previous runs
PID=$(lsof -ti :$PORT)
if [ -n "$PID" ]; then
    kill -9 $PID
fi
pkill -9 -x pg_receivewal
rm -rf "$PGDATA" "$ARCHIVE_DIR" "$BACKUP_DIR" "${PGDATA}_bk" "/tmp/keyring.per"
mkdir -p "$ARCHIVE_DIR"

echo "=== Step 1: Initialize primary server ==="
"$INSTALL_DIR/bin/initdb" -D "$PGDATA"

# Configure settings
echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
echo "wal_level = replica" >> "$PGDATA/postgresql.conf"
echo "max_wal_senders = 5" >> "$PGDATA/postgresql.conf"
echo "wal_compression = on" >> "$PGDATA/postgresql.conf"
echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
echo "port = $PORT" >> "$PGDATA/postgresql.conf"
echo "logging_collector = on" >> "$PGDATA/postgresql.conf"
echo "log_directory = '$PGDATA'" >> "$PGDATA/postgresql.conf"
echo "log_filename = 'server.log'" >> "$PGDATA/postgresql.conf"
echo "log_statement = 'all'" >> "$PGDATA/postgresql.conf"

echo "=== Step 2: Start PostgreSQL server ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w start
sleep 2

# Create replication user & slot for pg_receivewal
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE ROLE $REPL_USER WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_create_physical_replication_slot('$SLOT');"

# Start pg_receivewal in background
PGPASSFILE=$(mktemp)
echo "localhost:$PORT:*:$REPL_USER:$REPL_PASS" > "$PGPASSFILE"
chmod 600 "$PGPASSFILE"
PGPASSFILE=$PGPASSFILE "$INSTALL_DIR/bin/pg_receivewal" -D "$ARCHIVE_DIR" -h localhost -p $PORT -U $REPL_USER --slot=$SLOT > "$ARCHIVE_DIR/pg_receivewal.log" 2>&1 &
PG_RECEIVEWAL_PID=$!
echo "Started pg_receivewal with PID $PG_RECEIVEWAL_PID"

echo "=== Step 3: Create extension, keys, and table ==="
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '/tmp/keyring.per');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE TABLE t1(id SERIAL PRIMARY KEY, name TEXT) USING tde_heap;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO t1(name) VALUES('before backup 1'), ('before backup 2');"

echo "=== Step 4: Restart server to enable WAL encryption ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart
sleep 2

echo "=== Step 5: Take a base backup ==="
mkdir $BACKUP_DIR
chmod 700 $BACKUP_DIR
cp -R $PGDATA/pg_tde $BACKUP_DIR
"$INSTALL_DIR/bin/pg_basebackup" -D "$BACKUP_DIR" -F plain -X stream -E  -p $PORT

echo "=== Step 5.1: Insert and capture 5 recovery target times ==="
declare -A RECOVERY_TARGET_TIMES
for i in {1..5}; do
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO t1(name) VALUES('after backup recovery point $i');"
    sleep 2
    RECOVERY_TARGET_TIMES[$i]=$("$INSTALL_DIR/bin/psql" -d postgres -p $PORT -Atc "SELECT now();")
    echo "Captured recovery target time $i: ${RECOVERY_TARGET_TIMES[$i]}"
done

# Rotate the WAL key
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key2','global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key2','global_provider');"

# Force WAL switch
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_switch_wal();"
sleep 3

echo "=== Step 6: Simulate initial crash ==="
pkill -9 postgres
sleep 2

for i in {1..4}; do
    echo "=== Recovery iteration $i ==="

    # Clean old data
    rm -rf "$PGDATA"
    cp -r "$BACKUP_DIR" "$PGDATA"

    # Reset postgresql.conf (remove previous recovery settings if any)
    sed -i '/restore_command/d' "$PGDATA/postgresql.conf"
    sed -i '/recovery_target_time/d' "$PGDATA/postgresql.conf"

    # Add new recovery settings
    echo "restore_command = 'cp $ARCHIVE_DIR/%f %p'" >> "$PGDATA/postgresql.conf"
    echo "recovery_target_time = '${RECOVERY_TARGET_TIMES[$i]}'" >> "$PGDATA/postgresql.conf"
    touch "$PGDATA/recovery.signal"

    echo "Starting PostgreSQL in recovery mode for iteration $i..."
    if ! "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w start; then
      echo "[ERROR]: Failed to start PostgreSQL on port $PORT. Exiting..."
      echo "Check Logs: $PGDATA/server.log"
      exit 1
    fi

    echo "=== Promote the server ==="
    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" promote
    sleep 3

    echo "=== Insert post-promotion data ==="
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE TABLE IF NOT EXISTS t_recovery_$i (id INT PRIMARY KEY, name TEXT) USING tde_heap;"
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO t_recovery_$i VALUES ($i, 'recovery_$i');"

    echo "=== Verify post-promotion data ==="
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT * FROM t_recovery_$i;"
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT * FROM t1;"
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_is_encrypted('t_recovery_$i');"
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_is_encrypted('t1');"

    echo "=== Simulate crash after iteration $i ==="
    pkill -9 postgres
    sleep 2
done

# Stop pg_receivewal
kill $PG_RECEIVEWAL_PID
rm -f "$PGPASSFILE"

echo "=== DONE: Completed 5 recovery iterations across timelines ==="

