#!/bin/bash

KEYFILE="$RUN_DIR/pg_tde_upgrade_pitr.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

echo "=== pg_tde pg_upgrade PITR test (encrypted WAL) ==="

rm -f "$KEYFILE" || true
rm -rf "$RUN_DIR/archive" "$RUN_DIR/backup_pitr"

mkdir -p "$RUN_DIR/archive"

#############################################
# 1. INIT OLD CLUSTER
#############################################
echo "1. Initializing old cluster..."
old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"

echo "archive_mode=on" >> "$OLD_PGDATA/postgresql.conf"
echo "archive_command='$OLD_INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $RUN_DIR/archive/%%f\"'" >> "$OLD_PGDATA/postgresql.conf"

start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

psql_old="$OLD_INSTALL_DIR/bin/psql -p $OLD_PORT -h $PGHOST -d postgres"

#############################################
# 2. SETUP TDE
#############################################
echo "2. Setting up pg_tde on PG$OLD_MAJOR..."

$psql_old -c "CREATE EXTENSION pg_tde;"
$psql_old -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
$psql_old -c "SELECT pg_tde_create_key_using_global_key_provider('global-key', 'global_provider');"
$psql_old -c "SELECT pg_tde_set_key_using_global_key_provider('global-key', 'global_provider');"
$psql_old -c "SELECT pg_tde_set_server_key_using_global_key_provider('global-key', 'global_provider');"

#############################################
# 3. CREATE DATA
#############################################
echo "3. Creating data on PG$OLD_MAJOR..."

$psql_old -c "CREATE TABLE test_enc_pitr (id int primary key) USING tde_heap;"
$psql_old -c "INSERT INTO test_enc_pitr VALUES (1),(2),(3);"

#############################################
# 4. STOP + UPGRADE
#############################################
echo "4. Upgrading to PG$NEW_MAJOR..."

stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"
if [ "$OLD_MAJOR" == "17" ]; then
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
else
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"
fi
enable_pg_tde "$NEW_PGDATA"

$NEW_INSTALL_DIR/bin/pg_tde_upgrade --no-sync \
  --old-datadir "$OLD_PGDATA" \
  --new-datadir "$NEW_PGDATA" \
  --old-bindir "$OLD_INSTALL_DIR/bin" \
  --new-bindir "$NEW_INSTALL_DIR/bin" \
  --socketdir "$RUN_DIR" \
  --old-port "$OLD_PORT" \
  --new-port "$NEW_PORT"

###############################################
# 5. Enable WAL archiving in (PG18)           
# #############################################
echo "archive_mode=on" >> "$NEW_PGDATA/postgresql.conf"
echo "archive_command='$NEW_INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $RUN_DIR/archive/%%f\"'" >> "$NEW_PGDATA/postgresql.conf"

#############################################
# 6. START NEW CLUSTER (PG18)
#############################################
echo "6. Starting PG$NEW_MAJOR..."

start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

psql_new="$NEW_INSTALL_DIR/bin/psql -p $NEW_PORT -h $RUN_DIR -d postgres"

#############################################
# 7. ENABLE WAL ENCRYPTION
#############################################
echo "7. Enabling WAL encryption..."

$psql_new -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

#############################################
# 8. TAKE BASE BACKUP (PG18) ✅
#############################################
echo "8. Taking base backup (PG18)..."

mkdir $RUN_DIR/backup_pitr
chmod 700 $RUN_DIR/backup_pitr
cp -R "$NEW_PGDATA/pg_tde" "$RUN_DIR/backup_pitr/"

$NEW_INSTALL_DIR/bin/pg_tde_basebackup -D "$RUN_DIR/backup_pitr" -X stream -c fast -E -h "$PGHOST" -p "$NEW_PORT"

#############################################
# 9. GENERATE WAL (PG18)
#############################################
echo "8. Generating WAL..."

$psql_new -c "INSERT INTO test_enc_pitr VALUES (4),(5),(6);"
sleep 2

RECOVERY_TARGET_TIME=$($psql_new -At -c "SELECT now();")
echo "Recovery target time: $RECOVERY_TARGET_TIME"
sleep 2

$psql_new -c "INSERT INTO test_enc_pitr VALUES (7),(8);"

# Force WAL switch
$psql_new -c "SELECT pg_switch_wal();"

# Force checkpoint (very important)
$psql_new -c "CHECKPOINT;"

# Wait a bit to ensure archive_command finishes
sleep 10

stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"

#############################################
# 9. PITR (PG18 backup + WAL) ✅
#############################################
echo "9. Performing PITR..."

rm -rf "$NEW_PGDATA"
cp -r "$RUN_DIR/backup_pitr" "$NEW_PGDATA"

echo "restore_command='$NEW_INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"cp $RUN_DIR/archive/%%f %%p\"'" >> "$NEW_PGDATA/postgresql.conf"
echo "recovery_target_time='$RECOVERY_TARGET_TIME'" >> "$NEW_PGDATA/postgresql.conf"
echo "recovery_target_action='promote'" >> "$NEW_PGDATA/postgresql.conf"

touch "$NEW_PGDATA/recovery.signal"

#############################################
# 10. START RECOVERY
#############################################
echo "10. Starting recovered cluster..."

start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

#############################################
# 11. VALIDATION
#############################################
echo "11. Validating..."

ROW_COUNT=$($psql_new -At -c "SELECT count(*) FROM test_enc_pitr;")

echo "Recovered row count: $ROW_COUNT"

if [ "$ROW_COUNT" -eq 6 ]; then
    echo "[PASS] PITR after upgrade with encrypted WAL successful"
else
    echo "[FAIL] Expected 6 rows, got $ROW_COUNT"
    exit 1
fi

echo "Checking SELECT..."
$psql_new -c "SELECT * FROM test_enc_pitr LIMIT 1;" > /dev/null

stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"

echo "=== DONE ==="
