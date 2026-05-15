#!/bin/bash

KEYFILE="$RUN_DIR/wal_mismatch.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

echo "=== WAL encryption mismatch upgrade ==="

rm -f "$KEYFILE" || true

old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"

initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"

start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_add_global_key_provider_file('gkp', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key1', 'gkp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('key1', 'gkp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('key2', 'gkp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('key2', 'gkp');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "SHOW pg_tde.wal_encrypt;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "CREATE TABLE t1(id int) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -c "INSERT INTO t1 SELECT generate_series(1,10000);"

stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

if [[ "$OLD_MAJOR" == "17" && "$NEW_MAJOR" != "17" ]]; then
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
else
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"
fi

enable_pg_tde "$NEW_PGDATA"

cat >> "$NEW_PGDATA/postgresql.conf" <<EOF
pg_tde.wal_encrypt = off
EOF

$NEW_INSTALL_DIR/bin/pg_tde_upgrade \
 --old-datadir "$OLD_PGDATA" \
 --new-datadir "$NEW_PGDATA" \
 --old-bindir "$OLD_INSTALL_DIR/bin" \
 --new-bindir "$NEW_INSTALL_DIR/bin" \
 --socketdir "$RUN_DIR" \
 --old-port "$OLD_PORT" \
 --new-port "$NEW_PORT"

if [ $? -ne 0 ]; then
    echo "[FAIL] Upgrade failed unexpectedly"
    exit 1
fi

start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -c "ALTER EXTENSION "pg_tde" UPDATE;"
$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -c "SELECT count(*) FROM t1;"
$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -c "SHOW pg_tde.wal_encrypt;"

# Cleanup
rm -f $WRAPPER_DIR/update_extensions.sql
rm -f $WRAPPER_DIR/delete_old_cluster.sh
