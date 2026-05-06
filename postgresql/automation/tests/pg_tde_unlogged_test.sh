#!/bin/bash

# Unlogged table reinitialization test (bash port of recovery/014_unlogged_reinit.pl).
# Verifies that unlogged tables are properly reinitialized after a crash:
# - init fork is kept, main fork is recopied from init at startup
# - VM and FSM forks are removed during recovery

PSQL="$INSTALL_DIR/bin/psql"
TABLESPACE_DIR="$RUN_DIR/unlogged_ts1"
KEYFILE="$RUN_DIR/unlogged_keyfile"
UNLOGGED_PORT="${UNLOGGED_PORT:-5437}"
PGDATA="$RUN_DIR/pg_tde_unlogged_test"

# Cleanup and init
old_server_cleanup "$PGDATA"
rm -rf "$TABLESPACE_DIR" || true
mkdir -p "$TABLESPACE_DIR"
chmod 700 "$TABLESPACE_DIR" || true

echo "1. Initializing cluster with pg_tde..."
$INSTALL_DIR/bin/initdb -D "$PGDATA" --set shared_preload_libraries=pg_tde --set io_method=$IO_METHOD --set unix_socket_directories="$RUN_DIR" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: initdb failed."
    exit 1
fi
cat >> "$PGDATA/postgresql.conf" <<EOF
default_table_access_method = tde_heap
logging_collector = on
log_directory = '$PGDATA'
log_filename = 'server.log'
log_statement = 'all'
EOF

start_pg "$PGDATA" "$UNLOGGED_PORT"

echo "2. Enabling pg_tde extension and key provider..."
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_global_key_provider('key1', 'file_provider');"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1', 'file_provider');"
restart_pg "$PGDATA" "$UNLOGGED_PORT"

echo "3. Creating unlogged table and sequence in default location..."
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE UNLOGGED TABLE base_unlogged (id int);"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE UNLOGGED SEQUENCE seq_unlogged;"

BASE_UNLOGGED_PATH=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT pg_relation_filepath('base_unlogged');" | tr -d '\r\n')
SEQ_UNLOGGED_PATH=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT pg_relation_filepath('seq_unlogged');" | tr -d '\r\n')

echo "4. Checking table/sequence init and main forks exist..."
for path in "$PGDATA/${BASE_UNLOGGED_PATH}_init" "$PGDATA/$BASE_UNLOGGED_PATH" \
            "$PGDATA/${SEQ_UNLOGGED_PATH}_init" "$PGDATA/$SEQ_UNLOGGED_PATH"; do
    if [ ! -f "$path" ]; then
        echo "   [FAIL] Expected file missing: $path"
        exit 1
    fi
done
echo "   [PASS] All forks present."

echo "5. Testing sequence nextval..."
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged');")
[ "$NEXT" = "1" ] || { echo "   [FAIL] nextval expected 1, got $NEXT"; exit 1; }
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged');")
[ "$NEXT" = "2" ] || { echo "   [FAIL] nextval expected 2, got $NEXT"; exit 1; }
echo "   [PASS] Sequence nextval 1, 2."

echo "6. Creating tablespace and unlogged table in tablespace..."
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLESPACE ts1 LOCATION '$TABLESPACE_DIR';"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE UNLOGGED TABLE ts1_unlogged (id int) TABLESPACE ts1;"

TS1_UNLOGGED_PATH=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT pg_relation_filepath('ts1_unlogged');" | tr -d '\r\n')

for path in "$PGDATA/${TS1_UNLOGGED_PATH}_init" "$PGDATA/$TS1_UNLOGGED_PATH"; do
    if [ ! -f "$path" ]; then
        echo "   [FAIL] Expected tablespace file missing: $path"
        exit 1
    fi
done
echo "   [PASS] Tablespace init and main forks exist."

echo "7. Creating more unlogged sequences and identity table..."
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE UNLOGGED SEQUENCE seq_unlogged2;"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "ALTER SEQUENCE seq_unlogged2 INCREMENT 2;"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "SELECT nextval('seq_unlogged2');"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "CREATE UNLOGGED TABLE tab_seq_unlogged3 (a int GENERATED ALWAYS AS IDENTITY);"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "TRUNCATE tab_seq_unlogged3 RESTART IDENTITY;"
$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO tab_seq_unlogged3 DEFAULT VALUES;"

echo "8. Stopping postmaster (immediate) to simulate crash..."
$INSTALL_DIR/bin/pg_ctl -D "$PGDATA" -m immediate stop
sleep 2

