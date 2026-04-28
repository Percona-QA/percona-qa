#!/bin/bash

KEYFILE="$RUN_DIR/pg_tde_upgrade_global.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

echo "=== pg_tde pg_upgrade GLOBAL provider test ==="
echo "    Old cluster: PG-${OLD_MAJOR} at $OLD_INSTALL_DIR"
echo "    New cluster: PG-${NEW_MAJOR} at $NEW_INSTALL_DIR"

rm -f "$KEYFILE" || true

old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"

echo "1. Initializing old cluster (PG-${OLD_MAJOR})..."
initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"
start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

echo "2. Setting up pg_tde (GLOBAL key provider)..."
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_global_key_provider('global-key', 'global_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_key_using_global_key_provider('global-key', 'global_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_server_key_using_global_key_provider('global-key', 'global_provider');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE test_enc_global (k int primary key) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO test_enc_global VALUES (10),(20),(30);"

ROW_COUNT_BEFORE=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc_global;" | tr -d ' ')
echo "Rows before upgrade: $ROW_COUNT_BEFORE"

echo "3. Stopping old cluster..."
stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

echo "4. Initializing new cluster..."
initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
enable_pg_tde "$NEW_PGDATA"

echo "5. Running pg_upgrade..."
$NEW_INSTALL_DIR/bin/pg_tde_upgrade --no-sync \
  --old-datadir "$OLD_PGDATA" \
  --new-datadir "$NEW_PGDATA" \
  --old-bindir "$OLD_INSTALL_DIR/bin" \
  --new-bindir "$NEW_INSTALL_DIR/bin" \
  --socketdir "$RUN_DIR" \
  --old-port "$OLD_PORT" \
  --new-port "$NEW_PORT"

[ $? -ne 0 ] && echo "[FAIL] pg_upgrade failed" && exit 1

echo "6. Start new cluster..."
start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

ROW_COUNT_AFTER=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc_global;" | tr -d ' ')

if [ "$ROW_COUNT_AFTER" = "$ROW_COUNT_BEFORE" ]; then
    echo "[PASS] GLOBAL provider upgrade verified"
else
    echo "[FAIL] mismatch"
    exit 1
fi

stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"

echo "=== DONE: GLOBAL provider upgrade test ==="
