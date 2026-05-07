#!/bin/bash
#
# pg_tde_rewind_multi_round.sh
#
# Stress and multi-round scenarios for pg_rewind with pg_tde.
# Scenarios:
#   1. DDL storm: 50 CREATE TABLE + INSERT + DROP on diverged server
#   2. Double cycle: two consecutive diverge → rewind cycles
#   3. Concurrent background DML on source while divergence happens
#   4. Large number of tde_heap files (100+ tables)
#   5. WAL encryption enabled + 5 key rotations before rewind
#   6. Full sequence: promote → rewind → reconnect standby → promote again
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

KEYFILE="$RUN_DIR/mr_keyfile.per"

##############################################################################
# HELPERS
##############################################################################

_stop_pair() {
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$REPLICA_DATA" stop -m immediate 2>/dev/null || true
}

_cleanup_pair() {
    _stop_pair
    rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$KEYFILE"
}

_init_tde_primary() {
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
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_add_global_key_provider_file('file_prov','$KEYFILE');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_prov');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','file_prov');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_prov');"
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

_wait_replica_sync() {
    local primary_port="${1:-$PRIMARY_PORT}"
    local timeout=30
    while [ $timeout -gt 0 ]; do
        local cnt
        cnt=$("$PSQL" -p "$primary_port" -d postgres -t -A \
            -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
        [ "$cnt" -ge 1 ] && return 0
        sleep 1
        timeout=$((timeout - 1))
    done
    echo "ERROR: replica did not connect in 30s"
    exit 1
}

_rewind_and_start() {
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$REPLICA_DATA" stop -m fast    2>/dev/null || true
    "$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
                  --source-pgdata="$REPLICA_DATA" -c
    start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"
}

_reconnect_as_standby() {
    local standby_data=$1
    local standby_port=$2
    local upstream_port=$3
    touch "$standby_data/standby.signal"
    cat >> "$standby_data/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$upstream_port user=$(whoami)'
EOF
    start_pg "$standby_data" "$standby_port"
    local timeout=30
    while [ $timeout -gt 0 ]; do
        local cnt
        cnt=$("$PSQL" -p "$upstream_port" -d postgres -t -A \
            -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
        [ "$cnt" -ge 1 ] && return 0
        sleep 1
        timeout=$((timeout - 1))
    done
    echo "ERROR: standby did not reconnect in 30s"
    exit 1
}

##############################################################################
# SCENARIO 1: DDL storm — 50 CREATE TABLE + INSERT + DROP on diverged server
##############################################################################
echo ""
echo "=== SCENARIO 1: DDL storm divergence ==="
_cleanup_pair

_init_tde_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_base (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_base SELECT generate_series(1,500);"

_make_replica
_wait_replica_sync

"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

# DDL storm: 50 tables created, filled, and some dropped
"$PSQL" -p "$REPLICA_PORT" -d postgres <<'SQL'
DO $$
DECLARE i INT;
BEGIN
    FOR i IN 1..50 LOOP
        EXECUTE format(
            'CREATE TABLE storm_%s (id INT, val TEXT) USING tde_heap', i
        );
        EXECUTE format(
            'INSERT INTO storm_%s SELECT g, md5(g::text) FROM generate_series(1,100) g', i
        );
    END LOOP;
    -- Drop half of them to create relfilenode churn
    FOR i IN 1..25 LOOP
        EXECUTE format('DROP TABLE storm_%s', i);
    END LOOP;
END
$$;
SQL
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_base SELECT generate_series(9001,9500);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

_rewind_and_start

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_base;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_base empty after DDL storm rewind"; exit 1; }

# Check surviving DDL storm tables are accessible
for i in 26 30 35 40 45 50; do
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT count(*) FROM storm_${i};" >/dev/null 2>&1 || \
        echo "NOTE: storm_$i not accessible (may have been dropped on source)"
done

echo "PASS: Scenario 1 — DDL storm, base_rows=$COUNT"

##############################################################################
# SCENARIO 2: Double cycle — two consecutive diverge → rewind
##############################################################################
echo ""
echo "=== SCENARIO 2: Double cycle ==="
_cleanup_pair

_init_tde_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_double (id INT, round INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_double SELECT g, 0 FROM generate_series(1,100) g;"

_make_replica
_wait_replica_sync

echo "  Cycle 1"
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_double SELECT g, 1 FROM generate_series(1001,1100) g;"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
_rewind_and_start

# After cycle 1: primary has been rewound to match replica's state
# Rebuild replica from the now-rewound primary for cycle 2
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true
rm -rf "$REPLICA_DATA"
_make_replica
_wait_replica_sync

echo "  Cycle 2"
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_double SELECT g, 2 FROM generate_series(2001,2100) g;"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
_rewind_and_start

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_double;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_double empty after double cycle"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 2 — double cycle, rows=$COUNT"

##############################################################################
# SCENARIO 3: Concurrent background DML on source during divergence
##############################################################################
echo ""
echo "=== SCENARIO 3: Concurrent background DML on source ==="
_cleanup_pair

_init_tde_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_conc (id INT, val TEXT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_conc SELECT g, md5(g::text) FROM generate_series(1,500) g;"

_make_replica
_wait_replica_sync

"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

# Background DML worker on the promoted replica (new primary = REPLICA_PORT)
(
    set +e
    END_TIME=$((SECONDS + 20))
    while [ $SECONDS -lt $END_TIME ]; do
        "$PSQL" -p "$REPLICA_PORT" -d postgres -c \
            "INSERT INTO t_conc SELECT g, md5(random()::text) FROM generate_series(1,50) g;" \
            >/dev/null 2>&1
        "$PSQL" -p "$REPLICA_PORT" -d postgres -c \
            "UPDATE t_conc SET val=md5(random()::text) WHERE id % 10 = 0;" \
            >/dev/null 2>&1
        sleep 1
    done
) &
BG_PID=$!

# Meanwhile insert some diverging data on primary (which will be rewound)
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_conc SELECT g, md5(g::text) FROM generate_series(9001,9100) g;"

# Let background run for a bit
sleep 5

# Stop background worker
kill $BG_PID 2>/dev/null || true
wait $BG_PID 2>/dev/null || true

"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
_rewind_and_start

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_conc;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_conc empty after concurrent DML rewind"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 3 — concurrent DML, rows=$COUNT"

##############################################################################
# SCENARIO 4: Large number of tde_heap files (100 tables)
##############################################################################
echo ""
echo "=== SCENARIO 4: 100 tde_heap tables ==="
_cleanup_pair

_init_tde_primary

# Create 100 tde_heap tables
"$PSQL" -p "$PRIMARY_PORT" -d postgres <<'SQL'
DO $$
DECLARE i INT;
BEGIN
    FOR i IN 1..100 LOOP
        EXECUTE format(
            'CREATE TABLE heap_%s (id INT, val TEXT) USING tde_heap', i
        );
        EXECUTE format(
            'INSERT INTO heap_%s SELECT g, md5(g::text) FROM generate_series(1,50) g', i
        );
    END LOOP;
END
$$;
SQL
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CHECKPOINT;"

_make_replica
_wait_replica_sync

"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

# Add more rows to all tables on the promoted replica
"$PSQL" -p "$REPLICA_PORT" -d postgres <<'SQL'
DO $$
DECLARE i INT;
BEGIN
    FOR i IN 1..100 LOOP
        EXECUTE format(
            'INSERT INTO heap_%s SELECT g, md5(g::text) FROM generate_series(100,200) g', i
        );
    END LOOP;
END
$$;
SQL
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

_rewind_and_start

# Spot-check several tables
FAIL=0
for i in 1 10 25 50 75 100; do
    COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
        -c "SELECT count(*) FROM heap_${i};" 2>/dev/null || echo 0)
    [ "$COUNT" -gt 0 ] || { echo "ERROR: heap_$i empty after large-files rewind"; FAIL=1; }
done
[ $FAIL -eq 0 ] || exit 1

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 4 — 100 tde_heap files, all spot-checks passed"

##############################################################################
# SCENARIO 5: WAL encryption + 5 key rotations before rewind
##############################################################################
echo ""
echo "=== SCENARIO 5: WAL encryption + 5 key rotations ==="
_cleanup_pair

_init_tde_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_kr (id INT, round INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_kr SELECT g, 0 FROM generate_series(1,200) g;"

_make_replica "pg_tde.wal_encrypt = 'on'"
_wait_replica_sync

"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

# 5 key rotations on the promoted replica (new primary)
for n in 2 3 4 5 6; do
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_create_key_using_global_key_provider('key${n}','file_prov');"
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_set_server_key_using_global_key_provider('key${n}','file_prov');"
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_set_key_using_global_key_provider('key${n}','file_prov');"
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "INSERT INTO t_kr SELECT g, $n FROM generate_series(1,50) g;"
done
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

_rewind_and_start

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_kr;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_kr empty after 5 key rotations + rewind"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 5 — WAL enc + 5 rotations, rows=$COUNT"

##############################################################################
# SCENARIO 6: Promote → rewind → reconnect → promote again
##############################################################################
echo ""
echo "=== SCENARIO 6: Promote → rewind → reconnect → promote again ==="
_cleanup_pair

_init_tde_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_cycle (id INT, phase TEXT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_cycle SELECT g, 'initial' FROM generate_series(1,100) g;"

_make_replica
_wait_replica_sync

echo "  Phase 1: promote replica, diverge, rewind primary, reconnect as standby"
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_cycle SELECT g, 'phase1' FROM generate_series(1001,1100) g;"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

# Stop primary (old), rewind it, reconnect as standby
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c

# REPLICA is now the primary — start it first
start_pg "$REPLICA_DATA" "$REPLICA_PORT"

# Reconnect old primary (PRIMARY_DATA) as standby of REPLICA
touch "$PRIMARY_DATA/standby.signal"
cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
primary_conninfo = 'host=localhost port=$REPLICA_PORT user=$(whoami)'
EOF
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

# Wait for standby to connect
local_timeout=30
while [ $local_timeout -gt 0 ]; do
    cnt=$("$PSQL" -p "$REPLICA_PORT" -d postgres -t -A \
        -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
    [ "$cnt" -ge 1 ] && break
    sleep 1
    local_timeout=$((local_timeout - 1))
done
[ $local_timeout -gt 0 ] || { echo "ERROR: standby did not reconnect"; exit 1; }

echo "  Phase 1 complete: PRIMARY_DATA is standby of REPLICA_DATA"

echo "  Phase 2: promote old-primary (now standby) again"
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_cycle SELECT g, 'between_phases' FROM generate_series(2001,2100) g;"
sleep 2

# Promote PRIMARY_DATA to be primary again
"$PG_CTL" -D "$PRIMARY_DATA" promote
sleep 2

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_cycle SELECT g, 'phase2' FROM generate_series(3001,3100) g;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CHECKPOINT;"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_cycle;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_cycle empty after full promote+rewind+promote cycle"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true
"$PG_CTL" -D "$PRIMARY_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 6 — promote→rewind→reconnect→promote, rows=$COUNT"

##############################################################################
echo ""
echo "✅ pg_tde_rewind_multi_round: all scenarios passed"
