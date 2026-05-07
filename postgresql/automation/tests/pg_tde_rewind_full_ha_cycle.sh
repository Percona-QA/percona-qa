#!/bin/bash
#
# pg_tde_rewind_full_ha_cycle.sh
#
# Tests complete HA lifecycle scenarios with pg_rewind and pg_tde.
# Scenarios:
#   1. Rewind then reconnect rewound node as streaming standby (full failback)
#   2. Live-source rewind using --source-server (source stays running)
#   3. Cascading 3-node topology: primary → replica1 → replica2; promote replica1,
#      rewind primary, then reconnect as standby under replica1
#   4. Multiple rounds HA lifecycle: promote → rewind → reconnect × 3 with role swap
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

KEYFILE="$RUN_DIR/ha_cycle_keyfile.per"
NODE3_DATA="$RUN_DIR/node3_data"
NODE3_PORT=$((REPLICA_PORT + 1))

##############################################################################
# HELPERS
##############################################################################

_stop_all() {
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$REPLICA_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$NODE3_DATA"   stop -m immediate 2>/dev/null || true
}

_cleanup_all() {
    _stop_all
    rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$NODE3_DATA" "$KEYFILE"
}

_setup_tde() {
    local port=$1
    local dbname="${2:-postgres}"
    "$PSQL" -p "$port" -d "$dbname" \
        -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
    "$PSQL" -p "$port" -d "$dbname" \
        -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
    "$PSQL" -p "$port" -d "$dbname" \
        -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','file_provider');"
    "$PSQL" -p "$port" -d "$dbname" \
        -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_provider');"
}

_init_primary() {
    local data=$1
    local port=$2
    local extra_conf="${3:-}"
    initialize_server "$data" "$port"
    enable_pg_tde "$data"
    cat >> "$data/postgresql.conf" <<EOF
wal_level = replica
wal_log_hints = on
max_wal_senders = 5
wal_keep_size = 512MB
EOF
    [ -n "$extra_conf" ] && echo "$extra_conf" >> "$data/postgresql.conf"
    echo "host replication all 127.0.0.1/32 trust" >> "$data/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$data/pg_hba.conf"
    start_pg "$data" "$port"
    "$PSQL" -p "$port" -d postgres -c "CREATE EXTENSION pg_tde;"
    _setup_tde "$port"
}

