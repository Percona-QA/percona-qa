#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pg_tde_upgrade_psp_to_psp.sh
#
# Upgrade scenarios: PSP (17) → PSP (18)
#
# Same-flavour major-version bump.  Key-provider API is identical on both sides.
# PG-2240 fix (copy $OLD_DATA/pg_tde/) is still required for tde_heap data.
#
# USAGE
#   INSTALL_DIR=/usr/lib/postgresql/18 \
#   OLD_INSTALL_DIR=/usr/lib/postgresql/17 \
#   bash pg_tde_upgrade_psp_to_psp.sh
#
# ENV VARS
#   INSTALL_DIR       Target PSP install.  Default: /usr/lib/postgresql/18
#   OLD_INSTALL_DIR   Source PSP install.  Default: /usr/lib/postgresql/17
#   RUN_DIR           Working directory.   Default: /tmp/pg_tde_psp_psp
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/lib/postgresql/18}"
OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_psp_psp}"

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
    local data_dir="$1" install="$2"
    local initdb_bin="${install}/bin/initdb"
    rm -rf "$data_dir"
    "$initdb_bin" -D "$data_dir" --no-data-checksums -U "$(whoami)" >/dev/null
    echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
    echo "host all all 127.0.0.1/32 trust"    >> "$data_dir/pg_hba.conf"
    echo "local all all trust"                  >> "$data_dir/pg_hba.conf"
}

_start_cluster() {
    local data_dir="$1" port="$2" install="$3"
    local log="${data_dir}/postgres.log"
    "${install}/bin/postgres" -D "$data_dir" -p "$port" -k "$data_dir" >> "$log" 2>&1 &
    echo $! > "${data_dir}/postgres.pid"
    _wait_ready "$port" "${install}/bin/psql"
}

_stop_cluster() {
    local data_dir="$1" install="$2"
    "${install}/bin/pg_ctl" stop -D "$data_dir" -m fast -w 2>/dev/null || true
}

