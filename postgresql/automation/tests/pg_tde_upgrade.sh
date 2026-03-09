#!/bin/bash

# pg_tde pg_upgrade test: upgrade from old cluster (with pg_tde + encrypted table) to new cluster.

OLD_DATA="$RUN_DIR/pg_upgrade_old"
NEW_DATA="$RUN_DIR/pg_upgrade_new"
OLD_PORT="${OLD_PORT:-5435}"
NEW_PORT="${NEW_PORT:-5436}"
KEYFILE="$RUN_DIR/pg_tde_upgrade.key"
IO_METHOD="${IO_METHOD:-worker}"

# Remove key file so it is created fresh by the key provider (matches Perl unlink)
rm -f "$KEYFILE"

# Clean previous runs
old_server_cleanup "$OLD_DATA"
old_server_cleanup "$NEW_DATA"
rm -rf "$OLD_DATA" "$NEW_DATA" || true

echo "1. Initializing old cluster..."
$INSTALL_DIR/bin/initdb -D "$OLD_DATA" --set shared_preload_libraries=pg_tde --set io_method=$IO_METHOD --set unix_socket_directories="$RUN_DIR" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: initdb failed."
    exit 1
fi
start_pg "$OLD_DATA" "$OLD_PORT"

echo "2. Setting up pg_tde (database key provider) and encrypted table..."
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_database_key_provider_file('file-vault', '$KEYFILE');"
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_database_key_provider('test-db-key', 'file-vault');"
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_key_using_database_key_provider('test-db-key', 'file-vault');"
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE test_enc (k int, PRIMARY KEY (k)) USING tde_heap;"
$INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO test_enc (k) VALUES (1), (2);"

echo "3. Stopping old cluster..."
stop_pg "$OLD_DATA"

echo "4. Initializing new cluster (no start)..."
$INSTALL_DIR/bin/initdb -D "$NEW_DATA" --set shared_preload_libraries=pg_tde --set io_method=$IO_METHOD --set unix_socket_directories="$RUN_DIR" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: initdb failed."
    exit 1
fi

echo "5. Running pg_upgrade..."
$INSTALL_DIR/bin/pg_upgrade --no-sync \
  --old-datadir "$OLD_DATA" \
  --new-datadir "$NEW_DATA" \
  --old-bindir "$INSTALL_DIR/bin" \
  --new-bindir "$INSTALL_DIR/bin" \
  --socketdir "$RUN_DIR" \
  --old-port "$OLD_PORT" \
  --new-port "$NEW_PORT"

if [ $? -ne 0 ]; then
    echo "❌ pg_upgrade failed"
    exit 1
fi

# Optional: if new cluster fails to start due to pg_tde keys, copy old pg_tde dir (see Perl TODO)
# rm -rf "$NEW_DATA/pg_tde"
# cp -R "$OLD_DATA/pg_tde" "$NEW_DATA/pg_tde"

echo "6. Starting new cluster and verifying data..."
start_pg "$NEW_DATA" "$NEW_PORT"
$INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -h "$PGHOST" -c "SELECT * FROM test_enc;"
if [ $? -ne 0 ]; then
    echo "❌ SELECT from test_enc failed on new cluster"
    stop_pg "$NEW_DATA"
    exit 1
fi
stop_pg "$NEW_DATA"

echo "=== DONE: pg_tde pg_upgrade test completed ==="
