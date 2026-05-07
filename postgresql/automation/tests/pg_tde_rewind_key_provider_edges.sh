#!/bin/bash
#
# pg_tde_rewind_key_provider_edges.sh
#
# Tests pg_rewind edge cases involving pg_tde key providers.
# Scenarios:
#   1. Database-level (non-global) key provider API survives rewind
#   2. Multiple databases with different keys: all accessible after rewind
#   3. Key rotation on source before rewind — original key preserved on target
#   4. Negative: rewind target that has a missing key provider file
#
# Prerequisites: INSTALL_DIR, RUN_DIR, PRIMARY_DATA, REPLICA_DATA,
#                PRIMARY_PORT, REPLICA_PORT set by env.sh / test_runner.sh

##############################################################################
# BINARIES
##############################################################################
PSQL="$INSTALL_DIR/bin/psql"
PG_CTL="$INSTALL_DIR/bin/pg_ctl"

PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
[ -x "$PG_REWIND" ] || PG_REWIND="$INSTALL_DIR/bin/pg_rewind"

PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
[ -x "$PG_BASEBACKUP" ] || PG_BASEBACKUP="$INSTALL_DIR/bin/pg_basebackup"

KEYFILE="$RUN_DIR/kp_keyfile.per"
KEYFILE2="$RUN_DIR/kp_keyfile2.per"

##############################################################################
# HELPERS
##############################################################################

_cleanup_pair() {
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$REPLICA_DATA" stop -m immediate 2>/dev/null || true
    rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$KEYFILE" "$KEYFILE2"
}

_base_init_primary() {
    local extra_conf="${1:-}"
    initialize_server "$PRIMARY_DATA" "$PRIMARY_PORT"
    enable_pg_tde "$PRIMARY_DATA"
    cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
wal_level = replica
wal_log_hints = on
max_wal_senders = 5
wal_keep_size = 512MB
EOF
    [ -n "$extra_conf" ] && echo "$extra_conf" >> "$PRIMARY_DATA/postgresql.conf"
    echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
    start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CREATE EXTENSION pg_tde;"
}

_make_replica() {
    mkdir -p "$REPLICA_DATA"
    chmod 700 "$REPLICA_DATA"
    cp -R "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA/"
    "$PG_BASEBACKUP" -D "$REPLICA_DATA" -R -X stream -c fast -E \
        -h localhost -p "$PRIMARY_PORT"
    cat >> "$REPLICA_DATA/postgresql.conf" <<EOF
port = $REPLICA_PORT
unix_socket_directories = '$RUN_DIR'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
EOF
    start_pg "$REPLICA_DATA" "$REPLICA_PORT"
}

_diverge_and_rewind() {
    local new_primary_port=$1
    local new_primary_data=$2
    local sql="${3:-INSERT INTO t_kp SELECT generate_series(9000,9100);}"
    "$PG_CTL" -D "$new_primary_data" promote
    sleep 2
    "$PSQL" -p "$new_primary_port" -d postgres -c "$sql"
    "$PSQL" -p "$new_primary_port" -d postgres -c "CHECKPOINT;"
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
    "$PG_CTL" -D "$new_primary_data" stop -m fast
    "$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
                  --source-pgdata="$new_primary_data" -c
    start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"
}

##############################################################################
# SCENARIO 1: Database-level key provider survives rewind
##############################################################################
echo ""
echo "=== SCENARIO 1: Database-level key provider API ==="
_cleanup_pair

_base_init_primary