echo "9. Writing fake VM/FSM forks and removing main forks (to test recovery reinit)..."
echo 'TEST_VM' >> "$PGDATA/${BASE_UNLOGGED_PATH}_vm"
echo 'TEST_FSM' >> "$PGDATA/${BASE_UNLOGGED_PATH}_fsm"
rm -f "$PGDATA/$BASE_UNLOGGED_PATH" || { echo "   [FAIL] Could not remove $PGDATA/$BASE_UNLOGGED_PATH"; exit 1; }
rm -f "$PGDATA/$SEQ_UNLOGGED_PATH" || { echo "   [FAIL] Could not remove $PGDATA/$SEQ_UNLOGGED_PATH"; exit 1; }

echo 'TEST_VM' >> "$PGDATA/${TS1_UNLOGGED_PATH}_vm"
echo 'TEST_FSM' >> "$PGDATA/${TS1_UNLOGGED_PATH}_fsm"
rm -f "$PGDATA/$TS1_UNLOGGED_PATH" || { echo "   [FAIL] Could not remove $PGDATA/$TS1_UNLOGGED_PATH"; exit 1; }

echo "10. Starting cluster (recovery should reinit unlogged)..."
start_pg "$PGDATA" "$UNLOGGED_PORT"

echo "11. Checking unlogged table in base after recovery..."
[ -f "$PGDATA/${BASE_UNLOGGED_PATH}_init" ] || { echo "   [FAIL] table init fork in base should still exist"; exit 1; }
[ -f "$PGDATA/$BASE_UNLOGGED_PATH" ] || { echo "   [FAIL] table main fork in base should be recreated"; exit 1; }
[ ! -f "$PGDATA/${BASE_UNLOGGED_PATH}_vm" ] || { echo "   [FAIL] vm fork in base should be removed"; exit 1; }
[ ! -f "$PGDATA/${BASE_UNLOGGED_PATH}_fsm" ] || { echo "   [FAIL] fsm fork in base should be removed"; exit 1; }
echo "   [PASS] Base unlogged table reinit OK."

echo "12. Checking unlogged sequence after recovery..."
[ -f "$PGDATA/${SEQ_UNLOGGED_PATH}_init" ] || { echo "   [FAIL] sequence init fork should still exist"; exit 1; }
[ -f "$PGDATA/$SEQ_UNLOGGED_PATH" ] || { echo "   [FAIL] sequence main fork should be recreated"; exit 1; }
echo "   [PASS] Sequence reinit OK."

echo "13. Testing sequence nextval after restart..."
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged');")
[ "$NEXT" = "1" ] || { echo "   [FAIL] nextval after restart expected 1, got $NEXT"; exit 1; }
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged');")
[ "$NEXT" = "2" ] || { echo "   [FAIL] nextval after restart expected 2, got $NEXT"; exit 1; }
echo "   [PASS] seq_unlogged nextval 1, 2 after restart."

echo "14. Checking unlogged table in tablespace after recovery..."
[ -f "$PGDATA/${TS1_UNLOGGED_PATH}_init" ] || { echo "   [FAIL] init fork in tablespace should still exist"; exit 1; }
[ -f "$PGDATA/$TS1_UNLOGGED_PATH" ] || { echo "   [FAIL] main fork in tablespace should be recreated"; exit 1; }
[ ! -f "$PGDATA/${TS1_UNLOGGED_PATH}_vm" ] || { echo "   [FAIL] vm fork in tablespace should be removed"; exit 1; }
[ ! -f "$PGDATA/${TS1_UNLOGGED_PATH}_fsm" ] || { echo "   [FAIL] fsm fork in tablespace should be removed"; exit 1; }
echo "   [PASS] Tablespace unlogged reinit OK."

echo "15. Testing altered sequence and identity table after restart..."
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged2');")
[ "$NEXT" = "1" ] || { echo "   [FAIL] seq_unlogged2 nextval expected 1, got $NEXT"; exit 1; }
NEXT=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT nextval('seq_unlogged2');")
[ "$NEXT" = "3" ] || { echo "   [FAIL] seq_unlogged2 nextval expected 3, got $NEXT"; exit 1; }

$PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO tab_seq_unlogged3 VALUES (DEFAULT), (DEFAULT);"
ROWS=$($PSQL -p "$UNLOGGED_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT * FROM tab_seq_unlogged3 ORDER BY a;")
EXPECTED="1
2"
if [ "$ROWS" != "$EXPECTED" ]; then
    echo "   [FAIL] tab_seq_unlogged3 expected '$EXPECTED', got '$ROWS'"
    exit 1
fi
echo "   [PASS] Altered sequence and identity table OK."

stop_pg "$PGDATA"
echo "=== DONE: Unlogged reinit test completed ==="
