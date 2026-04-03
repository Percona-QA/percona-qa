#!/bin/bash

# pg_tde pg_upgrade scenarios test
#
# Runs multiple independent upgrade scenarios to validate pg_tde behaviour across
# a PostgreSQL major-version upgrade (e.g. PG-17 -> PG-18).
#
# Cross-version usage:
#   ./test_runner.sh --server_build_path /opt/pg18 \
#                    --old_server_build_path /opt/pg17 \
#                    --testname pg_tde_upgrade_scenarios_test.sh
#
# Scenarios:
#   1. Multiple databases with encrypted tables
#   2. Mixed table access methods (tde_heap + heap) with foreign key
#   3. Complex schema: indexes, sequences, views, check constraints
#   4. Large TOAST data in encrypted tables
#   5. Range-partitioned encrypted table
#   6. Global (cluster-level) key provider
#   7. pg_upgrade --check mode (pre-flight only, no actual upgrade)

OLD_BIN="${OLD_INSTALL_DIR:-$INSTALL_DIR}/bin"
NEW_BIN="$INSTALL_DIR/bin"
IO_METHOD="${IO_METHOD:-worker}"

OLD_MAJOR=$(get_pg_major_version_from_dir "$OLD_BIN")
NEW_MAJOR=$(get_pg_major_version_from_dir "$NEW_BIN")

# Ports dedicated to this test file to avoid conflicts with other tests
S_OLD_PORT=5437
S_NEW_PORT=5438

# Data directories for scenarios (re-used / cleaned between scenarios)
S_OLD_DATA="$RUN_DIR/scen_upgrade_old"
S_NEW_DATA="$RUN_DIR/scen_upgrade_new"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_SCENARIOS=()

echo "=== pg_tde pg_upgrade scenarios test ==="
echo "    Old: PG-${OLD_MAJOR} ($OLD_BIN)"
echo "    New: PG-${NEW_MAJOR} ($NEW_BIN)"

# ──────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ──────────────────────────────────────────────────────────────────────────────

_kill_ports() {
    lsof -ti:"$S_OLD_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
    lsof -ti:"$S_NEW_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
    sleep 1
}

_cleanup() {
    "$OLD_BIN/pg_ctl" -D "$S_OLD_DATA" stop -m immediate > /dev/null 2>&1 || true
    "$NEW_BIN/pg_ctl" -D "$S_NEW_DATA" stop -m immediate > /dev/null 2>&1 || true
    _kill_ports
    rm -rf "$S_OLD_DATA" "$S_NEW_DATA"
    rm -f delete_old_cluster.sh analyze_new_cluster.sh
}

# Initialize the old cluster. Callers may pass additional psql to run on it via
# the function body rather than arguments (keep it simple).
_init_old_cluster() {
    rm -rf "$S_OLD_DATA"
    "$OLD_BIN/initdb" -D "$S_OLD_DATA" \
        --set shared_preload_libraries=pg_tde \
        --set unix_socket_directories="$RUN_DIR" \
        > /dev/null 2>&1 || return 1
    # wal_level = replica is mandatory for pg_upgrade
    cat >> "$S_OLD_DATA/postgresql.conf" <<EOF
port = $S_OLD_PORT
wal_level = replica
EOF
    "$OLD_BIN/pg_ctl" -D "$S_OLD_DATA" -w start -o "-p $S_OLD_PORT" > /dev/null 2>&1 || return 1
    "$OLD_BIN/pg_isready" -p "$S_OLD_PORT" -t 30 > /dev/null 2>&1 || return 1
}

_stop_old_cluster() {
    "$OLD_BIN/pg_ctl" -D "$S_OLD_DATA" stop > /dev/null 2>&1 || true
}

_init_new_cluster() {
    rm -rf "$S_NEW_DATA"
    local io_flag=""
    if [[ "$NEW_MAJOR" -ge 18 ]]; then
        io_flag="--set io_method=$IO_METHOD"
    fi
    # shellcheck disable=SC2086
    "$NEW_BIN/initdb" -D "$S_NEW_DATA" \
        --set shared_preload_libraries=pg_tde \
        --set unix_socket_directories="$RUN_DIR" \
        $io_flag \
        > /dev/null 2>&1 || return 1
    cat >> "$S_NEW_DATA/postgresql.conf" <<EOF
port = $S_NEW_PORT
wal_level = replica
EOF
}

