#!/bin/bash

KEYFILE="$RUN_DIR/pg_tde_upgrade.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

echo "=== pg_tde pg_upgrade test ==="
echo "    Old cluster: PG-${OLD_MAJOR} at $OLD_INSTALL_DIR"
echo "    New cluster: PG-${NEW_MAJOR} at $NEW_INSTALL_DIR"

# Remove key file so it is created fresh by the key provider
rm -f "$KEYFILE" || true

# Clean previous runs
old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"

echo "1. Initializing old cluster (PG-${OLD_MAJOR})..."
initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"
start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

echo "2. Setting up pg_tde (database key provider) and encrypted table..."
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_database_key_provider_file('key_provider', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_database_key_provider('test-db-key', 'key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_key_using_database_key_provider('test-db-key', 'key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE test_enc (k int, PRIMARY KEY (k)) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO test_enc (k) VALUES (1), (2);"

ROW_COUNT_BEFORE=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc;" 2>/dev/null | tr -d ' ')
echo "Rows in test_enc before upgrade: $ROW_COUNT_BEFORE"

echo "3. Stopping old cluster..."
stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

echo "4. Initializing new cluster (no start)..."
initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
enable_pg_tde "$NEW_PGDATA"

echo "5. Running pg_upgrade (PG-${OLD_MAJOR} -> PG-${NEW_MAJOR})..."
$NEW_INSTALL_DIR/bin/pg_tde_upgrade --no-sync \
  --old-datadir "$OLD_PGDATA" \
  --new-datadir "$NEW_PGDATA" \
  --old-bindir "$OLD_INSTALL_DIR/bin" \
  --new-bindir "$NEW_INSTALL_DIR/bin" \
  --socketdir "$RUN_DIR" \
  --old-port "$OLD_PORT" \
  --new-port "$NEW_PORT"

if [ $? -ne 0 ]; then
    echo "❌ pg_upgrade failed"
    echo "[FAIL] pg_upgrade failed"
    exit 1
fi
echo "[PASS] pg_upgrade completed"

cat >> "$NEW_PGDATA/postgresql.conf" <<EOF
port = $NEW_PORT
wal_level = replica
EOF

# ──────────────────────────────────────────────────────────
# Step 4 – Start new cluster and verify data
# ──────────────────────────────────────────────────────────
echo ""
echo "6. Starting new cluster and verifying data..."
start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"
$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -h "$PGHOST" -c "SELECT * FROM test_enc;"
if [ $? -ne 0 ]; then
    echo "❌ SELECT from test_enc failed on new cluster"
    stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"
fi

ROW_COUNT_AFTER=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc;" 2>/dev/null | tr -d ' ')

if [ "$ROW_COUNT_AFTER" = "$ROW_COUNT_BEFORE" ]; then
    echo "[PASS] Row count verified: $ROW_COUNT_AFTER rows in test_enc after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$ROW_COUNT_BEFORE after=$ROW_COUNT_AFTER"
    stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"
    exit 1
fi
stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"

echo "=== DONE: pg_tde pg_upgrade test completed ==="
