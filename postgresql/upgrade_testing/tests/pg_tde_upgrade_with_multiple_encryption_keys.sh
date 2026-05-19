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
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_database_key_provider_file('local_key_provider', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_global_key_provider_file('global_key_provider', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_database_key_provider('test-db-key1', 'local_key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_key_using_database_key_provider('test-db-key1', 'local_key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_global_key_provider('server-key', 'global_key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_server_key_using_global_key_provider('server-key', 'global_key_provider');"

# Create Normal encrypted tables
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE test_enc1 (k int, PRIMARY KEY (k)) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO test_enc1 (k) VALUES (1), (2);"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE db2;"

# Create Enc tables using a different key in Database db2
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "SELECT pg_tde_add_database_key_provider_file('local_key_provider2', '$KEYFILE');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "SELECT pg_tde_create_key_using_database_key_provider('test-db-key2', 'local_key_provider2');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "SELECT pg_tde_set_key_using_database_key_provider('test-db-key2', 'local_key_provider2');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "CREATE TABLE test_enc2 (k int, PRIMARY KEY (k)) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "INSERT INTO test_enc2 (k) VALUES (1), (2);"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db2 -h "$PGHOST" -c "CREATE DATABASE db3"

# Create Enc tables using global key provider key
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db3 -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db3 -h "$PGHOST" -c "SELECT pg_tde_create_key_using_global_key_provider('test-db-key3', 'global_key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db3 -h "$PGHOST" -c "SELECT pg_tde_set_key_using_global_key_provider('test-db-key3', 'global_key_provider');"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db3 -h "$PGHOST" -c "CREATE TABLE test_enc3 (k int, PRIMARY KEY (k)) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d db3 -h "$PGHOST" -c "INSERT INTO test_enc3 (k) VALUES (1), (2);"

# Create Partitioned encrypted tables
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE part_enc (id int) PARTITION BY RANGE(id) USING tde_heap;"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE part_enc_1 PARTITION OF part_enc FOR VALUES FROM (0) TO (100);"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE part_enc_2 PARTITION OF part_enc FOR VALUES FROM (100) TO (200);"
$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO part_enc VALUES (10),(20),(110),(120);"

ROW_COUNT_BEFORE1=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc1;" | tr -d ' ')
ROW_COUNT_BEFORE2=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d db2 -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc2;" | tr -d ' ')
ROW_COUNT_BEFORE3=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d db3 -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc3;" | tr -d ' ')
PARTITION_COUNT_BEFORE=$("$OLD_INSTALL_DIR/bin/psql" -p "$OLD_PORT" -d postgres -h "$RUN_DIR" -t -c "select count(*) from part_enc;" | tr -d ' ')

# Validate result
if [ -z "$ROW_COUNT_BEFORE1" ]; then
    echo "[FAIL] Could not get row count before upgrade"
    exit 1
fi

if [ -z "$ROW_COUNT_BEFORE2" ]; then
    echo "[FAIL] Could not get row count before upgrade"
    exit 1
fi

if [ -z "$ROW_COUNT_BEFORE3" ]; then
    echo "[FAIL] Could not get row count before upgrade"
    exit 1
fi

if [ -z "$PARTITION_COUNT_BEFORE" ]; then
    echo "[FAIL] Could not get row count before upgrade"
    exit 1
fi

echo "Rows in test_enc1 before upgrade: $ROW_COUNT_BEFORE1"
echo "Rows in test_enc2 before upgrade: $ROW_COUNT_BEFORE2"
echo "Rows in test_enc3 before upgrade: $ROW_COUNT_BEFORE3"
echo "Rows in part_enc before upgrade: $PARTITION_COUNT_BEFORE"

echo "3. Stopping old cluster..."
stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

echo "4. Initializing new cluster (no start)..."
if [[ "$OLD_MAJOR" == "17" && "$NEW_MAJOR" != "17" ]]; then
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
else
  initialize_server "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"
fi
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
    echo "[FAIL] pg_upgrade failed"
    exit 1
fi
echo "[PASS] pg_upgrade completed"

cat >> "$NEW_PGDATA/postgresql.conf" <<EOF
port = $NEW_PORT
wal_level = replica
EOF

echo "6. Starting new cluster and verifying data..."
start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"
$NEW_INSTALL_DIR/bin/psql -p "$NEW_PORT" -d postgres -h "$PGHOST" -c "SELECT * FROM test_enc1;"
if [ $? -ne 0 ]; then
    echo "❌ SELECT from test_enc failed on new cluster"
    stop_pg "$NEW_PGDATA" "$NEW_INSTALL_DIR"
    exit 1
fi

ROW_COUNT_AFTER1=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc1;" | tr -d ' ')
ROW_COUNT_AFTER2=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d db2 -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc2;" | tr -d ' ')
ROW_COUNT_AFTER3=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d db3 -h "$RUN_DIR" -t -c "SELECT count(*) FROM test_enc3;" | tr -d ' ')
PARTITION_COUNT_AFTER=$("$NEW_INSTALL_DIR/bin/psql" -p "$NEW_PORT" -d postgres -h "$RUN_DIR" -t -c "SELECT count(*) FROM part_enc;" | tr -d ' ')

# Validate result
if [ -z "$ROW_COUNT_AFTER1" ]; then
    echo "[FAIL] Could not get row count after upgrade"
    exit 1
fi

if [ -z "$ROW_COUNT_AFTER2" ]; then
    echo "[FAIL] Could not get row count after upgrade"
    exit 1
fi

if [ -z "$ROW_COUNT_AFTER3" ]; then
    echo "[FAIL] Could not get row count after upgrade"
    exit 1
fi

if [ -z "$PARTITION_COUNT_AFTER" ]; then
    echo "[FAIL] Could not get row count after upgrade"
    exit 1
fi

if [ "$ROW_COUNT_AFTER1" = "$ROW_COUNT_BEFORE1" ]; then
    echo "[PASS] Row count verified: $ROW_COUNT_AFTER1 rows in test_enc1 after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$ROW_COUNT_BEFORE1 after=$ROW_COUNT_AFTER1"
    exit 1
fi

if [ "$ROW_COUNT_AFTER2" = "$ROW_COUNT_BEFORE2" ]; then
    echo "[PASS] Row count verified: $ROW_COUNT_AFTER2 rows in test_enc1 after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$ROW_COUNT_BEFORE2 after=$ROW_COUNT_AFTER2"
    exit 1
fi

if [ "$ROW_COUNT_AFTER3" = "$ROW_COUNT_BEFORE3" ]; then
    echo "[PASS] Row count verified: $ROW_COUNT_AFTER3 rows in test_enc1 after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$ROW_COUNT_BEFORE3 after=$ROW_COUNT_AFTER3"
    exit 1
fi

if [ "$PARTITION_COUNT_AFTER" = "$PARTITION_COUNT_BEFORE" ]; then
    echo "[PASS] Row count verified: $PARTITION_COUNT_AFTER rows in test_enc after upgrade"
else
    echo "[FAIL] Row count mismatch: before=$PARTITION_COUNT_BEFORE after=$PARTITION_COUNT_AFTER"
    exit 1
fi

# Cleanup
rm -f $WRAPPER_DIR/update_extensions.sql
rm -f $WRAPPER_DIR/delete_old_cluster.sh
echo "=== DONE: pg_tde pg_upgrade test completed ==="