_make_replica() {
    local src_data=$1
    local src_port=$2
    local dst_data=$3
    local dst_port=$4
    local extra_conf="${5:-}"
    mkdir -p "$dst_data"
    chmod 700 "$dst_data"
    cp -R "$src_data/pg_tde" "$dst_data/"
    "$PG_BASEBACKUP" -D "$dst_data" -R -X stream -c fast -E \
        -h localhost -p "$src_port"
    cat >> "$dst_data/postgresql.conf" <<EOF
port = $dst_port
unix_socket_directories = '$RUN_DIR'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
EOF
    [ -n "$extra_conf" ] && echo "$extra_conf" >> "$dst_data/postgresql.conf"
    start_pg "$dst_data" "$dst_port"
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
    # Wait for WAL receiver to connect
    local timeout=30
    while [ $timeout -gt 0 ]; do
        local cnt
        cnt=$("$PSQL" -p "$upstream_port" -d postgres -t -A \
            -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
        [ "$cnt" -ge 1 ] && break
        sleep 1
        timeout=$((timeout - 1))
    done
    [ $timeout -gt 0 ] || { echo "ERROR: standby did not reconnect in 30s"; exit 1; }
    echo "Standby connected to port $upstream_port"
}

_wait_replica_sync() {
    local primary_port=$1
    local timeout=30
    while [ $timeout -gt 0 ]; do
        local cnt
        cnt=$("$PSQL" -p "$primary_port" -d postgres -t -A \
            -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo 0)
        [ "$cnt" -ge 1 ] && return 0
        sleep 1
        timeout=$((timeout - 1))
    done
    echo "ERROR: replica did not appear in pg_stat_replication"
    exit 1
}

##############################################################################
# SCENARIO 1: Rewind then reconnect rewound node as streaming standby
##############################################################################
echo ""
echo "=== SCENARIO 1: Rewind → reconnect as streaming standby ==="
_cleanup_all

_init_primary "$PRIMARY_DATA" "$PRIMARY_PORT"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_failback (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_failback SELECT generate_series(1,1000);"

_make_replica "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"
_wait_replica_sync "$PRIMARY_PORT"

# Diverge: insert on primary only
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_failback SELECT generate_series(1001,2000);"

# Promote replica → new primary
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

# Insert diverging data on the now-promoted replica
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_failback SELECT generate_series(5001,6000);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

# Stop old primary
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast

# Rewind old primary back to new primary's state
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c

# Reconnect rewound node as standby under the promoted replica
start_pg "$REPLICA_DATA" "$REPLICA_PORT"
_reconnect_as_standby "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_PORT"

# Verify replication is working
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_failback VALUES (99999);"
sleep 2

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_failback WHERE id = 99999;")
[ "$COUNT" -eq 1 ] || { echo "ERROR: replication not working after failback"; exit 1; }

echo "PASS: Scenario 1 — failback with streaming replication confirmed"

##############################################################################
# SCENARIO 2: Live-source rewind using --source-server
##############################################################################
echo ""
echo "=== SCENARIO 2: Live-source rewind (--source-server) ==="
_cleanup_all

_init_primary "$PRIMARY_DATA" "$PRIMARY_PORT"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_live (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_live SELECT generate_series(1,500);"

_make_replica "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"
_wait_replica_sync "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_live SELECT generate_series(501,1000);"

# Promote replica
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 2

"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_live SELECT generate_series(9001,9500);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

# Stop only the TARGET (old primary) — source stays running
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate

# Live-source rewind
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
    --source-server="host=localhost port=$REPLICA_PORT user=$(whoami) dbname=postgres"

start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_live;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_live empty after live-source rewind"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
echo "PASS: Scenario 2 — live-source rewind, rows=$COUNT"

##############################################################################
# SCENARIO 3: Cascading 3-node topology (A→B→C, promote B, rewind A)
##############################################################################
echo ""
echo "=== SCENARIO 3: Cascading 3-node topology ==="
_cleanup_all

# nodeA = PRIMARY_DATA/PRIMARY_PORT (original primary)
# nodeB = REPLICA_DATA/REPLICA_PORT (replica of A, will be promoted)
# nodeC = NODE3_DATA/NODE3_PORT (replica of B via cascading)

_init_primary "$PRIMARY_DATA" "$PRIMARY_PORT" \
    "wal_level = logical
max_replication_slots = 5"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_cascade (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_cascade SELECT generate_series(1,1000);"

# Create nodeB as replica of A
_make_replica "$PRIMARY_DATA" "$PRIMARY_PORT" \
    "$REPLICA_DATA" "$REPLICA_PORT" "hot_standby = on"
_wait_replica_sync "$PRIMARY_PORT"

# Create nodeC as cascading replica of B (wait for B to start as standby)
sleep 2
_make_replica "$REPLICA_DATA" "$REPLICA_PORT" \
    "$NODE3_DATA" "$NODE3_PORT" "hot_standby = on"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_cascade SELECT generate_series(1001,1500);"
sleep 2

# Promote nodeB → it becomes new primary
"$PG_CTL" -D "$REPLICA_DATA" promote
sleep 3

"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_cascade SELECT generate_series(8001,8500);"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

# Stop nodeA (old primary) and nodeC cascading replica
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$NODE3_DATA"   stop -m fast
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast

# Rewind nodeA → nodeB
"$PG_REWIND" --target-pgdata="$PRIMARY_DATA" \
              --source-pgdata="$REPLICA_DATA" -c

# Restart nodeB as new primary
start_pg "$REPLICA_DATA" "$REPLICA_PORT"

# Reconnect nodeA as standby of nodeB
_reconnect_as_standby "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_PORT"

# Verify nodeC can also reconnect under nodeB
_reconnect_as_standby "$NODE3_DATA" "$NODE3_PORT" "$REPLICA_PORT"

# End-to-end check: write on B, read back on A and C
"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_cascade VALUES (77777);"
sleep 2

COUNT_A=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_cascade WHERE id = 77777;")
COUNT_C=$("$PSQL" -p "$NODE3_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_cascade WHERE id = 77777;")

[ "$COUNT_A" -eq 1 ] || { echo "ERROR: nodeA did not receive cascading replication"; exit 1; }
[ "$COUNT_C" -eq 1 ] || { echo "ERROR: nodeC did not receive cascading replication"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
"$PG_CTL" -D "$PRIMARY_DATA" stop -m fast 2>/dev/null || true
"$PG_CTL" -D "$NODE3_DATA"   stop -m fast 2>/dev/null || true

echo "PASS: Scenario 3 — 3-node cascading topology, nodeA=$COUNT_A nodeC=$COUNT_C"

##############################################################################
# SCENARIO 4: Multiple rounds HA lifecycle (3 rounds, roles swap each round)
##############################################################################
echo ""
echo "=== SCENARIO 4: Multiple rounds HA lifecycle (3 rounds) ==="
_cleanup_all

# Round helper: given current_primary and current_standby, promote standby,
# diverge it, rewind old primary, reconnect as standby.
do_round() {
    local round=$1
    local cur_primary_data=$2
    local cur_primary_port=$3
    local cur_standby_data=$4
    local cur_standby_port=$5

    echo "  Round $round: primary=port$cur_primary_port standby=port$cur_standby_port"

    "$PSQL" -p "$cur_primary_port" -d postgres \
        -c "INSERT INTO t_rounds SELECT generate_series($((round*1000)), $((round*1000+100)));"

    # Promote standby
    "$PG_CTL" -D "$cur_standby_data" promote
    sleep 2

    # Diverge new primary
    "$PSQL" -p "$cur_standby_port" -d postgres \
        -c "INSERT INTO t_rounds SELECT generate_series($((round*10000)), $((round*10000+100)));"
    "$PSQL" -p "$cur_standby_port" -d postgres -c "CHECKPOINT;"

    # Stop old primary
    "$PG_CTL" -D "$cur_primary_data" stop -m immediate
    "$PG_CTL" -D "$cur_standby_data" stop -m fast

    # Rewind old primary
    "$PG_REWIND" --target-pgdata="$cur_primary_data" \
                  --source-pgdata="$cur_standby_data" -c

    # New primary starts, old primary reconnects as standby
    start_pg "$cur_standby_data" "$cur_standby_port"
    _reconnect_as_standby "$cur_primary_data" "$cur_primary_port" "$cur_standby_port"

    echo "  Round $round: PASS"
}

_init_primary "$PRIMARY_DATA" "$PRIMARY_PORT"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_rounds (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_rounds SELECT generate_series(1,100);"

_make_replica "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"
_wait_replica_sync "$PRIMARY_PORT"

# Round 1: primary=PRIMARY, standby=REPLICA  →  after: primary=REPLICA, standby=PRIMARY
do_round 1 "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"

# Stop what was old-primary (now standby) before rebuilding roles
"$PG_CTL" -D "$PRIMARY_DATA" stop -m fast 2>/dev/null || true

# Rebuild so REPLICA can be used as source for a fresh standby
# (PRIMARY_DATA was rewound, now we start fresh)
sleep 1

# Round 2: primary=REPLICA, standby=PRIMARY  →  after: primary=PRIMARY, standby=REPLICA
do_round 2 "$REPLICA_DATA" "$REPLICA_PORT" "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true
sleep 1

# Round 3: primary=PRIMARY, standby=REPLICA again
do_round 3 "$PRIMARY_DATA" "$PRIMARY_PORT" "$REPLICA_DATA" "$REPLICA_PORT"

# Final validation
FINAL_COUNT=$("$PSQL" -p "$REPLICA_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_rounds;")
[ "$FINAL_COUNT" -gt 0 ] || { echo "ERROR: t_rounds empty after 3 rounds"; exit 1; }

"$PG_CTL" -D "$REPLICA_DATA" stop -m fast 2>/dev/null || true
"$PG_CTL" -D "$PRIMARY_DATA" stop -m fast 2>/dev/null || true

echo "PASS: Scenario 4 — 3 HA cycles completed, final rows=$FINAL_COUNT"

##############################################################################
echo ""
echo "✅ pg_tde_rewind_full_ha_cycle: all scenarios passed"
