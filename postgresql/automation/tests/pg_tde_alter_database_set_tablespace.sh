#!/bin/bash

set -euo pipefail

PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="$RUN_DIR/alter_db_tsp_keyfile.per"
TS_BLOCK_TARGET="$RUN_DIR/ts_block_target"
TS_ALLOW_OUTSIDE="$RUN_DIR/ts_allow_outside"
TS_ALLOW_TARGET="$RUN_DIR/ts_allow_target"
TS_EMPTY_TARGET="$RUN_DIR/ts_empty_target"
TS_HEAP_TARGET="$RUN_DIR/ts_heap_target"
TS_MIXED_TARGET="$RUN_DIR/ts_mixed_target"

echo "=== pg_tde ALTER DATABASE ... SET TABLESPACE checks ==="

old_server_cleanup "$PGDATA" "$PORT"
rm -rf "$PGDATA" "$TS_BLOCK_TARGET" "$TS_ALLOW_OUTSIDE" "$TS_ALLOW_TARGET" "$TS_EMPTY_TARGET" "$TS_HEAP_TARGET" "$TS_MIXED_TARGET" || true
rm -f "$KEYFILE" || true
mkdir -p "$TS_BLOCK_TARGET" "$TS_ALLOW_OUTSIDE" "$TS_ALLOW_TARGET" "$TS_EMPTY_TARGET" "$TS_HEAP_TARGET" "$TS_MIXED_TARGET"
chmod 700 "$TS_BLOCK_TARGET" "$TS_ALLOW_OUTSIDE" "$TS_ALLOW_TARGET" "$TS_EMPTY_TARGET" "$TS_HEAP_TARGET" "$TS_MIXED_TARGET"

initialize_server "$PGDATA" "$PORT"
enable_pg_tde "$PGDATA"
start_pg "$PGDATA" "$PORT"

echo "1) Configure pg_tde"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "SELECT pg_tde_add_global_key_provider_file('global_file_provider','$KEYFILE');"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "SELECT pg_tde_create_key_using_global_key_provider('db_tsp_key','global_file_provider');"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "SELECT pg_tde_set_default_key_using_global_key_provider('db_tsp_key','global_file_provider');"
restart_pg "$PGDATA" "$PORT"

echo "2) Must be refused when encrypted objects exist in database default tablespace"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE blockdb;"
"$PSQL" -p "$PORT" -d blockdb -h "$PGHOST" -c "CREATE TABLE enc_default (id INT);"
"$PSQL" -p "$PORT" -d blockdb -h "$PGHOST" -c "INSERT INTO enc_default VALUES (1);"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_block_target LOCATION '$TS_BLOCK_TARGET';"

old_oid=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -t -A -c \
  "SELECT dattablespace FROM pg_database WHERE datname='blockdb';" | tr -d '\r\n')

set +e
block_out=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -c \
  "ALTER DATABASE blockdb SET TABLESPACE ts_block_target;" 2>&1)
block_rc=$?
set -e

if [ "$block_rc" -eq 0 ]; then
  echo "[FAIL] Expected ALTER DATABASE blockdb SET TABLESPACE to fail"
  exit 1
fi

new_oid=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -t -A -c \
  "SELECT dattablespace FROM pg_database WHERE datname='blockdb';" | tr -d '\r\n')
[ "$new_oid" = "$old_oid" ] || { echo "[FAIL] blockdb tablespace changed unexpectedly"; exit 1; }

echo "   [PASS] Operation refused as expected."
echo "   [INFO] Error output: $block_out"

echo "3) Must be allowed when default tablespace has no encrypted objects"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_allow_outside LOCATION '$TS_ALLOW_OUTSIDE';"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_allow_target LOCATION '$TS_ALLOW_TARGET';"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE allowdb;"

# Keep encrypted table in non-default tablespace.
"$PSQL" -p "$PORT" -d allowdb -h "$PGHOST" -c \
  "CREATE TABLE enc_outside (id INT) TABLESPACE ts_allow_outside;"
"$PSQL" -p "$PORT" -d allowdb -h "$PGHOST" -c "INSERT INTO enc_outside VALUES (42);"

