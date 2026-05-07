#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pg_tde_upgrade_ppg_to_psp.sh
#
# Upgrade scenarios: PPG (<17) → PSP (>=17)
#
# PG-2240: pg_upgrade does not copy $OLD_DATA/pg_tde/ (encrypted DEK store).
# Fix applied here: copy that directory after pg_upgrade and before starting
# the new cluster.
#
# USAGE
#   INSTALL_DIR=/usr/lib/postgresql/18 \
#   OLD_INSTALL_DIR=/usr/lib/postgresql/17 \
#   bash pg_tde_upgrade_ppg_to_psp.sh
#
# ENV VARS
#   INSTALL_DIR       New PostgreSQL install (PSP target). Default: /usr/lib/postgresql/18
#   OLD_INSTALL_DIR   Old PostgreSQL install (PPG source). Default: /usr/lib/postgresql/17
#   RUN_DIR           Working directory for cluster data.  Default: /tmp/pg_tde_ppg_psp
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/lib/postgresql/18}"
OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_ppg_psp}"

INITDB="${OLD_INSTALL_DIR}/bin/initdb"
OLD_PG="${OLD_INSTALL_DIR}/bin/postgres"
PSQL_OLD="${OLD_INSTALL_DIR}/bin/psql"
PG_UPGRADE="${INSTALL_DIR}/bin/pg_upgrade"
PSQL="${INSTALL_DIR}/bin/psql"

PASS=0; FAIL=0; ERRORS=()

_die()  { echo "FATAL: $*" >&2; exit 1; }
_info() { echo "[INFO] $*"; }
_ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); ERRORS+=("$1"); }

_require_binaries() {
    [[ -x "$INITDB" ]]    || _die "initdb not found at $INITDB"
    [[ -x "$OLD_PG" ]]    || _die "postgres not found at $OLD_PG"
    [[ -x "$PG_UPGRADE" ]] || _die "pg_upgrade not found at $PG_UPGRADE"
}

_wait_ready() {
    local port="$1"
    local psql_bin="$2"
    for i in $(seq 1 30); do
        "$psql_bin" -p "$port" -d postgres -c "SELECT 1" >/dev/null 2>&1 && return 0
        sleep 1
    done
    _die "Cluster on port $port did not become ready"
}

_make_cluster() {
    local data_dir="$1" port="$2" install="$3"
    local initdb_bin="${install}/bin/initdb"
    rm -rf "$data_dir"
    "$initdb_bin" -D "$data_dir" --no-data-checksums -U "$(whoami)" >/dev/null
    echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
    echo "host all all 127.0.0.1/32 trust"    >> "$data_dir/pg_hba.conf"
    echo "local all all trust"                  >> "$data_dir/pg_hba.conf"
}

_start_cluster() {
    local data_dir="$1" port="$2" install="$3"
    local pg_bin="${install}/bin/postgres"
    local log="${data_dir}/postgres.log"
    "$pg_bin" -D "$data_dir" -p "$port" -k "$data_dir" >> "$log" 2>&1 &
    echo $! > "${data_dir}/postgres.pid"
    _wait_ready "$port" "${install}/bin/psql"
}

_stop_cluster() {
    local data_dir="$1" install="$2"
    local pg_ctl="${install}/bin/pg_ctl"
    "$pg_ctl" stop -D "$data_dir" -m fast -w 2>/dev/null || true
}

