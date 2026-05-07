#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pg_tde_upgrade_wal_encryption.sh
#
# Four WAL encryption on/off paths across a major-version pg_upgrade.
#
# Paths tested
# ────────────
#  1. WAL enc off → off   Baseline: encryption disabled throughout.
#  2. WAL enc on  → off   Enable in old, disable before pg_upgrade, verify off in new.
#  3. WAL enc on  → re-enable  Upgrade with WAL enc off, re-enable on new cluster.
#  4. --check with WAL enc on  pg_upgrade --check must pass with encrypted WAL active.
#
# USAGE
#   INSTALL_DIR=/usr/lib/postgresql/18 \
#   OLD_INSTALL_DIR=/usr/lib/postgresql/17 \
#   bash pg_tde_upgrade_wal_encryption.sh
#
# ENV VARS
#   INSTALL_DIR       New PostgreSQL install.  Default: /usr/lib/postgresql/18
#   OLD_INSTALL_DIR   Old PostgreSQL install.  Default: /usr/lib/postgresql/17
#   RUN_DIR           Working directory.        Default: /tmp/pg_tde_wal_enc_upgrade
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/lib/postgresql/18}"
OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_wal_enc_upgrade}"

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
    rm -rf "$data_dir"
    "${install}/bin/initdb" -D "$data_dir" --no-data-checksums -U "$(whoami)" >/dev/null
    echo "shared_preload_libraries = 'pg_tde'" >> "$data_dir/postgresql.conf"
    echo "host all all 127.0.0.1/32 trust"    >> "$data_dir/pg_hba.conf"
    echo "local all all trust"                  >> "$data_dir/pg_hba.conf"
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

_restart_cluster() {
    local data_dir="$1" port="$2" install="$3"
    _stop_cluster "$data_dir" "$install"
    sleep 1
    _start_cluster "$data_dir" "$port" "$install"
}

_setup_tde() {
    local port="$1" psql_bin="$2" keyfile="$3" key="${4:-test_key}"
    "$psql_bin" -p "$port" -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_tde" >/dev/null

    local add_fn
    add_fn=$("$psql_bin" -p "$port" -d postgres -At \
        -c "SELECT proname FROM pg_proc WHERE proname='pg_tde_add_global_key_provider_file' LIMIT 1")
    [[ -n "$add_fn" ]] || add_fn="pg_tde_add_key_provider_file"
    "$psql_bin" -p "$port" -d postgres \
        -c "SELECT ${add_fn}('file_provider','${keyfile}')" >/dev/null

    if "$psql_bin" -p "$port" -d postgres -At \
            -c "SELECT 1 FROM pg_proc WHERE proname='pg_tde_create_key_using_global_key_provider' LIMIT 1" \
            2>/dev/null | grep -q 1; then
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_create_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_set_server_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT pg_tde_set_key_using_global_key_provider('${key}','file_provider')" >/dev/null 2>&1 || true
    else
        local set_fn
        set_fn=$("$psql_bin" -p "$port" -d postgres -At \
            -c "SELECT proname FROM pg_proc WHERE proname LIKE 'pg_tde_set%principal_key' LIMIT 1")
        [[ -n "$set_fn" ]] || set_fn="pg_tde_set_principal_key"
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT ${set_fn}('${key}','file_provider')" >/dev/null 2>&1 || \
        "$psql_bin" -p "$port" -d postgres \
            -c "SELECT ${set_fn}('${key}')" >/dev/null
    fi
}

_enable_wal_enc() {
    local data_dir="$1" port="$2" psql_bin="$3" install="$4"
    "$psql_bin" -p "$port" -d postgres \
        -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on'" >/dev/null
    _restart_cluster "$data_dir" "$port" "$install"
}

_disable_wal_enc() {
    local data_dir="$1" port="$2" psql_bin="$3" install="$4"
    "$psql_bin" -p "$port" -d postgres \
        -c "ALTER SYSTEM RESET pg_tde.wal_encrypt" >/dev/null
    _restart_cluster "$data_dir" "$port" "$install"
}