"$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -c \
  "ALTER DATABASE allowdb SET TABLESPACE ts_allow_target;"

db_ts=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -t -A -c \
  "SELECT t.spcname FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace WHERE d.datname='allowdb';" \
  | tr -d '\r\n')
[ "$db_ts" = "ts_allow_target" ] || { echo "[FAIL] allowdb was not moved to target tablespace"; exit 1; }

outside_ts=$("$PSQL" -p "$PORT" -d allowdb -h "$PGHOST" -t -A -c \
  "SELECT t.spcname FROM pg_class c JOIN pg_tablespace t ON t.oid=c.reltablespace WHERE c.relname='enc_outside';" \
  | tr -d '\r\n')
[ "$outside_ts" = "ts_allow_outside" ] || { echo "[FAIL] enc_outside moved unexpectedly"; exit 1; }

count=$("$PSQL" -p "$PORT" -d allowdb -h "$PGHOST" -t -A -c \
  "SELECT COUNT(*) FROM enc_outside;" | tr -d '\r\n')
[ "$count" = "1" ] || { echo "[FAIL] Expected 1 row in allowdb.enc_outside, got $count"; exit 1; }

echo "   [PASS] Operation allowed and data remains accessible."

echo "4) Empty database move should be allowed"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_empty_target LOCATION '$TS_EMPTY_TARGET';"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE emptydb;"
"$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -c \
  "ALTER DATABASE emptydb SET TABLESPACE ts_empty_target;"
empty_ts=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -t -A -c \
  "SELECT t.spcname FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace WHERE d.datname='emptydb';" \
  | tr -d '\r\n')
[ "$empty_ts" = "ts_empty_target" ] || { echo "[FAIL] emptydb was not moved"; exit 1; }
echo "   [PASS] Empty database move works."

echo "5) Heap-only objects in default tablespace should not block move"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_heap_target LOCATION '$TS_HEAP_TARGET';"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE heapdb;"
"$PSQL" -p "$PORT" -d heapdb -h "$PGHOST" -c "CREATE TABLE heap_only (id INT) USING heap;"
"$PSQL" -p "$PORT" -d heapdb -h "$PGHOST" -c "INSERT INTO heap_only VALUES (7);"
"$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -c \
  "ALTER DATABASE heapdb SET TABLESPACE ts_heap_target;"
heap_ts=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -t -A -c \
  "SELECT t.spcname FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace WHERE d.datname='heapdb';" \
  | tr -d '\r\n')
[ "$heap_ts" = "ts_heap_target" ] || { echo "[FAIL] heapdb was not moved"; exit 1; }
heap_count=$("$PSQL" -p "$PORT" -d heapdb -h "$PGHOST" -t -A -c \
  "SELECT COUNT(*) FROM heap_only;" | tr -d '\r\n')
[ "$heap_count" = "1" ] || { echo "[FAIL] heapdb data check failed"; exit 1; }
echo "   [PASS] Heap-only default objects do not block operation."

echo "6) Mixed heap + encrypted objects in default tablespace should still be refused"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c \
  "CREATE TABLESPACE ts_mixed_target LOCATION '$TS_MIXED_TARGET';"
"$PSQL" -p "$PORT" -d postgres -h "$PGHOST" -c "CREATE DATABASE mixeddb;"
"$PSQL" -p "$PORT" -d mixeddb -h "$PGHOST" -c "CREATE TABLE heap_default (id INT) USING heap;"
"$PSQL" -p "$PORT" -d mixeddb -h "$PGHOST" -c "CREATE TABLE enc_default2 (id INT);"
set +e
mixed_out=$("$PSQL" -p "$PORT" -d template1 -h "$PGHOST" -c \
  "ALTER DATABASE mixeddb SET TABLESPACE ts_mixed_target;" 2>&1)
mixed_rc=$?
set -e
[ "$mixed_rc" -ne 0 ] || { echo "[FAIL] Expected mixeddb move to fail"; exit 1; }
echo "   [PASS] Mixed default objects (incl encrypted) correctly blocked."
echo "   [INFO] Error output: $mixed_out"

stop_pg "$PGDATA"
echo "=== DONE: pg_tde ALTER DATABASE ... SET TABLESPACE checks completed ==="
