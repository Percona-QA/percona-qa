#!/bin/bash

# Configuration
TEST_DIR="$RUN_DIR/pg_checksum_test"
PGDATA="$TEST_DIR/data"
PORT=55532 # Port for the server
KEYFILE="$TEST_DIR/checksum_test_keyring.file"
IO_METHOD="${IO_METHOD:-worker}"


# Cleanup previous runs
rm -rf "$TEST_DIR"  || true
mkdir -p "$TEST_DIR"

echo "1. Initializing cluster with checksums enabled..."
$INSTALL_DIR/bin/initdb -k -D "$PGDATA" --set shared_preload_libraries=pg_tde --set io_method=$IO_METHOD > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: initdb failed."
    exit 1
fi

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
# Corrupt 16 bytes in the first data page (offset 100 is past page header) so checksum will fail
dd if=/dev/urandom of="$ENCRYPTED_DATA_FILE" bs=1 count=16 seek=100 conv=notrunc 2>/dev/null
if [ $? -ne 0 ]; then
    echo "   [FAIL] Failed to corrupt encrypted data file."
    exit 1
fi
echo "   Corrupted encrypted data file $ENCRYPTED_DATA_FILE (16 bytes at offset 100)."

echo "9. Running pg_tde_checksums again (expect checksum pass)..."
CHECK_OUTPUT=$($INSTALL_DIR/bin/pg_tde_checksums -c -D "$PGDATA" 2>&1)
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "   [FAIL] pg_tde_checksums failed to skip the checksums of encrypted data file corruption."
    echo "   Details: $(echo "$CHECK_OUTPUT" | grep "checksum verification failed" | tail -n 1)"
    exit 1
else
    echo "   [PASS] pg_tde_checksums skipped the checksums of encrypted data file corruption."
fi

echo "10. Corrupting unencrypted data file to verify pg_tde_checksums detects unencrypted data file corruption..."
if [ ! -f "$UNENCRYPTED_DATA_FILE" ]; then
    echo "   [FAIL] Unencrypted data file not found: $UNENCRYPTED_DATA_FILE"
    exit 1
fi
# Corrupt 16 bytes in the first data page (offset 100 is past page header) so checksum will fail
dd if=/dev/urandom of="$UNENCRYPTED_DATA_FILE" bs=1 count=16 seek=100 conv=notrunc 2>/dev/null
if [ $? -ne 0 ]; then
    echo "   [FAIL] Failed to corrupt unencrypted data file."
    exit 1
fi
echo "   Corrupted unencrypted data file $UNENCRYPTED_DATA_FILE (16 bytes at offset 100)."

echo "11. Running pg_tde_checksums again (expect checksum failure)..."
CHECK_OUTPUT=$($INSTALL_DIR/bin/pg_tde_checksums -c -D "$PGDATA" 2>&1)
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "   [FAIL] pg_tde_checksums should have reported checksum failure but exited 0."
    echo "   Details: $(echo "$CHECK_OUTPUT" | grep "checksum verification failed" | tail -n 1)"
    exit 1
else
    echo "   [PASS] pg_tde_checksums correctly reported checksum failure."
fi

echo "=== DONE: pg_tde_checksums test completed ==="