#!/bin/bash

# CONFIGURATION
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
rm -rf /dev/shm/*
mkdir -p "$ARCHIVE_DIR"

echo "=== Step 1: Initialize primary server ==="
"$INSTALL_DIR/bin/initdb" -D "$PGDATA"

# Configure archive settings
echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
echo "io_method = 'sync'" >> "$PGDATA/postgresql.conf"
echo "archive_mode = on" >> "$PGDATA/postgresql.conf"
echo "archive_command = '$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $ARCHIVE_DIR/%%f\"'" >> "$PGDATA/postgresql.conf"
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
"$INSTALL_DIR/bin/pg_tde_basebackup" -D "$BACKUP_DIR" -F plain -X stream -E -p $PORT

echo "=== Step 5.1: Insert and capture 5 recovery target times ==="
declare -A RECOVERY_TARGET_TIMES
for i in {1..5}; do
    "$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "INSERT INTO mohit(name) VALUES('after backup $i');"
    sleep 2
    RECOVERY_TARGET_TIMES[$i]=$("$INSTALL_DIR/bin/psql" -d postgres -p $PORT -Atc "SELECT now();")
    echo "Captured recovery target time $i: ${RECOVERY_TARGET_TIMES[$i]}"
done

# Switch WAL & force archive
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_switch_wal();"
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart

############################################################
### === TEST A: No temp files after successful archive ===
############################################################
echo "=== TEST A: Checking that no temp files remain after success ==="
if ls /dev/shm | grep -q pg_tde; then
    echo "ERROR: Temp files leaked on success"
    exit 1
else
    echo "OK: No temp files on success"
fi

###############################################################
### === TEST B: Cleanup on failure of wrapped archive cmd ===
###############################################################
echo "=== TEST B: Cleanup on failure of archive command ==="

sed -i "s|cp %%p $ARCHIVE_DIR/%%f|false|" $PGDATA/postgresql.conf
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart

"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT pg_switch_wal();"
sleep 2

if ls /dev/shm | grep -q pg_tde; then
    echo "ERROR: Temp files leaked on wrapped-command failure"
    exit 1
else
    echo "OK: Cleanup successful on failure"
fi

# Restore original archive_command
sed -i "s|false|cp %%p $ARCHIVE_DIR/%%f|" $PGDATA/postgresql.conf
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w restart

###############################################################
### === TEST C: ENOSPC behavior (/dev/shm full) ===
###############################################################
echo "=== TEST C: Insufficient tmpfs capacity (ENOSPC test) ==="
rm -rf /tmp/fake_wal
touch /tmp/fake_wal
dd if=/dev/urandom of=/tmp/fake_wal bs=1M count=1

# Fill /dev/shm until ENOSPC
echo "Filling /dev/shm..."
counter=0
while :; do
    dd if=/dev/urandom of=/dev/shm/fill_$counter bs=1M count=50 2>/dev/null || break
    counter=$((counter+1))
done
echo "/dev/shm filled, running pg_tde_archive_decrypt..."

set +e
$INSTALL_DIR/bin/pg_tde_archive_decrypt /tmp/fake_wal /tmp/fake_out "cp %f %p"
RET=$?
set -e

if [ $RET -eq 0 ]; then
  echo "pg_tde_archive_decrypt command is successful"
else
  echo "ERROR: Not successful"
  exit 1
fi

# Cleaning up tmpfs
rm -f /dev/shm/fill_*

###############################################################
### === TEST D: Multiple retries do NOT leak ===
###############################################################
echo "=== TEST D: Multiple retry stress test ==="

for i in {1..8}; do
    set +e
    $INSTALL_DIR/bin/pg_tde_archive_decrypt /tmp/fake_wal /tmp/fake_out "false"
    set -e

    if ls /dev/shm | grep -q pg_tde; then
        echo "ERROR: Leak on retry $i!"
        exit 1
    fi
done

echo "OK: No leaks after repeated failures"

echo "=== Printing WAL content from $ARCHIVE_DIR using strings utility ==="
strings $ARCHIVE_DIR/000000010000000000000001 | grep 'before backup'

echo "=== Perform recovery ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w stop

rm -rf "$PGDATA"
cp -r "$BACKUP_DIR" "$PGDATA"

sed -i '/restore_command/d' "$PGDATA/postgresql.conf"
sed -i '/recovery_target_time/d' "$PGDATA/postgresql.conf"

echo "restore_command = '$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"cp $ARCHIVE_DIR/%%f %%p\"'" >> "$PGDATA/postgresql.conf"
echo "recovery_target_time = '${RECOVERY_TARGET_TIMES[4]}'" >> "$PGDATA/postgresql.conf"
touch "$PGDATA/recovery.signal"

"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -o "-p $PORT" -w start
sleep 5

echo "=== Promote the server ==="
"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" promote
sleep 3

echo "=== Verify post-promotion data ==="
"$INSTALL_DIR/bin/psql" -d postgres -p $PORT -c "SELECT * FROM mohit;"

