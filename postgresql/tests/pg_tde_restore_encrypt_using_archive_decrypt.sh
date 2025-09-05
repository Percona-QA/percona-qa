#!/bin/bash

# CONFIGURATION
INSTALL_DIR="$HOME/postgresql/bld_17.6/install"
PGDATA="$INSTALL_DIR/data"
LOGFILE=$PGDATA/server.log
ARCHIVE_DIR="$INSTALL_DIR/wal_archive"
BACKUP_DIR="$INSTALL_DIR/base_backup"
PORT=5432

# Cleanup from previous runs
PID=$(lsof -ti :$PORT)
if [ -n "$PID" ]; then
    kill -9 $PID
fi
rm -rf "$PGDATA" "$ARCHIVE_DIR" "$BACKUP_DIR" "${PGDATA}_bk" "/tmp/keyring.per"
mkdir -p "$ARCHIVE_DIR"

echo "=== Step 1: Initialize primary server ==="
"$INSTALL_DIR/bin/initdb" -D "$PGDATA"

# Configure archive settings
echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
echo "archive_mode = on" >> "$PGDATA/postgresql.conf"
echo "archive_command = '$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $ARCHIVE_DIR/%%f\"'" >> "$PGDATA/postgresql.conf"
#echo "archive_command = 'cp %p $ARCHIVE_DIR/%f'" >> "$PGDATA/postgresql.conf"
echo "wal_level = replica" >> "$PGDATA/postgresql.conf"
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

echo "=== Step 3: Create extension, keys, and table ==="
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '/tmp/keyring.per');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE TABLE mohit(id SERIAL PRIMARY KEY, name TEXT) USING tde_heap;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO mohit(name) VALUES('before backup 1'), ('before backup 2');"

echo "=== Step 4: Restart server to enable WAL encryption ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart

sleep 2

echo "=== Step 5: Take a base backup ==="
mkdir $BACKUP_DIR
chmod 700 $BACKUP_DIR
cp -R $PGDATA/pg_tde $BACKUP_DIR/
"$INSTALL_DIR/bin/pg_basebackup" -D "$BACKUP_DIR" -F plain -X stream -E -p $PORT

echo "=== Step 5.1: Insert and capture 5 recovery target times ==="
declare -A RECOVERY_TARGET_TIMES
for i in {1..5}; do
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO mohit(name) VALUES('after backup $i');"
    sleep 2
    RECOVERY_TARGET_TIMES[$i]=$("$INSTALL_DIR/bin/psql" -d postgres -p $PORT -Atc "SELECT now();")
    echo "Captured recovery target time $i: ${RECOVERY_TARGET_TIMES[$i]}"
done

# Making sure all WAL files are archived
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_switch_wal();"
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart

echo "=== Step 6: Printing WAL content from $ARCHIVE_DIR using strings utility"
strings $ARCHIVE_DIR/000000010000000000000001 | grep 'before backup'
strings $ARCHIVE_DIR/000000010000000000000001 | grep 'after backup'
strings $ARCHIVE_DIR/000000010000000000000002 | grep 'after backup'
strings $ARCHIVE_DIR/000000010000000000000003 | grep 'after backup'
strings $ARCHIVE_DIR/000000010000000000000004 | grep 'after backup'


echo "=== Step 7: Perform recovery"
# Stop server
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w stop

# Clean old data
rm -rf "$PGDATA"
cp -r "$BACKUP_DIR" "$PGDATA"

# Reset postgresql.conf (remove previous recovery settings if any)
sed -i '/restore_command/d' "$PGDATA/postgresql.conf"
sed -i '/recovery_target_time/d' "$PGDATA/postgresql.conf"

# Add new recovery settings
echo "restore_command = '$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"cp $ARCHIVE_DIR/%%f %%p\"'" >> "$PGDATA/postgresql.conf"
echo "recovery_target_time = '${RECOVERY_TARGET_TIMES[4]}'" >> "$PGDATA/postgresql.conf"
touch "$PGDATA/recovery.signal"

$INSTALL_DIR/bin/pg_ctl -D "$PGDATA" -o "-p $PORT" -w start
sleep 5

echo "=== Promote the server ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" promote
sleep 3

echo "=== Verify post-promotion data ==="
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT * FROM mohit;"