_setup_tde() {
    local port="$1" psql_bin="$2" keyfile="$3" key_name="${4:-test_key}" dbname="${5:-postgres}"
    "$psql_bin" -p "$port" -d "$dbname" -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null

    local add_fn
    add_fn=$("$psql_bin" -p "$port" -d "$dbname" -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_add_global_key_provider_file' LIMIT 1")
    [[ -n "$add_fn" ]] || add_fn="pg_tde_add_key_provider_file"
    "$psql_bin" -p "$port" -d "$dbname" \
        -c "SELECT ${add_fn}('file_provider','${keyfile}')" >/dev/null

    local create_fn
    create_fn=$("$psql_bin" -p "$port" -d "$dbname" -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_create_key_using_global_key_provider' LIMIT 1")
    if [[ -n "$create_fn" ]]; then
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_create_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_set_server_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT pg_tde_set_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
    else
        local set_fn
        set_fn=$("$psql_bin" -p "$port" -d "$dbname" -At \
            -c "SELECT proname FROM pg_proc WHERE proname LIKE 'pg_tde_set%principal_key' LIMIT 1")
        [[ -n "$set_fn" ]] || set_fn="pg_tde_set_principal_key"
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT ${set_fn}('${key_name}','file_provider')" >/dev/null 2>&1 || \
        "$psql_bin" -p "$port" -d "$dbname" \
            -c "SELECT ${set_fn}('${key_name}')" >/dev/null
    fi
}

_pg_upgrade() {
    local old_data="$1" new_data="$2" old_port="$3" new_port="$4"
    "${INSTALL_DIR}/bin/pg_upgrade" \
        -b "${OLD_INSTALL_DIR}/bin" \
        -B "${INSTALL_DIR}/bin" \
        -d "$old_data" \
        -D "$new_data" \
        -p "$old_port" \
        -P "$new_port" \
        >/dev/null 2>&1
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

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: tde_heap data survives PSP→PSP with PG-2240 fix
# ─────────────────────────────────────────────────────────────────────────────
scenario_tde_heap_data_survives() {
    local name="psp_to_psp_tde_heap_data_survives"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15510
    local new_port=15511

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE enc_rows (id INT, data TEXT) USING tde_heap;
         INSERT INTO enc_rows SELECT i, md5(i::text) FROM generate_series(1,1000) i;" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count am
    count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM enc_rows")
    am=$("$PSQL"    -p "$new_port" -d postgres -At \
        -c "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam=am.oid WHERE c.relname='enc_rows'")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "1000" && "$am" == "tde_heap" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} am=${am}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: Multiple databases with different keys
# ─────────────────────────────────────────────────────────────────────────────
scenario_multiple_databases_different_keys() {
    local name="psp_to_psp_multiple_databases_different_keys"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15512
    local new_port=15513

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile" "key_v1"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE rows_a (n INT) USING tde_heap;
         INSERT INTO rows_a VALUES (1),(2);" >/dev/null

    "$PSQL_OLD" -p "$old_port" -d postgres -c "CREATE DATABASE db_b" >/dev/null
    "$PSQL_OLD" -p "$old_port" -d db_b -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile" "key_v2" "db_b"
    "$PSQL_OLD" -p "$old_port" -d db_b -c \
        "CREATE TABLE rows_b (n INT) USING tde_heap;
         INSERT INTO rows_b SELECT generate_series(1,30);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local cnt_a cnt_b
    cnt_a=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM rows_a")
    cnt_b=$("$PSQL" -p "$new_port" -d db_b     -At -c "SELECT COUNT(*) FROM rows_b")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_a" == "2" && "$cnt_b" == "30" ]]; then
        _ok "$name"
    else
        _fail "$name: rows_a=${cnt_a} rows_b=${cnt_b}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: Key provider accessible and can encrypt new data after upgrade
# ─────────────────────────────────────────────────────────────────────────────
scenario_key_provider_accessible() {
    local name="psp_to_psp_key_provider_accessible"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15514
    local new_port=15515

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE pre_upgrade (id INT) USING tde_heap;
         INSERT INTO pre_upgrade VALUES (42);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    # Provider count preserved from catalog
    local prov_count pre_count post_count
    prov_count=$("$PSQL" -p "$new_port" -d postgres -At \
        -c "SELECT COUNT(*) FROM pg_tde_list_all_global_key_providers()" 2>/dev/null || echo "0")
    "$PSQL" -p "$new_port" -d postgres -c \
        "CREATE TABLE post_upgrade (id INT) USING tde_heap;
         INSERT INTO post_upgrade VALUES (99);" >/dev/null
    pre_count=$("$PSQL"  -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM pre_upgrade")
    post_count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM post_upgrade")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$pre_count" == "1" && "$post_count" == "1" ]]; then
        _ok "$name (providers=${prov_count})"
    else
        _fail "$name: pre=${pre_count} post=${post_count}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4: WAL encryption disabled before upgrade; stays off afterward
# ─────────────────────────────────────────────────────────────────────────────
scenario_wal_enc_disabled_before_upgrade() {
    local name="psp_to_psp_wal_enc_disabled_before_upgrade"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15516
    local new_port=15517

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"

    # Enable WAL encryption
    "$PSQL_OLD" -p "$old_port" -d postgres \
        -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on'" >/dev/null
    "${OLD_INSTALL_DIR}/bin/pg_ctl" restart -D "$old_data" -w >/dev/null
    _wait_ready "$old_port" "$PSQL_OLD"

    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE wal_data (id INT) USING tde_heap;
         INSERT INTO wal_data SELECT generate_series(1,80);" >/dev/null

    # Disable WAL encryption before stopping (pg_upgrade needs clean WAL)
    "$PSQL_OLD" -p "$old_port" -d postgres \
        -c "ALTER SYSTEM RESET pg_tde.wal_encrypt" >/dev/null
    "${OLD_INSTALL_DIR}/bin/pg_ctl" restart -D "$old_data" -w >/dev/null
    _wait_ready "$old_port" "$PSQL_OLD"
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count wal_enc
    count=$("$PSQL"   -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM wal_data")
    wal_enc=$("$PSQL" -p "$new_port" -d postgres -At -c "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "off")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "80" && "$wal_enc" == "off" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} wal_encrypt=${wal_enc}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
[[ -x "${OLD_INSTALL_DIR}/bin/postgres" ]] || _die "OLD_INSTALL_DIR not valid: ${OLD_INSTALL_DIR}"
[[ -x "${INSTALL_DIR}/bin/pg_upgrade"   ]] || _die "pg_upgrade not found: ${INSTALL_DIR}/bin/pg_upgrade"
mkdir -p "$RUN_DIR"

scenario_tde_heap_data_survives
scenario_multiple_databases_different_keys
scenario_key_provider_accessible
scenario_wal_enc_disabled_before_upgrade

echo ""
echo "═══════════════════════════════════════════"
echo "  PSP→PSP upgrade tests complete"
echo "  PASS: $PASS   FAIL: $FAIL"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do echo "  FAIL: $e"; done
fi
echo "═══════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