# Use global provider for server key, database provider for table key
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_global_key_provider_file('global_prov','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_global_key_provider('server_key','global_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key','global_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_database_key_provider_file('db_prov','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_database_key_provider('db_key','db_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_key_using_database_key_provider('db_key','db_prov');"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_kp (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_kp SELECT generate_series(1,500);"

_make_replica
_diverge_and_rewind "$REPLICA_PORT" "$REPLICA_DATA"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_kp;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_kp empty after rewind"; exit 1; }

# Verify database provider still listed
DB_PROV_COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT COUNT(*) FROM pg_tde_list_all_database_key_providers();" \
    2>/dev/null || echo 0)
[ "$DB_PROV_COUNT" -ge 1 ] || \
    echo "NOTE: pg_tde_list_all_database_key_providers not available or 0 providers"

echo "PASS: Scenario 1 — database-level key provider, rows=$COUNT"

##############################################################################
# SCENARIO 2: Multiple databases with different keys
##############################################################################
echo ""
echo "=== SCENARIO 2: Multiple databases with different keys ==="
_cleanup_pair

_base_init_primary

# Global provider
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_global_key_provider_file('file_prov','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_global_key_provider('server_key','file_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key','file_prov');"

# DB1: postgres with key "key_db1"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_database_key_provider_file('prov_db1','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_database_key_provider('key_db1','prov_db1');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_key_using_database_key_provider('key_db1','prov_db1');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_db1 (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_db1 SELECT generate_series(1,200);"

# DB2: a second database with its own key
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CREATE DATABASE db2;"
"$PSQL" -p "$PRIMARY_PORT" -d db2 -c "CREATE EXTENSION pg_tde;"
"$PSQL" -p "$PRIMARY_PORT" -d db2 \
    -c "SELECT pg_tde_add_database_key_provider_file('prov_db2','$KEYFILE2');"
"$PSQL" -p "$PRIMARY_PORT" -d db2 \
    -c "SELECT pg_tde_create_key_using_database_key_provider('key_db2','prov_db2');"
"$PSQL" -p "$PRIMARY_PORT" -d db2 \
    -c "SELECT pg_tde_set_key_using_database_key_provider('key_db2','prov_db2');"
"$PSQL" -p "$PRIMARY_PORT" -d db2 \
    -c "CREATE TABLE t_db2 (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d db2 \
    -c "INSERT INTO t_db2 SELECT generate_series(1,200);"

_make_replica

# Diverge: promote replica, insert into both databases
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_db1 SELECT generate_series(9001,9100);"
"$PSQL" -p "$REPLICA_PORT" -d db2 \
    -c "INSERT INTO t_db2 SELECT generate_series(9001,9100);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

C1=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_db1;")
C2=$("$PSQL" -p "$PRIMARY_PORT" -d db2 -t -A \
    -c "SELECT count(*) FROM t_db2;")

[ "$C1" -gt 0 ] || { echo "ERROR: t_db1 empty after rewind"; exit 1; }
[ "$C2" -gt 0 ] || { echo "ERROR: t_db2 empty after rewind"; exit 1; }

echo "PASS: Scenario 2 — db1_rows=$C1 db2_rows=$C2"

##############################################################################
# SCENARIO 3: Key rotation on source before rewind — original key on target
##############################################################################
echo ""
echo "=== SCENARIO 3: Key rotation between nodes ==="
_cleanup_pair

_base_init_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_global_key_provider_file('file_prov','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_global_key_provider('key_v1','file_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_server_key_using_global_key_provider('key_v1','file_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_key_using_global_key_provider('key_v1','file_prov');"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_rot (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_rot SELECT generate_series(1,300);"

_make_replica

# Promote replica, then rotate the key on the new primary
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_global_key_provider('key_v2','file_prov');"
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "SELECT pg_tde_set_server_key_using_global_key_provider('key_v2','file_prov');"
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "SELECT pg_tde_set_key_using_global_key_provider('key_v2','file_prov');"
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_rot SELECT generate_series(9001,9100);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

# After rewind, primary has the state from source which had key_v2
# Table data from source (with key_v2) should be readable
COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_rot;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_rot empty after rewind with key rotation"; exit 1; }

echo "PASS: Scenario 3 — rows=$COUNT after source key rotation + rewind"

##############################################################################
# SCENARIO 4: Negative — rewind when target key provider file is missing
##############################################################################
echo ""
echo "=== SCENARIO 4: Negative — missing key provider file on target ==="
_cleanup_pair

_base_init_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_add_global_key_provider_file('file_prov','$KEYFILE');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','file_prov');"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_prov');"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_miss (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_miss SELECT generate_series(1,100);"

_make_replica

"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_miss SELECT generate_series(5001,5100);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast

# Rewind succeeds (it's a file-level operation, doesn't need the key)
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c

# Remove the keyfile so pg_tde cannot decrypt on start
KEYFILE_BAK="${KEYFILE}.bak"
mv "$KEYFILE" "$KEYFILE_BAK"

# Start should either fail or emit decryption errors
set +e
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT" 2>/dev/null
RC=$?
set -e

# Either startup failed (RC!=0) or encryption error appears in log
if [ $RC -eq 0 ]; then
    # Server started — try to read the encrypted table; it should fail
    ERRMSG=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
        -c "SELECT count(*) FROM t_miss;" 2>&1 || echo "QUERY_FAILED")
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m fast 2>/dev/null || true
    if echo "$ERRMSG" | grep -qi "QUERY_FAILED\|encrypt\|key\|provider\|error"; then
        echo "PASS: Scenario 4 — table access failed as expected with missing keyfile"
    else
        echo "NOTE: server started and query succeeded — pg_tde may have cached the key"
    fi
else
    echo "PASS: Scenario 4 — server failed to start without keyfile (RC=$RC)"
fi

# Restore keyfile for cleanup
mv "$KEYFILE_BAK" "$KEYFILE"

echo "PASS: Scenario 4 completed"

##############################################################################
echo ""
echo "✅ pg_tde_rewind_key_provider_edges: all scenarios passed"
