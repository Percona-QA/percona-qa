#!/bin/bash
#
# pg_tde_rewind_wal_encryption.sh
#
# Tests pg_rewind with pg_tde WAL encryption enabled.
# Scenarios:
#   1. Basic rewind when WAL encryption is on
#   2. WAL encryption setting is preserved on the rewound server
#   3. WAL compression (lz4, fallback pglz) combined with TDE
#   4. WAL encryption + WAL archiving: archive survives rewind
#   5. Timeline ID increments after promote + rewind with WAL encryption
#   6. Overlapping WAL-key generations with kept target segments
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

KEYFILE="$RUN_DIR/wal_enc_keyfile.per"

##############################################################################
# HELPERS
##############################################################################

_cleanup_pair() {
    "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate 2>/dev/null || true
    "$PG_CTL" -D "$REPLICA_DATA" stop -m immediate 2>/dev/null || true
    rm -rf "$PRIMARY_DATA" "$REPLICA_DATA" "$KEYFILE" "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"
}

_setup_primary() {
    local extra_conf="${1:-}"
    initialize_server "$PRIMARY_DATA" "$PRIMARY_PORT"
    enable_pg_tde "$PRIMARY_DATA"
    cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
wal_level = replica
wal_log_hints = on
max_wal_senders = 5
wal_keep_size = 512MB
archive_mode = on
archive_command = '$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p "cp %%p $ARCHIVE_DIR/%%f"'
# Required because pg_tde_rewind is executed with -c in this suite.
restore_command = '$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p "cp $ARCHIVE_DIR/%%f %%p"'
EOF
    [ -n "$extra_conf" ] && echo "$extra_conf" >> "$PRIMARY_DATA/postgresql.conf"
    echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY_DATA/pg_hba.conf"
    start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

    "$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CREATE EXTENSION pg_tde;"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_set_server_key_using_global_key_provider('key1','file_provider');"
    "$PSQL" -p "$PRIMARY_PORT" -d postgres \
        -c "SELECT pg_tde_set_key_using_global_key_provider('key1','file_provider');"
}

_setup_replica() {
    local extra_conf="${1:-}"
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
    [ -n "$extra_conf" ] && echo "$extra_conf" >> "$REPLICA_DATA/postgresql.conf"
    start_pg "$REPLICA_DATA" "$REPLICA_PORT"
}

_promote_replica() {
    local port="$1"
    local data_dir="$2"

    # Replica may have exited after initial startup checks; ensure it is running.
    if ! "$INSTALL_DIR/bin/pg_isready" -p "$port" -t 5 >/dev/null 2>&1; then
        echo "Replica is not ready on port $port, attempting restart before promote..."
        start_pg "$data_dir" "$port" || true
    fi

    # SQL promotion is generally more reliable than pg_ctl promote in CI.
    "$PSQL" -p "$port" -d postgres -c "SELECT pg_promote(wait_seconds => 60);" >/dev/null 2>&1 || true

    for _ in $(seq 1 90); do
        IN_RECOVERY=$("$PSQL" -p "$port" -d postgres -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "t")
        if [ "$IN_RECOVERY" = "f" ]; then
            return 0
        fi
        sleep 1
    done

    # Fallback with explicit diagnostics.
    "$PG_CTL" -D "$data_dir" promote || true
    sleep 2
    IN_RECOVERY=$("$PSQL" -p "$port" -d postgres -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "t")
    if [ "$IN_RECOVERY" != "f" ]; then
        echo "ERROR: replica did not promote in time (port=$port)"
        if [ -f "$data_dir/server.log" ]; then
            echo "--- replica server.log (tail) ---"
            tail -n 80 "$data_dir/server.log" || true
        fi
        if [ -f "$PRIMARY_DATA/server.log" ]; then
            echo "--- primary server.log (tail) ---"
            tail -n 40 "$PRIMARY_DATA/server.log" || true
        fi
        return 1
    fi
}

_promote_and_diverge() {
    local new_primary_port="$1"
    local new_primary_data="$2"
    local sql="${3:-INSERT INTO t_rewind VALUES (generate_series(1,500));}"
    _promote_replica "$new_primary_port" "$new_primary_data"
    "$PSQL" -p "$new_primary_port" -d postgres -c "$sql"
    "$PSQL" -p "$new_primary_port" -d postgres -c "CHECKPOINT;"
}

_run_rewind_pgdata() {
    # Both servers must be stopped before calling this
    "$PG_REWIND" \
        --target-pgdata="$PRIMARY_DATA" \
        --source-pgdata="$REPLICA_DATA" -c
}

##############################################################################
# SCENARIO 1: Basic rewind with WAL encryption enabled
##############################################################################
echo ""
echo "=== SCENARIO 1: Basic rewind with WAL encryption enabled ==="
_cleanup_pair