_run_pg_upgrade() {
    "$NEW_BIN/pg_upgrade" --no-sync \
        --old-datadir "$S_OLD_DATA" \
        --new-datadir "$S_NEW_DATA" \
        --old-bindir  "$OLD_BIN" \
        --new-bindir  "$NEW_BIN" \
        --socketdir   "$RUN_DIR" \
        --old-port    "$S_OLD_PORT" \
        --new-port    "$S_NEW_PORT" \
        > /dev/null 2>&1
}

# pg_upgrade copies relation files; pg_tde key store lives in $PGDATA/pg_tde/
# and must be present in the new cluster.
_copy_pg_tde_keys() {
    if [ -d "$S_OLD_DATA/pg_tde" ] && [ ! -d "$S_NEW_DATA/pg_tde" ]; then
        cp -R "$S_OLD_DATA/pg_tde" "$S_NEW_DATA/pg_tde"
    fi
}

_start_new_cluster() {
    "$NEW_BIN/pg_ctl" -D "$S_NEW_DATA" -w start -o "-p $S_NEW_PORT" > /dev/null 2>&1 || return 1
    "$NEW_BIN/pg_isready" -p "$S_NEW_PORT" -t 30 > /dev/null 2>&1 || return 1
}

_stop_new_cluster() {
    "$NEW_BIN/pg_ctl" -D "$S_NEW_DATA" stop > /dev/null 2>&1 || true
}

# Convenience psql wrappers
_old_psql() { "$OLD_BIN/psql" -p "$S_OLD_PORT" -h "$RUN_DIR" "$@"; }
_new_psql() { "$NEW_BIN/psql" -p "$S_NEW_PORT" -h "$RUN_DIR" "$@"; }

# ──────────────────────────────────────────────────────────────────────────────
# Scenario runner
# ──────────────────────────────────────────────────────────────────────────────

