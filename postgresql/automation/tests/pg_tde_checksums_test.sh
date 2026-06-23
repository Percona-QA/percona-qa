#!/bin/bash

# Configuration
KEYFILE="$RUN_DIR/checksum_test_keyring.file"

# Cleanup previous runs
old_server_cleanup $PGDATA

echo "1. Initializing cluster with checksums enabled..."
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA 

echo "2. Verifying a healthy cluster..."
$INSTALL_DIR/bin/pg_checksums -c -D "$PGDATA" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   [PASS] Healthy cluster verified with pg_checksums without encryption."
else
    echo "   [FAIL] Healthy cluster reported errors with pg_checksums without encryption."
    exit 1
fi


echo "3. Verifying a new cluster with pg_tde_checksums..."
$INSTALL_DIR/bin/pg_tde_checksums -c -D "$PGDATA" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   [PASS] New cluster verified with pg_tde_checksums without encryption."
else
    echo "   [FAIL] New cluster reported errors with pg_tde_checksums without encryption."
    exit 1
fi

echo "4. Starting the server"
start_pg $PGDATA $PORT

echo "5. Enable and update the pg_tde extension"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$KEYFILE');"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_keyring');"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_set_default_key_using_global_key_provider('wal_key','global_keyring');"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"
restart_pg $PGDATA $PORT

echo "6. Create test tables (encrypted and unencrypted)"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "CREATE TABLE test(id INT, val TEXT) USING tde_heap;"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "INSERT INTO test VALUES (1, 'before corruption');"
echo "6.1 Create unencrypted table test1"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "CREATE TABLE test1(id INT, val TEXT)USING heap;"
 $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "INSERT INTO test1 VALUES (1, 'before corruption');"

# Get database OID and table relfilenode for corruption test (while server is up)
DB_OID=$($INSTALL_DIR/bin/psql -d postgres -p $PORT -t -A -c "SELECT oid FROM pg_database WHERE datname = 'postgres';")
ENCRYPTED_RELFILENODE=$($INSTALL_DIR/bin/psql -d postgres -p $PORT -t -A -c "SELECT relfilenode FROM pg_class WHERE relname = 'test';")
UNENCRYPTED_RELFILENODE=$(psql -d postgres -p $PORT -t -A -c "SELECT relfilenode FROM pg_class WHERE relname = 'test1';")
ENCRYPTED_DATA_FILE="$PGDATA/base/$DB_OID/$ENCRYPTED_RELFILENODE"
UNENCRYPTED_DATA_FILE="$PGDATA/base/$DB_OID/$UNENCRYPTED_RELFILENODE"

echo "7. Running pg_tde_checksums to verify the checksums (before corruption)..."
stop_pg $PGDATA $PORT
CHECK_OUTPUT=$($INSTALL_DIR/bin/pg_tde_checksums -c -D "$PGDATA" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "   [FAIL] pg_tde_checksums failed to verify the checksums."
    echo "   Details: $(echo "$CHECK_OUTPUT" | grep "checksum verification failed" | tail -n 1)"
    exit 1
else
    echo "   [PASS] pg_tde_checksums verified the checksums."
fi

echo "8. Corrupting encrypted data file to verify pg_tde_checksums skips encrypted data file corruption..."
if [ ! -f "$ENCRYPTED_DATA_FILE" ]; then
    echo "   [FAIL] Encrypted data file not found: $ENCRYPTED_DATA_FILE"
    exit 1
fi

echo "=== DONE: pg_tde_checksums test completed ==="
