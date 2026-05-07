#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pg_tde_upgrade_access_method.sh
#
# Five heap ↔ tde_heap permutations across a major-version pg_upgrade.
#
# Permutations
# ────────────
#  1. all heap  → all heap      Baseline: no TDE, plain upgrade.
#  2. all tde_heap → tde_heap   PG-2240 core; pg_tde dir copy required.
#  3. mixed heap+tde_heap        Both access methods survive upgrade.
#  4. heap → enable TDE after   Plain upgrade, then activate TDE on new cluster.
#  5. tde_heap → convert first  Rewrite tables as heap before pg_upgrade; no copy needed.
#
# USAGE
#   INSTALL_DIR=/usr/lib/postgresql/18 \
#   OLD_INSTALL_DIR=/usr/lib/postgresql/17 \
#   bash pg_tde_upgrade_access_method.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/lib/postgresql/18}"
OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_am_upgrade}"

PSQL_OLD="${OLD_INSTALL_DIR}/bin/psql"
PSQL="${INSTALL_DIR}/bin/psql"

PASS=0; FAIL=0; ERRORS=()

_die()  { echo "FATAL: $*" >&2; exit 1; }
_info() { echo "[INFO] $*"; }
_ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); ERRORS+=("$1"); }

_wait_ready() {
    local port="$1" psql_bin="$2"
    for i in $(seq 1 30); do
        "$psql_bin" -p "$port" -d postgres -c "SELECT 1" >/dev/null 2>&1 && return 0
        sleep 1
    done
    _die "Cluster on port $port did not become ready"
}

_make_cluster() {
    local data_dir="$1" install="$2" tde="${3:-no}"
    rm -rf "$data_dir"
    "${install}/bin/initdb" -D "$data_dir" --no-data-checksums -U "$(whoami)" >/dev/null
    if [[ "$tde" == "yes" ]]; then
        echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
    fi
    echo "host all all 127.0.0.1/32 trust" >> "$data_dir/pg_hba.conf"
    echo "local all all trust"               >> "$data_dir/pg_hba.conf"
}

_make_cluster_tde_heap_default() {
    local data_dir="$1" install="$2"
    rm -rf "$data_dir"
    "${install}/bin/initdb" -D "$data_dir" --no-data-checksums -U "$(whoami)" >/dev/null
    echo "shared_preload_libraries = 'pg_tde'"      >> "$data_dir/postgresql.conf"
    echo "default_table_access_method = 'tde_heap'" >> "$data_dir/postgresql.conf"
    echo "host all all 127.0.0.1/32 trust"          >> "$data_dir/pg_hba.conf"
    echo "local all all trust"                        >> "$data_dir/pg_hba.conf"
}

_start_cluster() {
    local data_dir="$1" port="$2" install="$3"
    "${install}/bin/postgres" -D "$data_dir" -p "$port" -k "$data_dir" \
        >> "${data_dir}/postgres.log" 2>&1 &
    echo $! > "${data_dir}/postgres.pid"
    _wait_ready "$port" "${install}/bin/psql"
}

_stop_cluster() {
    local data_dir="$1" install="$2"
    "${install}/bin/pg_ctl" stop -D "$data_dir" -m fast -w 2>/dev/null || true
}