run_scenario() {
    local name="$1"
    local func="$2"
    echo ""
    echo "──────────────────────────────────────────────────"
    echo " Scenario: $name"
    echo "──────────────────────────────────────────────────"
    _cleanup
    if $func; then
        echo "[PASS] $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "[FAIL] $name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_SCENARIOS+=("$name")
        _cleanup
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 1 – Multiple databases with encrypted tables
# Each database uses its own key provider and key name.
# Validates that both survive the upgrade intact.
# ──────────────────────────────────────────────────────────────────────────────
scenario_multi_db() {
    local key1="$RUN_DIR/scen1_db1.key"
    local key2="$RUN_DIR/scen1_db2.key"
    rm -f "$key1" "$key2"

    _init_old_cluster || return 1

    # Database 1
    _old_psql -d postgres -c "CREATE DATABASE db1;" > /dev/null 2>&1
    _old_psql -d db1 -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d db1 -c "SELECT pg_tde_add_database_key_provider_file('vault1', '$key1');" > /dev/null 2>&1
    _old_psql -d db1 -c "SELECT pg_tde_create_key_using_database_key_provider('key1', 'vault1');" > /dev/null 2>&1
    _old_psql -d db1 -c "SELECT pg_tde_set_key_using_database_key_provider('key1', 'vault1');" > /dev/null 2>&1
    _old_psql -d db1 -c "CREATE TABLE t1 (id int PRIMARY KEY, v text) USING tde_heap;" > /dev/null 2>&1
    _old_psql -d db1 -c "INSERT INTO t1 SELECT i, 'db1_' || i FROM generate_series(1,50) i;" > /dev/null 2>&1

    # Database 2
    _old_psql -d postgres -c "CREATE DATABASE db2;" > /dev/null 2>&1
    _old_psql -d db2 -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d db2 -c "SELECT pg_tde_add_database_key_provider_file('vault2', '$key2');" > /dev/null 2>&1
    _old_psql -d db2 -c "SELECT pg_tde_create_key_using_database_key_provider('key2', 'vault2');" > /dev/null 2>&1
    _old_psql -d db2 -c "SELECT pg_tde_set_key_using_database_key_provider('key2', 'vault2');" > /dev/null 2>&1
    _old_psql -d db2 -c "CREATE TABLE t2 (id int PRIMARY KEY, v text) USING tde_heap;" > /dev/null 2>&1
    _old_psql -d db2 -c "INSERT INTO t2 SELECT i, 'db2_' || i FROM generate_series(1,75) i;" > /dev/null 2>&1

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local c1 c2
    c1=$(_new_psql -d db1 -t -c "SELECT count(*) FROM t1;" 2>/dev/null | tr -d ' ')
    c2=$(_new_psql -d db2 -t -c "SELECT count(*) FROM t2;" 2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$c1" = "50" ] && [ "$c2" = "75" ] || {
        echo "    db1 count=$c1 (expected 50), db2 count=$c2 (expected 75)"
        return 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 2 – Mixed table access methods with cross-table foreign key
# Encrypted (tde_heap) and plain (heap) tables co-exist in one database.
# ──────────────────────────────────────────────────────────────────────────────
scenario_mixed_methods() {
    local keyfile="$RUN_DIR/scen2.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1

    _old_psql -d postgres > /dev/null 2>&1 <<'SQL'
CREATE TABLE categories (id int PRIMARY KEY, name text) USING heap;
INSERT INTO categories VALUES (1,'alpha'),(2,'beta'),(3,'gamma');

CREATE TABLE events (
    id      serial PRIMARY KEY,
    cat_id  int NOT NULL REFERENCES categories(id),
    payload text
) USING tde_heap;
INSERT INTO events (cat_id, payload)
    SELECT (i % 3) + 1, md5(i::text)
    FROM generate_series(1, 200) i;
SQL

    local enc_count plain_count
    enc_count=$(_old_psql  -d postgres -t -c "SELECT count(*) FROM events;"     2>/dev/null | tr -d ' ')
    plain_count=$(_old_psql -d postgres -t -c "SELECT count(*) FROM categories;" 2>/dev/null | tr -d ' ')

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local enc_after plain_after fk_ok
    enc_after=$(_new_psql   -d postgres -t -c "SELECT count(*) FROM events;"     2>/dev/null | tr -d ' ')
    plain_after=$(_new_psql  -d postgres -t -c "SELECT count(*) FROM categories;" 2>/dev/null | tr -d ' ')
    # FK integrity: every event's cat_id must exist in categories
    fk_ok=$(_new_psql -d postgres -t \
        -c "SELECT count(*) FROM events e LEFT JOIN categories c ON c.id=e.cat_id WHERE c.id IS NULL;" \
        2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$enc_after"   = "$enc_count"   ] || { echo "    events count mismatch: $enc_after vs $enc_count"; return 1; }
    [ "$plain_after" = "$plain_count" ] || { echo "    categories count mismatch: $plain_after vs $plain_count"; return 1; }
    [ "$fk_ok"       = "0"            ] || { echo "    FK violation after upgrade: $fk_ok orphaned rows"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 3 – Complex schema: indexes, sequences, views, check constraints
# ──────────────────────────────────────────────────────────────────────────────
scenario_complex_schema() {
    local keyfile="$RUN_DIR/scen3.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1

    _old_psql -d postgres > /dev/null 2>&1 <<'SQL'
-- Encrypted table with various constraint types and a sequence
CREATE SEQUENCE order_seq START 1000;

CREATE TABLE orders (
    id       int DEFAULT nextval('order_seq') PRIMARY KEY,
    customer text        NOT NULL,
    amount   numeric(12,2) CHECK (amount > 0),
    status   text        NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending','shipped','done')),
    created  timestamptz NOT NULL DEFAULT now()
) USING tde_heap;

-- B-tree index on customer for fast lookups
CREATE INDEX idx_orders_customer ON orders(customer);
-- Partial index for open orders
CREATE INDEX idx_orders_pending   ON orders(created) WHERE status = 'pending';

INSERT INTO orders (customer, amount, status)
    SELECT 'cust_' || (i % 20),
           (i * 3.14)::numeric(12,2),
           CASE i % 3 WHEN 0 THEN 'pending' WHEN 1 THEN 'shipped' ELSE 'done' END
    FROM generate_series(1, 300) i;

-- View over encrypted table
CREATE VIEW v_pending AS
    SELECT id, customer, amount FROM orders WHERE status = 'pending';
SQL

    local row_count seq_val pending_via_view
    row_count=$(_old_psql      -d postgres -t -c "SELECT count(*) FROM orders;"    2>/dev/null | tr -d ' ')
    seq_val=$(_old_psql        -d postgres -t -c "SELECT last_value FROM order_seq;" 2>/dev/null | tr -d ' ')
    pending_via_view=$(_old_psql -d postgres -t -c "SELECT count(*) FROM v_pending;" 2>/dev/null | tr -d ' ')

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local row_after seq_after pending_after idx_count
    row_after=$(_new_psql      -d postgres -t -c "SELECT count(*) FROM orders;"    2>/dev/null | tr -d ' ')
    seq_after=$(_new_psql      -d postgres -t -c "SELECT last_value FROM order_seq;" 2>/dev/null | tr -d ' ')
    pending_after=$(_new_psql  -d postgres -t -c "SELECT count(*) FROM v_pending;" 2>/dev/null | tr -d ' ')
    idx_count=$(_new_psql      -d postgres -t \
        -c "SELECT count(*) FROM pg_indexes WHERE tablename='orders';" \
        2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$row_after"     = "$row_count"        ] || { echo "    row count mismatch: $row_after vs $row_count"; return 1; }
    [ "$seq_after"     = "$seq_val"          ] || { echo "    sequence last_value mismatch: $seq_after vs $seq_val"; return 1; }
    [ "$pending_after" = "$pending_via_view" ] || { echo "    view row count mismatch: $pending_after vs $pending_via_view"; return 1; }
    [ "$idx_count"     -ge 2                 ] || { echo "    expected >= 2 indexes, got $idx_count"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 4 – Large TOAST data in encrypted tables
# Rows whose text columns exceed 8 kB are stored in TOAST; verify they survive.
# ──────────────────────────────────────────────────────────────────────────────
scenario_toast_data() {
    local keyfile="$RUN_DIR/scen4.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1

    _old_psql -d postgres > /dev/null 2>&1 <<'SQL'
CREATE TABLE blobs (
    id      serial PRIMARY KEY,
    payload text,       -- will be > 8 kB -> TOAST
    tags    text[]
) USING tde_heap;

-- Insert 20 rows with ~16 kB payloads and array data
INSERT INTO blobs (payload, tags)
    SELECT repeat(md5(i::text), 400),       -- ~13 kB per row
           ARRAY['tag' || i, 'common']
    FROM generate_series(1, 20) i;
SQL

    local total_len
    total_len=$(_old_psql -d postgres -t \
        -c "SELECT sum(length(payload)) FROM blobs;" \
        2>/dev/null | tr -d ' ')

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local total_after row_count tag_check
    total_after=$(_new_psql -d postgres -t \
        -c "SELECT sum(length(payload)) FROM blobs;" \
        2>/dev/null | tr -d ' ')
    row_count=$(_new_psql  -d postgres -t -c "SELECT count(*) FROM blobs;" 2>/dev/null | tr -d ' ')
    # Verify array column survived (spot-check row 5)
    tag_check=$(_new_psql  -d postgres -t \
        -c "SELECT tags[2] FROM blobs WHERE id=5;" \
        2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$total_after" = "$total_len" ] || { echo "    TOAST payload total length mismatch: $total_after vs $total_len"; return 1; }
    [ "$row_count"   = "20"         ] || { echo "    row count mismatch: $row_count"; return 1; }
    [ "$tag_check"   = "common"     ] || { echo "    array column mismatch: got '$tag_check'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 5 – Range-partitioned encrypted table
# Parent and all partitions use tde_heap; data in each partition is verified.
# ──────────────────────────────────────────────────────────────────────────────
scenario_partitioned_table() {
    local keyfile="$RUN_DIR/scen5.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1

    _old_psql -d postgres > /dev/null 2>&1 <<'SQL'
CREATE TABLE measurements (
    sensor_id int,
    recorded  date    NOT NULL,
    value     numeric NOT NULL
) USING tde_heap PARTITION BY RANGE (recorded);

CREATE TABLE measurements_2023
    PARTITION OF measurements
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01')
    USING tde_heap;

CREATE TABLE measurements_2024
    PARTITION OF measurements
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')
    USING tde_heap;

CREATE TABLE measurements_2025
    PARTITION OF measurements
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')
    USING tde_heap;

-- Distribute 300 rows across partitions
INSERT INTO measurements (sensor_id, recorded, value)
    SELECT (i % 10) + 1,
           date '2023-01-01' + (i % 1095),
           round((random() * 100)::numeric, 2)
    FROM generate_series(1, 300) i;
SQL

    local total p2023 p2024 p2025
    total=$(_old_psql  -d postgres -t -c "SELECT count(*) FROM measurements;"          2>/dev/null | tr -d ' ')
    p2023=$(_old_psql  -d postgres -t -c "SELECT count(*) FROM measurements_2023;"     2>/dev/null | tr -d ' ')
    p2024=$(_old_psql  -d postgres -t -c "SELECT count(*) FROM measurements_2024;"     2>/dev/null | tr -d ' ')
    p2025=$(_old_psql  -d postgres -t -c "SELECT count(*) FROM measurements_2025;"     2>/dev/null | tr -d ' ')

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local total_a p2023_a p2024_a p2025_a
    total_a=$(_new_psql -d postgres -t -c "SELECT count(*) FROM measurements;"          2>/dev/null | tr -d ' ')
    p2023_a=$(_new_psql -d postgres -t -c "SELECT count(*) FROM measurements_2023;"     2>/dev/null | tr -d ' ')
    p2024_a=$(_new_psql -d postgres -t -c "SELECT count(*) FROM measurements_2024;"     2>/dev/null | tr -d ' ')
    p2025_a=$(_new_psql -d postgres -t -c "SELECT count(*) FROM measurements_2025;"     2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$total_a" = "$total" ] || { echo "    total count mismatch: $total_a vs $total"; return 1; }
    [ "$p2023_a" = "$p2023" ] || { echo "    2023 partition mismatch: $p2023_a vs $p2023"; return 1; }
    [ "$p2024_a" = "$p2024" ] || { echo "    2024 partition mismatch: $p2024_a vs $p2024"; return 1; }
    [ "$p2025_a" = "$p2025" ] || { echo "    2025 partition mismatch: $p2025_a vs $p2025"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 6 – Global (cluster-level) key provider
# Uses pg_tde_add_global_key_provider_file which applies across all databases.
# ──────────────────────────────────────────────────────────────────────────────
scenario_global_key_provider() {
    local keyfile="$RUN_DIR/scen6_global.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global-vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('global-key', 'global-vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('global-key', 'global-vault');" > /dev/null 2>&1

    _old_psql -d postgres > /dev/null 2>&1 <<'SQL'
CREATE TABLE global_enc (id int PRIMARY KEY, data text) USING tde_heap;
INSERT INTO global_enc SELECT i, 'global_' || i FROM generate_series(1, 120) i;
SQL

    local row_count
    row_count=$(_old_psql -d postgres -t -c "SELECT count(*) FROM global_enc;" 2>/dev/null | tr -d ' ')

    _stop_old_cluster
    _init_new_cluster || return 1
    _run_pg_upgrade   || return 1
    _copy_pg_tde_keys
    _start_new_cluster || return 1

    local row_after spot_check
    row_after=$(_new_psql -d postgres -t -c "SELECT count(*) FROM global_enc;" 2>/dev/null | tr -d ' ')
    # Spot-check a specific row value
    spot_check=$(_new_psql -d postgres -t \
        -c "SELECT data FROM global_enc WHERE id=60;" \
        2>/dev/null | tr -d ' ')

    _stop_new_cluster

    [ "$row_after"   = "$row_count"   ] || { echo "    row count mismatch: $row_after vs $row_count"; return 1; }
    [ "$spot_check"  = "global_60"    ] || { echo "    spot-check mismatch: '$spot_check'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Scenario 7 – pg_upgrade --check mode (pre-flight only, no actual upgrade)
# Verifies that the compatibility check passes and leaves both clusters intact.
# ──────────────────────────────────────────────────────────────────────────────
scenario_check_mode() {
    local keyfile="$RUN_DIR/scen7.key"
    rm -f "$keyfile"

    _init_old_cluster || return 1

    _old_psql -d postgres -c "CREATE EXTENSION pg_tde;" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('vault', '$keyfile');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('k', 'vault');" > /dev/null 2>&1
    _old_psql -d postgres -c "CREATE TABLE check_tbl (id int PRIMARY KEY) USING tde_heap;" > /dev/null 2>&1
    _old_psql -d postgres -c "INSERT INTO check_tbl SELECT generate_series(1,10);" > /dev/null 2>&1

    _stop_old_cluster
    _init_new_cluster || return 1

    # Run pg_upgrade in --check mode only (no data modification)
    "$NEW_BIN/pg_upgrade" --check --no-sync \
        --old-datadir "$S_OLD_DATA" \
        --new-datadir "$S_NEW_DATA" \
        --old-bindir  "$OLD_BIN" \
        --new-bindir  "$NEW_BIN" \
        --socketdir   "$RUN_DIR" \
        --old-port    "$S_OLD_PORT" \
        --new-port    "$S_NEW_PORT" \
        > /dev/null 2>&1 || { echo "    pg_upgrade --check failed"; return 1; }

    echo "    pg_upgrade --check passed; verifying old cluster data is intact..."

    # Old cluster must still be startable and its data untouched
    "$OLD_BIN/pg_ctl" -D "$S_OLD_DATA" -w start -o "-p $S_OLD_PORT" > /dev/null 2>&1 || return 1
    "$OLD_BIN/pg_isready" -p "$S_OLD_PORT" -t 30 > /dev/null 2>&1 || return 1

    local row_after
    row_after=$(_old_psql -d postgres -t -c "SELECT count(*) FROM check_tbl;" 2>/dev/null | tr -d ' ')
    "$OLD_BIN/pg_ctl" -D "$S_OLD_DATA" stop > /dev/null 2>&1 || true

    [ "$row_after" = "10" ] || { echo "    old cluster data corrupted after --check: count=$row_after"; return 1; }
    rm -f pg_upgrade_output.d pg_upgrade_server.log 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Run all scenarios
# ──────────────────────────────────────────────────────────────────────────────

run_scenario "Multiple databases with encrypted tables"      scenario_multi_db
run_scenario "Mixed table access methods (tde_heap + heap)"  scenario_mixed_methods
run_scenario "Complex schema: indexes, sequences, views"     scenario_complex_schema
run_scenario "Large TOAST data in encrypted tables"          scenario_toast_data
run_scenario "Range-partitioned encrypted table"             scenario_partitioned_table
run_scenario "Global (cluster-level) key provider"           scenario_global_key_provider
run_scenario "pg_upgrade --check mode (pre-flight only)"     scenario_check_mode

# Final cleanup
_cleanup

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo " pg_tde upgrade scenarios SUMMARY"
echo " Passed: $PASS_COUNT"
echo " Failed: $FAIL_COUNT"
if [ ${#FAILED_SCENARIOS[@]} -gt 0 ]; then
    echo " Failed scenarios:"
    for s in "${FAILED_SCENARIOS[@]}"; do
        echo "   - $s"
    done
fi
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

echo "=== DONE: all pg_tde upgrade scenarios passed ==="