_is_wal_enc_on() {
    local port="$1" psql_bin="$2"
    local val
    val=$("$psql_bin" -p "$port" -d postgres -At -c "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "off")
    [[ "$val" == "on" ]]
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
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: WAL enc off → off (baseline)
# ─────────────────────────────────────────────────────────────────────────────
scenario_wal_enc_off_to_off() {
    local name="wal_enc_off_to_off"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15530
    local new_port=15531

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE wal_off (id INT) USING tde_heap;
         INSERT INTO wal_off SELECT generate_series(1,50);" >/dev/null
    # Confirm WAL enc is off
    if _is_wal_enc_on "$old_port" "$PSQL_OLD"; then
        _fail "$name: expected WAL enc off before upgrade"; return
    fi
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count wal_state
    count=$("$PSQL"     -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM wal_off")
    wal_state=$("$PSQL" -p "$new_port" -d postgres -At -c "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "off")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "50" && "$wal_state" == "off" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} wal_encrypt=${wal_state}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: WAL enc on → off (disable before pg_upgrade)
# ─────────────────────────────────────────────────────────────────────────────
scenario_wal_enc_on_to_off() {
    local name="wal_enc_on_to_off"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15532
    local new_port=15533

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    _enable_wal_enc "$old_data" "$old_port" "$PSQL_OLD" "$OLD_INSTALL_DIR"

    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE wal_on_data (id INT) USING tde_heap;
         INSERT INTO wal_on_data SELECT generate_series(1,80);" >/dev/null

    # Disable WAL enc before pg_upgrade — pg_upgrade cannot handle encrypted WAL
    _disable_wal_enc "$old_data" "$old_port" "$PSQL_OLD" "$OLD_INSTALL_DIR"
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    local count wal_state
    count=$("$PSQL"     -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM wal_on_data")
    wal_state=$("$PSQL" -p "$new_port" -d postgres -At -c "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "off")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$count" == "80" && "$wal_state" == "off" ]]; then
        _ok "$name"
    else
        _fail "$name: count=${count} wal_encrypt=${wal_state}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: WAL enc on → disable for upgrade → re-enable on new cluster
# ─────────────────────────────────────────────────────────────────────────────
scenario_wal_enc_on_to_reenable() {
    local name="wal_enc_on_to_reenable"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15534
    local new_port=15535

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    _enable_wal_enc "$old_data" "$old_port" "$PSQL_OLD" "$OLD_INSTALL_DIR"

    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE pre_enc (id INT) USING tde_heap;
         INSERT INTO pre_enc VALUES (1),(2),(3);" >/dev/null

    _disable_wal_enc "$old_data" "$old_port" "$PSQL_OLD" "$OLD_INSTALL_DIR"
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if ! _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port"; then
        _fail "$name: pg_upgrade failed"; return
    fi

    _copy_pg_tde_dir "$old_data" "$new_data"
    _start_cluster "$new_data" "$new_port" "$INSTALL_DIR"

    # Re-enable WAL encryption on the upgraded cluster
    _enable_wal_enc "$new_data" "$new_port" "$PSQL" "$INSTALL_DIR"

    "$PSQL" -p "$new_port" -d postgres -c \
        "CREATE TABLE post_enc (id INT) USING tde_heap;
         INSERT INTO post_enc SELECT generate_series(1,10);" >/dev/null

    local cnt_pre cnt_post wal_state
    cnt_pre=$("$PSQL"   -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM pre_enc")
    cnt_post=$("$PSQL"  -p "$new_port" -d postgres -At -c "SELECT COUNT(*) FROM post_enc")
    wal_state=$("$PSQL" -p "$new_port" -d postgres -At -c "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "off")
    _stop_cluster "$new_data" "$INSTALL_DIR"

    if [[ "$cnt_pre" == "3" && "$cnt_post" == "10" && "$wal_state" == "on" ]]; then
        _ok "$name"
    else
        _fail "$name: pre=${cnt_pre} post=${cnt_post} wal_encrypt=${wal_state}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4: pg_upgrade --check with WAL encryption on
# ─────────────────────────────────────────────────────────────────────────────
scenario_check_mode_with_wal_enc_on() {
    local name="wal_enc_check_mode_with_enc_on"
    _info "=== $name ==="

    local workdir="${RUN_DIR}/${name}"
    local old_data="${workdir}/old"
    local new_data="${workdir}/new"
    local keyfile="${workdir}/tde.per"
    local old_port=15536
    local new_port=15537

    rm -rf "$workdir"; mkdir -p "$workdir"

    _make_cluster "$old_data" "$OLD_INSTALL_DIR"
    _start_cluster "$old_data" "$old_port" "$OLD_INSTALL_DIR"
    _setup_tde "$old_port" "$PSQL_OLD" "$keyfile"
    _enable_wal_enc "$old_data" "$old_port" "$PSQL_OLD" "$OLD_INSTALL_DIR"

    "$PSQL_OLD" -p "$old_port" -d postgres -c \
        "CREATE TABLE wal_check_tbl (id INT) USING tde_heap;
         INSERT INTO wal_check_tbl VALUES (1);" >/dev/null
    _stop_cluster "$old_data" "$OLD_INSTALL_DIR"

    _make_cluster "$new_data" "$INSTALL_DIR"
    if _pg_upgrade "$old_data" "$new_data" "$old_port" "$new_port" "--check"; then
        _ok "$name"
    else
        _fail "$name: pg_upgrade --check failed with WAL enc on"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
[[ -x "${OLD_INSTALL_DIR}/bin/postgres" ]] || _die "OLD_INSTALL_DIR not valid: $OLD_INSTALL_DIR"
[[ -x "${INSTALL_DIR}/bin/pg_upgrade"   ]] || _die "pg_upgrade not found: ${INSTALL_DIR}/bin/pg_upgrade"
mkdir -p "$RUN_DIR"

scenario_wal_enc_off_to_off
scenario_wal_enc_on_to_off
scenario_wal_enc_on_to_reenable
scenario_check_mode_with_wal_enc_on

echo ""
echo "═══════════════════════════════════════════"
echo "  WAL encryption upgrade tests complete"
echo "  PASS: $PASS   FAIL: $FAIL"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do echo "  FAIL: $e"; done
fi
echo "═══════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
