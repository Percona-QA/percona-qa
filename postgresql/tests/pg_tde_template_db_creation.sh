#!/bin/bash

INSTALL_DIR=$HOME/postgresql/bld_17.6/install
PGDATA=$INSTALL_DIR/data
LOG_FILE=$INSTALL_DIR/server.log

source "$(dirname "${BASH_SOURCE[0]}")/helper_scripts/initialize_server.sh"

# Output formatting
log() { echo -e "\n===> $1\n"; }

check_pg_tde() {
    db=$1
    if $INSTALL_DIR/bin/psql -d "$db" -tAc "SELECT extname FROM pg_extension WHERE extname='pg_tde';" | grep -q 'pg_tde'; then
        echo "✅ pg_tde is present in $db"
    else
        echo "❌ pg_tde is NOT present in $db"
    fi
}

run_pg_tde_function_test() {
    db=$1
    log "Testing pg_tde functionality in $db"
    $INSTALL_DIR/bin/psql -d "$db" <<EOF
-- Clean up if exists
SELECT pg_tde_add_database_key_provider_file('keyring_file','/tmp/mykey.per');
SELECT pg_tde_create_key_using_database_key_provider('key1','keyring_file');
SELECT pg_tde_set_key_using_database_key_provider('key1','keyring_file');
CREATE TABLE enc_test(id INT, secret TEXT) USING tde_heap;
INSERT INTO enc_test VALUES (1, 'secret_text');
SELECT * FROM enc_test;
EOF
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    $INSTALL_DIR/bin/psql -d template1 -c 'CREATE EXTENSION pg_tde;'
}

# Actual testing starts here...
initialize_server
start_server
# Cleanup
log "Dropping existing test databases and templates if any"
for db in testdb1 testdb2 testdb3 custom_template; do
    $INSTALL_DIR/bin/dropdb --if-exists "$db"
done

log "Step 1: Create DB from template1 (pg_tde installed)"
$INSTALL_DIR/bin/createdb testdb1
check_pg_tde testdb1

log "Step 2: Create DB from template0 (pg_tde should NOT be present)"
$INSTALL_DIR/bin/createdb testdb2 --template=template0
check_pg_tde testdb2

log "Step 3: Create custom template with pg_tde"
$INSTALL_DIR/bin/createdb custom_template
$INSTALL_DIR/bin/createdb testdb3 --template=custom_template
check_pg_tde testdb3

log "Step 4: Functional test - Run pg_tde functions in testdb1"
run_pg_tde_function_test testdb1

log "Step 5: Drop pg_tde in testdb1 with encrypted table (should fail)"
$INSTALL_DIR/bin/psql -d testdb1 -c "DROP EXTENSION pg_tde;" || echo "✅ Drop failed as expected due to dependencies"

log "Step 6: Create DB as non-superuser"
$INSTALL_DIR/bin/createuser limited_user --no-superuser
$INSTALL_DIR/bin/createdb testdb4 --owner=limited_user
check_pg_tde testdb4

log "Step 7: Remove pg_tde from template1 and create a new DB (testdb5)"
$INSTALL_DIR/bin/psql -d template1 -c "DROP EXTENSION IF EXISTS pg_tde;"
$INSTALL_DIR/bin/createdb testdb5
check_pg_tde testdb5

log "Step 8: Check system catalogs in testdb1"
$INSTALL_DIR/bin/psql -d testdb1 -c "SELECT * FROM pg_extension WHERE extname='pg_tde';"
$INSTALL_DIR/bin/psql -d testdb1 -c "SELECT * FROM pg_depend WHERE objid IN (SELECT oid FROM pg_extension WHERE extname='pg_tde');"

log "Step 9: Dump testdb1 schema and check for pg_tde extension"
$INSTALL_DIR/bin/pg_dump -s testdb1 | grep "pg_tde" && echo "✅ pg_tde is in dump" || echo "❌ pg_tde not found in dump"

log "🎉 All tests completed!"