_setup_tde() {
    local port="$1" psql_bin="$2" keyfile="$3" key="${4:-test_key}" dbname="${5:-postgres}"
    "$psql_bin" -p "$port" -d "$dbname" -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null

    local add_fn
    add_fn=$("$psql_bin" -p "$port" -d "$dbname" -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_add_global_key_provider_file' LIMIT 1")
    [[ -n "$add_fn" ]] || add_fn="pg_tde_add_key_provider_file"
    "$psql_bin" -p "$port" -d "$dbname" \
        -c "SELECT ${add_fn}('file_provider','${keyfile}')" >/dev/null

    if "$psql_bin" -p "$port" -d "$dbname" -At \
            -c "SELECT 1 FROM pg_proc WHERE proname='pg_tde_create_key_using_global_key_provider' LIMIT 1" \
            2>/dev/null | grep -q 1; then
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_create_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_set_server_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_set_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
    else
        local set_fn
        set_fn=$("$psql_bin" -p "$port" -d "$dbname" -At \
            -c "SELECT proname FROM pg_proc WHERE proname LIKE 'pg_tde_set%principal_key' LIMIT 1")
        [[ -n "$set_fn" ]] || set_fn="pg_tde_set_principal_key"
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT ${set_fn}('${key}','file_provider')" >/dev/null 2>&1 || \
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT ${set_fn}('${key}')" >/dev/null
    fi
}

_pg_upgrade() {
    local old_data="$1" new_data="$2" old_port="$3" new_port="$4" extra="${5:-}"
    # shellcheck disable=SC2086
    "${INSTALL_DIR}/bin/pg_upgrade" \
        -b "${OLD_INSTALL_DIR}/bin" -B "${INSTALL_DIR}/bin" \
        -d "$old_data" -D "$new_data" \
        -p "$old_port" -P "$new_port" \
        ${extra} >/dev/null 2>&1
}

_copy_pg_tde_dir() {
    local old_data="$1" new_data="$2"
    if [[ -d "${old_data}/pg_tde" ]]; then
        rm -rf "${new_data}/pg_tde"
        cp -R "${old_data}/pg_tde" "${new_data}/pg_tde"
        return 0
    fi
    return 1
}

_get_am() {
    local port="$1" psql_bin="$2" table="$3"
    "$psql_bin" -p "$port" -d postgres -At \
        -c "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam=am.oid WHERE c.relname='${table}'"
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: all heap → all heap (baseline, no TDE)
# ─────────────────────────────────────────────────────────────────────────────
scenario_all_heap_baseline() {
    local name="am_all_heap_baseline"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local old_port=15520
    local new_port=15521

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE heap_tbl (id INT, data TEXT) USING heap;
         INSERT INTO heap_tbl SELECT i, md5(i::text) FROM generate_series(1,300) i;" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"
    local count am
    count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM heap_tbl")
    am=$(_get_am "$new_port" "$PSQL" "heap_tbl")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "300" && "$am" == "heap" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} am=${am}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: all tde_heap → tde_heap (PG-2240 primary scenario)
# ─────────────────────────────────────────────────────────────────────────────
scenario_all_tde_heap_pg2240_fix() {
    local name="am_all_tde_heap_pg2240_fix"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15522
    local new_port=15523

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster_tde_heap_default "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE tbl_a (id INT, val TEXT);
         INSERT INTO tbl_a SELECT i, md5(i::text) FROM generate_series(1,400) i;
         CREATE TABLE tbl_b (x NUMERIC);
         INSERT INTO tbl_b SELECT random() FROM generate_series(1,100);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster_tde_heap_default "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local cnt_a cnt_b am_a am_b
    cnt_a=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM tbl_a")
    cnt_b=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM tbl_b")
    am_a=$(_get_am "$new_port" "$PSQL" "tbl_a")
    am_b=$(_get_am "$new_port" "$PSQL" "tbl_b")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_a" == "400" && "$cnt_b" == "100" && "$am_a" == "tde_heap" && "$am_b" == "tde_heap" ]]; then
        _ok "$name"
    else
        _fail "$name: tbl_a=${cnt_a}/${am_a}  tbl_b=${cnt_b}/${am_b}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: mixed heap + tde_heap in same cluster
# ─────────────────────────────────────────────────────────────────────────────
scenario_mixed_heap_and_tde_heap() {
    local name="am_mixed_heap_tde_heap"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15524
    local new_port=15525

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR" "yes"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE plain     (id INT) USING heap;
         INSERT INTO plain SELECT generate_series(1,100);
         CREATE TABLE encrypted (id INT, secret TEXT) USING tde_heap;
         INSERT INTO encrypted SELECT i, md5(i::text) FROM generate_series(1,150) i;" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR" "yes"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local cnt_p cnt_e am_p am_e
    cnt_p=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM plain")
    cnt_e=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM encrypted")
    am_p=$(_get_am "$new_port" "$PSQL" "plain")
    am_e=$(_get_am "$new_port" "$PSQL" "encrypted")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_p" == "100" && "$cnt_e" == "150" && "$am_p" == "heap" && "$am_e" == "tde_heap" ]]; then
        _ok "$name"
    else
        _fail "$name: plain=${cnt_p}/${am_p}  encrypted=${cnt_e}/${am_e}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4: heap → enable TDE after upgrade
# ─────────────────────────────────────────────────────────────────────────────
scenario_heap_enable_tde_after_upgrade() {
    local name="am_heap_enable_tde_after_upgrade"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15526
    local new_port=15527

    rm -rf "$workdir"; mkdir -p "$workdir"

    # Old cluster: plain heap, no TDE
    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE plain_data (id INT, info TEXT);
         INSERT INTO plain_data SELECT i, md5(i::text) FROM generate_series(1,200) i;" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    # New cluster: preload pg_tde but do not set as default yet
    _make_cluster "$new_data" "$INSTALL_DIR" "yes"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"
    _setup_tde "$new_port" "$PSQL" "$keyfile"

    # Plain data must be intact; new tde_heap table must work
    "$PSQL" -p "$new_port" -d postgres -c \
        "CREATE TABLE new_encrypted (id INT) USING tde_heap;
         INSERT INTO new_encrypted VALUES (1),(2),(3);" >/dev/null

    local cnt_old cnt_new am_old am_new
    cnt_old=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM plain_data")
    cnt_new=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM new_encrypted")
    am_old=$(_get_am "$new_port" "$PSQL" "plain_data")
    am_new=$(_get_am "$new_port" "$PSQL" "new_encrypted")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_old" == "200" && "$cnt_new" == "3" && "$am_old" == "heap" && "$am_new" == "tde_heap" ]]; then
        _ok "$name"
    else
        _fail "$name: plain=${cnt_old}/${am_old}  new=${cnt_new}/${am_new}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 5: tde_heap → convert to heap before upgrade (no pg_tde dir copy needed)
# ─────────────────────────────────────────────────────────────────────────────
scenario_tde_heap_convert_before_upgrade() {
    local name="am_tde_heap_convert_before_upgrade"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15528
    local new_port=15529

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR" "yes"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE was_encrypted (id INT, data TEXT) USING tde_heap;
         INSERT INTO was_encrypted SELECT i, md5(i::text) FROM generate_series(1,250) i;" >/dev/null

    # Convert tde_heap → heap before pg_upgrade (data is now plaintext on disk)
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "ALTER TABLE was_encrypted SET ACCESS METHOD heap" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    # New cluster: plain, no pg_tde (table is now heap)
    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    # No pg_tde dir copy needed — table was converted to heap
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count am
    count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM was_encrypted")
    am=$(_get_am "$new_port" "$PSQL" "was_encrypted")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "250" && "$am" == "heap" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} am=${am}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
[[ -x "${OLD_INSTALL_DIR}/bin/postgres"  ]] || _die "OLD_INSTALL_DIR not valid: $OLD_INSTALL_DIR"
[[ -x "${INSTALL_DIR}/bin/pg_upgrade"   ]] || _die "pg_upgrade not found: ${INSTALL_DIR}/bin/pg_upgrade"
mkdir -p "$RUN_DIR"

scenario_all_heap_baseline
scenario_all_tde_heap_pg2240_fix
scenario_mixed_heap_and_tde_heap
scenario_heap_enable_tde_after_upgrade
scenario_tde_heap_convert_before_upgrade

echo ""
echo "═══════════════════════════════════════════"
echo "  Access-method upgrade tests complete"
echo "  PASS: $PASS   FAIL: $FAIL"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do echo "  FAIL: $e"; done
fi
echo "═══════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