_setup_tde() {
    local port="$1" psql_bin="$2" keyfile="$3" key_name="${4:-test_key}"
    "$psql_bin" -p "$port" -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null

    local fn
    fn=$("$psql_bin" -p "$port" -d postgres -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_add_global_key_provider_file' LIMIT 1" 2>/dev/null || echo "")
    if [[ -z "$fn" ]]; then
        fn="pg_tde_add_key_provider_file"
    fi
    "$psql_bin" -p "$port" -d postgres \
        -c "SELECT ${fn}('file_provider','${keyfile}')" >/dev/null

    local set_fn
    set_fn=$("$psql_bin" -p "$port" -d postgres -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_create_key_using_global_key_provider' LIMIT 1" 2>/dev/null || echo "")
    if [[ -n "$set_fn" ]]; then
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_create_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_set_server_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_set_key_using_global_key_provider('${key_name}','file_provider')" >/dev/null 2>&1 || true
    else
        local old_fn
        old_fn=$("$psql_bin" -p "$port" -d postgres -At \
            -c "SELECT proname FROM pg_proc WHERE proname IN ('pg_tde_set_global_principal_key','pg_tde_set_server_principal_key','pg_tde_set_principal_key') LIMIT 1" 2>/dev/null || echo "pg_tde_set_principal_key")
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT ${old_fn}('${key_name}','file_provider')" >/dev/null 2>&1 || \
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT ${old_fn}('${key_name}')" >/dev/null
    fi
}

_run_pg_upgrade() {
    local old_data="$1" new_data="$2" old_port="$3" new_port="$4" extra="${5:-}"
    local new_bin="${INSTALL_DIR}/bin"
    local old_bin="${OLD_INSTALL_DIR}/bin"
    # shellcheck disable=SC2086
    "${new_bin}/pg_upgrade" \
        -b "$old_bin" \
        -B "$new_bin" \
        -d "$old_data" \
        -D "$new_data" \
        -p "$old_port" \
        -P "$new_port" \
        ${extra} 2>&1
}

_copy_pg_tde_dir() {
    local old_data="$1" new_data="$2"
    if [[ -d "${old_data}/pg_tde" ]]; then
        rm -rf "${new_data}/pg_tde"
        cp -R "${old_data}/pg_tde" "${new_data}/pg_tde"
        _info "Copied pg_tde key-material directory (PG-2240 fix)"
        return 0
    fi
    _info "WARNING: pg_tde directory not found in old cluster"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: tde_heap data intact after PPG→PSP with pg_tde dir copy (PG-2240)
# ─────────────────────────────────────────────────────────────────────────────
scenario_file_provider_data_intact() {
    local name="ppg_to_psp_file_provider_data_intact"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old_data"
    local new_data="${workdir}/new_data"
    local keyfile="${workdir}/tde.per"
    local old_port=15500
    local new_port=15501

    rm -rf "$workdir"
    mkdir -p "$workdir"

    _make_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile" "ppg_key"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE secrets (id INT, payload TEXT) USING tde_heap;
         INSERT INTO secrets SELECT i, md5(i::text) FROM generate_series(1,500) i;" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    if _run_pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port" | grep -q "Clusters are compatible"; then
        : # pg_upgrade succeeded
    fi
    if ! "${INSTALL_DIR}/bin/pg_upgrade" \
            -b "${OLD_INSTALL_DIR}/bin" -B "${INSTALL_DIR}/bin" \
            -d "$old_data" -D "$new_data" \
            -p "$old_port" -P "$new_port" >/dev/null 2>&1; then
        _fail "$name: pg_upgrade failed"
        return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count
    count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM secrets")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "500" ]]; then
        _ok "$name"
    else
        _fail "$name: expected 500 rows, got ${count}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: ALTER EXTENSION pg_tde UPDATE succeeds post-upgrade
# ─────────────────────────────────────────────────────────────────────────────
scenario_alter_extension_update() {
    local name="ppg_to_psp_alter_extension_update"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old_data"
    local new_data="${workdir}/new_data"
    local keyfile="${workdir}/tde.per"
    local old_port=15502
    local new_port=15503

    rm -rf "$workdir"
    mkdir -p "$workdir"

    _make_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE ext_tbl (id INT) USING tde_heap;
         INSERT INTO ext_tbl VALUES (1),(2),(3);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$new_port" "$INSTALL_DIR"
    if ! "${INSTALL_DIR}/bin/pg_upgrade" \
            -b "${OLD_INSTALL_DIR}/bin" -B "${INSTALL_DIR}/bin" \
            -d "$old_data" -D "$new_data" \
            -p "$old_port" -P "$new_port" >/dev/null 2>&1; then
        _fail "$name: pg_upgrade failed"
        return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local upd_rc count
    "$PSQL" -p "$new_port" -d postgres -c "ALTER EXTENSION pg_tde UPDATE" >/dev/null 2>&1
    upd_rc=$?
    count=$("$PSQL" -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM ext_tbl")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ $upd_rc -eq 0 && "$count" == "3" ]]; then
        _ok "$name"
    else
        _fail "$name: ALTER EXTENSION rc=$upd_rc count=$count"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: Multiple databases with TDE survive PPG→PSP upgrade
# ─────────────────────────────────────────────────────────────────────────────
scenario_multiple_databases() {
    local name="ppg_to_psp_multiple_databases"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old_data"
    local new_data="${workdir}/new_data"
    local keyfile="${workdir}/tde.per"
    local old_port=15504
    local new_port=15505

    rm -rf "$workdir"
    mkdir -p "$workdir"

    _make_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile" "key_postgres"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE pg_secrets (v INT) USING tde_heap;
         INSERT INTO pg_secrets VALUES (10);" >/dev/null

    "$PSQL_OLD" -p "$old_port" -d postgres -c "CREATE DATABASE db_alpha" >/dev/null
    "$PSQL_OLD" -p "$old_port" -d db_alpha -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile" "key_alpha"
    "$PSQL_OLD" -p "$old_port" -d db_alpha -c \
        "CREATE TABLE alpha_secrets (v INT) USING tde_heap;
         INSERT INTO alpha_secrets SELECT generate_series(1,20);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$new_port" "$INSTALL_DIR"
    if ! "${INSTALL_DIR}/bin/pg_upgrade" \
            -b "${OLD_INSTALL_DIR}/bin" -B "${INSTALL_DIR}/bin" \
            -d "$old_data" -D "$new_data" \
            -p "$old_port" -P "$new_port" >/dev/null 2>&1; then
        _fail "$name: pg_upgrade failed"
        return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local cnt_pg cnt_alpha
    cnt_pg=$("$PSQL"    -p "$new_port" -d postgres  -At -c "SELECT COUNT(*) FROM pg_secrets")
    cnt_alpha=$("$PSQL" -p "$new_port" -d db_alpha   -At -c "SELECT COUNT(*) FROM alpha_secrets")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_pg" == "1" && "$cnt_alpha" == "20" ]]; then
        _ok "$name"
    else
        _fail "$name: postgres=${cnt_pg} db_alpha=${cnt_alpha}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4: pg_upgrade --check passes with TDE configured
# ─────────────────────────────────────────────────────────────────────────────
scenario_check_mode() {
    local name="ppg_to_psp_check_mode"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old_data"
    local new_data="${workdir}/new_data"
    local keyfile="${workdir}/tde.per"
    local old_port=15506
    local new_port=15507

    rm -rf "$workdir"
    mkdir -p "$workdir"

    _make_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE check_tbl (id INT) USING tde_heap;
         INSERT INTO check_tbl VALUES (1),(2);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$new_port" "$INSTALL_DIR"
    if "${INSTALL_DIR}/bin/pg_upgrade" \
            -b "${OLD_INSTALL_DIR}/bin" -B "${INSTALL_DIR}/bin" \
            -d "$old_data" -D "$new_data" \
            -p "$old_port" -P "$new_port" \
            --check >/dev/null 2>&1; then
        _ok "$name"
    else
        _fail "$name: pg_upgrade --check failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
_require_binaries
mkdir -p "$RUN_DIR"

scenario_file_provider_data_intact
scenario_alter_extension_update
scenario_multiple_databases
scenario_check_mode

echo ""
echo "═══════════════════════════════════════════"
echo "  PPG→PSP upgrade tests complete"
echo "  PASS: $PASS   FAIL: $FAIL"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "  Failed scenarios:"
    for e in "${ERRORS[@]}"; do echo "    - $e"; done
fi
echo "═══════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
