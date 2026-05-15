#!/bin/bash

KEYFILE="$RUN_DIR/pg_tde_upgrade.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

echo "=== Key rotation crash upgrade test ==="

rm -f "$KEYFILE" || true

old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"

initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"
start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_add_database_key_provider_file('kp', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('key1', 'kp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('key1', 'kp');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "CREATE TABLE t1(id int) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "INSERT INTO t1 SELECT generate_series(1,10000);"

echo "Rotating encryption key..."
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('key2', 'kp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('key2', 'kp');"

echo "Immediate crash after key rotation..."
$OLD_INSTALL_DIR/bin/pg_ctl -D "$OLD_PGDATA" stop -m immediate

echo "Restarting old cluster for crash recovery..."
start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

echo "Running CHECKPOINT after recovery..."
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres \
  -c "CHECKPOINT;"

echo "Stopping cluster cleanly..."
stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

if [[ "$OLD_MAJOR" == "17" && "$NEW_MAJOR" != "17" ]]; then
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

if [ $? -ne 0 ]; then
    echo "[FAIL] pg_tde_upgrade failed after crash"
    exit 1
fi

start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -c "SELECT count(*) FROM t1;"

# Cleanup
rm -f $WRAPPER_DIR/update_extensions.sql
rm -f $WRAPPER_DIR/delete_old_cluster.sh