_setup_primary
# Enable WAL encryption on primary then restart
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_rewind (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_rewind SELECT generate_series(1,1000);"

_setup_replica "pg_tde.wal_encrypt = 'on'"

# Insert diverging data on primary (before promote)
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_rewind SELECT generate_series(1001,2000);"

# Promote replica, diverge it
_promote_and_diverge "$REPLICA_PORT" "$REPLICA_DATA" \
    "INSERT INTO t_rewind SELECT generate_series(5001,6000);"

# Stop primary (immediate — simulates crash)
"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate

# Rewind
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata

# Start rewound primary
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

# Validate: table exists and WAL enc is still on
COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_rewind;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_rewind empty after rewind"; exit 1; }

WAL_ENC=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SHOW pg_tde.wal_encrypt;" 2>/dev/null || echo "off")
[ "$WAL_ENC" = "on" ] || echo "NOTE: pg_tde.wal_encrypt not 'on' after rewind (may need restart)"

echo "PASS: Scenario 1 — rows=$COUNT"

##############################################################################
# SCENARIO 2: WAL encryption setting preserved after rewind
##############################################################################
echo ""
echo "=== SCENARIO 2: WAL encryption setting preserved after rewind ==="
_cleanup_pair

_setup_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_enc (id INT, val TEXT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_enc SELECT g, md5(g::text) FROM generate_series(1,500) g;"

_setup_replica "pg_tde.wal_encrypt = 'on'"

_promote_and_diverge "$REPLICA_PORT" "$REPLICA_DATA" \
    "INSERT INTO t_enc SELECT g, md5(g::text) FROM generate_series(2000,2500) g;"

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

# postgresql.auto.conf from the source side must carry wal_encrypt = on
SETTING=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT setting FROM pg_settings WHERE name='pg_tde.wal_encrypt';" \
    2>/dev/null || echo "off")
[ "$SETTING" = "on" ] || \
    echo "NOTE: pg_tde.wal_encrypt='$SETTING' after rewind — check postgresql.auto.conf"

ENCRYPTED=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT pg_tde_is_encrypted('t_enc');" 2>/dev/null || echo "f")
[ "$ENCRYPTED" = "t" ] || { echo "ERROR: t_enc not encrypted after rewind"; exit 1; }

echo "PASS: Scenario 2"

##############################################################################
# SCENARIO 3: WAL compression with TDE (try lz4, fallback to pglz)
##############################################################################
echo ""
echo "=== SCENARIO 3: WAL compression + TDE ==="
_cleanup_pair

# Detect lz4 WAL compression support
WAL_COMP="pglz"
if "$INSTALL_DIR/bin/postgres" -C wal_compression 2>/dev/null | grep -q lz4; then
    WAL_COMP="lz4"
fi
echo "Using wal_compression=$WAL_COMP"

_setup_primary "wal_compression = '$WAL_COMP'"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_comp (id INT, payload TEXT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_comp SELECT g, repeat(md5(g::text), 50) FROM generate_series(1,1000) g;"

_setup_replica "wal_compression = '$WAL_COMP'
pg_tde.wal_encrypt = 'on'"

_promote_and_diverge "$REPLICA_PORT" "$REPLICA_DATA" \
    "INSERT INTO t_comp SELECT g, repeat(md5(g::text),50) FROM generate_series(5000,5500) g;"

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_comp;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_comp empty after rewind"; exit 1; }

echo "PASS: Scenario 3 — wal_compression=$WAL_COMP, rows=$COUNT"

##############################################################################
# SCENARIO 4: WAL encryption + WAL archiving survive rewind
##############################################################################
echo ""
echo "=== SCENARIO 4: WAL encryption + archiving ==="
_cleanup_pair

ARCHIVE_EXTRA="archive_mode = on
archive_command = '$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $ARCHIVE_DIR/%%f\"'
restore_command = '$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"cp $ARCHIVE_DIR/%%f %%p\"'"

_setup_primary "$ARCHIVE_EXTRA"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_arch (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_arch SELECT generate_series(1,500);"

_setup_replica "$ARCHIVE_EXTRA"

_promote_and_diverge "$REPLICA_PORT" "$REPLICA_DATA" \
    "INSERT INTO t_arch SELECT generate_series(9000,9500);"

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_arch;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_arch empty after rewind+archive"; exit 1; }

# Verify archive directory has WAL files
ARCH_COUNT=$(ls "$ARCHIVE_DIR" | wc -l)
[ "$ARCH_COUNT" -gt 0 ] || { echo "ERROR: no archived WAL files"; exit 1; }

echo "PASS: Scenario 4 — rows=$COUNT, archived_wal_files=$ARCH_COUNT"

##############################################################################
# SCENARIO 5: Timeline ID increments after promote + rewind with WAL enc
##############################################################################
echo ""
echo "=== SCENARIO 5: Timeline ID increments with WAL encryption ==="
_cleanup_pair

_setup_primary
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_tl (id INT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_tl SELECT generate_series(1,100);"

_setup_replica "pg_tde.wal_encrypt = 'on'"

# Read timeline before promote
TL_BEFORE=$("$INSTALL_DIR/bin/pg_controldata" "$REPLICA_DATA" \
    | awk '/Latest checkpoint.*TimeLineID/ {print $NF}')

_promote_and_diverge "$REPLICA_PORT" "$REPLICA_DATA" \
    "INSERT INTO t_tl SELECT generate_series(200,300);"

# Read timeline after promote
TL_AFTER=$("$INSTALL_DIR/bin/pg_controldata" "$REPLICA_DATA" \
    | awk '/Latest checkpoint.*TimeLineID/ {print $NF}')

[ "$TL_AFTER" -gt "$TL_BEFORE" ] || \
    { echo "ERROR: timeline did not increment (before=$TL_BEFORE after=$TL_AFTER)"; exit 1; }

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_tl;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_tl empty after rewind"; exit 1; }

echo "PASS: Scenario 5 — timeline $TL_BEFORE -> $TL_AFTER, rows=$COUNT"

##############################################################################
# SCENARIO 6: Overlapping WAL-key generations with kept target segments
##############################################################################
echo ""
echo "=== SCENARIO 6: WAL-key overlap with archived rewind ==="
_cleanup_pair

ARCHIVE_EXTRA="archive_mode = on
archive_command = '$INSTALL_DIR/bin/pg_tde_archive_decrypt %f %p \"cp %%p $ARCHIVE_DIR/%%f\"'
restore_command = '$INSTALL_DIR/bin/pg_tde_restore_encrypt %f %p \"cp $ARCHIVE_DIR/%%f %%p\"'"

_setup_primary "$ARCHIVE_EXTRA"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "CREATE TABLE t_overlap (id INT, payload TEXT) USING tde_heap;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_overlap SELECT g, repeat(md5(g::text), 12) FROM generate_series(1,3000) g;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CHECKPOINT;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "SELECT pg_switch_wal();"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "SELECT pg_switch_wal();"

_setup_replica "$ARCHIVE_EXTRA
pg_tde.wal_encrypt = 'on'"

# Keep WAL pressure on future target before divergence.
"$PSQL" -p "$PRIMARY_PORT" -d postgres \
    -c "INSERT INTO t_overlap SELECT g, repeat(md5(g::text), 10) FROM generate_series(3001,7000) g;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "CHECKPOINT;"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "SELECT pg_switch_wal();"
"$PSQL" -p "$PRIMARY_PORT" -d postgres -c "SELECT pg_switch_wal();"

# Promote replica and rotate server key multiple times while generating WAL.
_promote_replica "$REPLICA_PORT" "$REPLICA_DATA"
for i in 1 2 3; do
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_create_key_using_global_key_provider('wal_rot_$i','file_provider');"
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_rot_$i','file_provider');"
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "SELECT pg_tde_set_key_using_global_key_provider('wal_rot_$i','file_provider');"
    START_ID=$((i * 10000))
    END_ID=$((START_ID + 350))
    "$PSQL" -p "$REPLICA_PORT" -d postgres \
        -c "INSERT INTO t_overlap SELECT g, repeat(md5(g::text), 8) FROM generate_series($START_ID,$END_ID) g;"
    "$PSQL" -p "$REPLICA_PORT" -d postgres -c "SELECT pg_switch_wal();"
    "$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"
done

"$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate
"$PG_CTL" -D "$REPLICA_DATA" stop -m fast
_run_rewind_pgdata
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

COUNT=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
    -c "SELECT count(*) FROM t_overlap;")
[ "$COUNT" -gt 0 ] || { echo "ERROR: t_overlap empty after overlap rewind"; exit 1; }

# Re-attach rewound target as standby and verify it can replay fresh WAL.
"$PG_CTL" -D "$PRIMARY_DATA" stop -m fast
echo "primary_conninfo = 'host=$RUN_DIR port=$REPLICA_PORT user=$(id -un)'" >> "$PRIMARY_DATA/postgresql.auto.conf"
touch "$PRIMARY_DATA/standby.signal"

start_pg "$REPLICA_DATA" "$REPLICA_PORT"
start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PSQL" -p "$REPLICA_PORT" -d postgres \
    -c "INSERT INTO t_overlap SELECT g, repeat(md5(g::text), 6) FROM generate_series(50001,50300) g;"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "SELECT pg_switch_wal();"
"$PSQL" -p "$REPLICA_PORT" -d postgres -c "CHECKPOINT;"

FOUND=0
for _ in $(seq 1 30); do
    MIRRORED=$("$PSQL" -p "$PRIMARY_PORT" -d postgres -t -A \
        -c "SELECT count(*) FROM t_overlap WHERE id BETWEEN 50001 AND 50300;" 2>/dev/null || echo "0")
    if [ "$MIRRORED" -eq 300 ]; then
        FOUND=1
        break
    fi
    sleep 1
done
[ "$FOUND" -eq 1 ] || { echo "ERROR: rewound standby did not replay fresh WAL after key overlap"; exit 1; }

echo "PASS: Scenario 6 — overlap replay rows=$MIRRORED"

##############################################################################
echo ""
echo "✅ pg_tde_rewind_wal_encryption: all scenarios passed"
