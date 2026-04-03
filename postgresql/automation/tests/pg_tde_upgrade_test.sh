#!/bin/bash

# pg_tde pg_upgrade test: upgrade an old cluster (with pg_tde + encrypted table) to a new cluster.
#
# Cross-version usage (e.g. PG-17 -> PG-18):
#   ./test_runner.sh --server_build_path /opt/pg18 \
#                    --old_server_build_path /opt/pg17 \
#                    --testname pg_tde_upgrade_test.sh
#
# Same-version usage (OLD_INSTALL_DIR falls back to INSTALL_DIR automatically):
#   ./test_runner.sh --server_build_path /opt/pg18 \
#                    --testname pg_tde_upgrade_test.sh

OLD_DATA="$RUN_DIR/pg_upgrade_old"
NEW_DATA="$RUN_DIR/pg_upgrade_new"
OLD_PORT="${OLD_PORT:-5435}"
NEW_PORT="${NEW_PORT:-5436}"
KEYFILE="$RUN_DIR/pg_tde_upgrade.key"
IO_METHOD="${IO_METHOD:-worker}"

# OLD_INSTALL_DIR is set in env.sh; defaults to INSTALL_DIR when --old_server_build_path is omitted.
OLD_BIN="${OLD_INSTALL_DIR:-$INSTALL_DIR}/bin"
NEW_BIN="$INSTALL_DIR/bin"

OLD_MAJOR=$(get_pg_major_version_from_dir "$OLD_BIN")
NEW_MAJOR=$(get_pg_major_version_from_dir "$NEW_BIN")

echo "=== pg_tde pg_upgrade test ==="
echo "    Old cluster: PG-${OLD_MAJOR} at $OLD_BIN"
echo "    New cluster: PG-${NEW_MAJOR} at $NEW_BIN"

# Remove key file so it is created fresh by the key provider
rm -f "$KEYFILE"

# Clean previous runs
old_server_cleanup "$OLD_DATA" "$OLD_PORT"
old_server_cleanup "$NEW_DATA" "$NEW_PORT"
rm -rf "$OLD_DATA" "$NEW_DATA" || true

# ──────────────────────────────────────────────────────────
# Step 1 – Initialize and populate the old cluster
# ──────────────────────────────────────────────────────────
echo ""
echo "1. Initializing old cluster (PG-${OLD_MAJOR})..."
"$OLD_BIN/initdb" -D "$OLD_DATA" \
    --set shared_preload_libraries=pg_tde \
    --set unix_socket_directories="$RUN_DIR" \
    > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[FAIL] initdb failed for old cluster"
    exit 1
fi

# pg_upgrade requires wal_level >= replica in the old cluster
cat >> "$OLD_DATA/postgresql.conf" <<EOF
port = $OLD_PORT
wal_level = replica
EOF

start_pg_with_dir "$OLD_BIN" "$OLD_DATA" "$OLD_PORT"

echo "2. Setting up pg_tde (database key provider) and encrypted table..."
"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1

"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "SELECT pg_tde_add_database_key_provider_file('file-vault', '$KEYFILE');" > /dev/null 2>&1

"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "SELECT pg_tde_create_key_using_database_key_provider('test-db-key', 'file-vault');" > /dev/null 2>&1

"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "SELECT pg_tde_set_key_using_database_key_provider('test-db-key', 'file-vault');" > /dev/null 2>&1

"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "CREATE TABLE test_enc (k int PRIMARY KEY) USING tde_heap;" > /dev/null 2>&1

"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -c "INSERT INTO test_enc VALUES (1), (2), (3);" > /dev/null 2>&1

ROW_COUNT_BEFORE=$("$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" \
    -t -c "SELECT count(*) FROM test_enc;" 2>/dev/null | tr -d ' ')
echo "    Rows in test_enc before upgrade: $ROW_COUNT_BEFORE"

echo "3. Stopping old cluster..."
stop_pg_with_dir "$OLD_BIN" "$OLD_DATA"

# ──────────────────────────────────────────────────────────
# Step 2 – Initialize the new (empty) cluster
# ──────────────────────────────────────────────────────────
echo ""
echo "4. Initializing new cluster (PG-${NEW_MAJOR})..."
IO_FLAG=""
if [[ "$NEW_MAJOR" -ge 18 ]]; then
    IO_FLAG="--set io_method=$IO_METHOD"
fi

"$NEW_BIN/initdb" -D "$NEW_DATA" \
    --set shared_preload_libraries=pg_tde \
    --set unix_socket_directories="$RUN_DIR" \
    $IO_FLAG \
    > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[FAIL] initdb failed for new cluster"
    exit 1
fi

cat >> "$NEW_DATA/postgresql.conf" <<EOF
port = $NEW_PORT
wal_level = replica
EOF

# ──────────────────────────────────────────────────────────
# Step 3 – Run pg_upgrade
# ──────────────────────────────────────────────────────────
echo ""
echo "5. Running pg_upgrade (PG-${OLD_MAJOR} -> PG-${NEW_MAJOR})..."
"$NEW_BIN/pg_upgrade" --no-sync \
    --old-datadir "$OLD_DATA" \
    --new-datadir "$NEW_DATA" \
    --old-bindir "$OLD_BIN" \
    --new-bindir "$NEW_BIN" \
    --socketdir "$RUN_DIR" \
    --old-port "$OLD_PORT" \
    --new-port "$NEW_PORT"

if [ $? -ne 0 ]; then
    echo "[FAIL] pg_upgrade failed"
    exit 1
fi
echo "[PASS] pg_upgrade completed"

# Carry over the pg_tde key directory so the new cluster can read encrypted data.
# pg_upgrade copies relation files but pg_tde's internal key store lives in $PGDATA/pg_tde.
if [ ! -d "$NEW_DATA/pg_tde" ] && [ -d "$OLD_DATA/pg_tde" ]; then
    echo "    Copying pg_tde key directory from old cluster to new cluster..."
    cp -R "$OLD_DATA/pg_tde" "$NEW_DATA/pg_tde"
fi

# ──────────────────────────────────────────────────────────
# Step 4 – Start new cluster and verify data
# ──────────────────────────────────────────────────────────
echo ""
echo "6. Starting new cluster and verifying data..."
start_pg_with_dir "$NEW_BIN" "$NEW_DATA" "$NEW_PORT"

ROW_COUNT_AFTER=$("$NEW_BIN/psql" -p "$NEW_PORT" -d postgres -h "$RUN_DIR" \
    -t -c "SELECT count(*) FROM test_enc;" 2>/dev/null | tr -d ' ')

if [ "$ROW_COUNT_AFTER" = "$ROW_COUNT_BEFORE" ]; then
    echo "[PASS] Row count verified: $ROW_COUNT_AFTER rows in test_enc after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$ROW_COUNT_BEFORE after=$ROW_COUNT_AFTER"
    stop_pg_with_dir "$NEW_BIN" "$NEW_DATA"
    exit 1
fi

# Run the post-upgrade analyze script generated by pg_upgrade
if [ -f "analyze_new_cluster.sh" ]; then
    echo "    Running post-upgrade ANALYZE..."
    bash analyze_new_cluster.sh > /dev/null 2>&1
fi

stop_pg_with_dir "$NEW_BIN" "$NEW_DATA"

# Cleanup pg_upgrade generated scripts
rm -f delete_old_cluster.sh analyze_new_cluster.sh

echo ""
echo "=== DONE: pg_tde pg_upgrade test completed ==="
