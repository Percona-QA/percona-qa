#!/bin/bash

KEYFILE="$RUN_DIR/keyring.per"

# Cleanup from previous runs
old_server_cleanup $PGDATA
rm -rf "$ARCHIVE_DIR" "$BACKUP_DIR" "${PGDATA}_bk" "$KEYFILE"
mkdir -p "$ARCHIVE_DIR"

initialize_server $PGDATA $PORT

# Configure archive settings
echo "archive_mode = on" >> "$PGDATA/postgresql.conf"
echo "archive_command = 'cp %p $ARCHIVE_DIR/%f'" >> "$PGDATA/postgresql.conf"
echo "wal_compression = on" >> "$PGDATA/postgresql.conf"

enable_pg_tde $PGDATA
start_pg $PGDATA $PORT

echo "=== Step 3: Create extension, keys, and table ==="
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "CREATE TABLE t1(id SERIAL PRIMARY KEY, name TEXT) USING tde_heap;"
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO t1(name) VALUES('before backup 1'), ('before backup 2');"

echo "=== Step 4: Restart server to enable WAL encryption ==="
restart_pg $PGDATA $PORT

echo "=== Step 5: Take a base backup ==="
"$INSTALL_DIR/bin/pg_tde_basebackup" -D "$BACKUP_DIR" -F plain -X fetch -p $PORT

echo "=== Step 5.1: Insert and capture 5 recovery target times ==="
declare -A RECOVERY_TARGET_TIMES
for i in {1..5}; do
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO t1(name) VALUES('after backup recovery point $i');"
    sleep 2
    RECOVERY_TARGET_TIMES[$i]=$("$INSTALL_DIR/bin/psql" -d postgres -p $PORT -Atc "SELECT now();")
    echo "Captured recovery target time $i: ${RECOVERY_TARGET_TIMES[$i]}"
done

# Rotate the WAL key
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key2','global_provider')";
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key2','global_provider')";

# Force WAL switch
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_switch_wal();"
sleep 3

echo "=== Step 6: Simulate initial crash ==="
crash_pg $PGDATA $PORT

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
    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w start
    sleep 5

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
    crash_pg $PGDATA $PORT
done

echo "=== DONE: Completed 4 recovery iterations across timelines ==="
