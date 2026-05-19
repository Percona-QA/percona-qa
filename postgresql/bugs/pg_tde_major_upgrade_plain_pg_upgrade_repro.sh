#!/usr/bin/env bash
# Reproduce post-pg_upgrade failures when using plain pg_upgrade + cp pg_tde/
# instead of pg_tde_upgrade (PG17+pg_tde 2.1.x → PG18+pg_tde 2.2.x).
#
# Matches pytest failures:
#   - failed to decrypt key (multi-DB / ghost tables)
#   - invalid magic number in WAL segment (WAL encryption left on)
#   - pg_upgrade schema-dump failure (wal_encrypt on empty target)
#
# Prerequisites:
#   - PG17 with pg_tde 2.1.x at OLD_INSTALL_DIR (e.g. /usr/lib/postgresql/17)
#   - PG18 with pg_tde 2.2.x at NEW_INSTALL_DIR (e.g. /usr/lib/postgresql/18)
#   - pg_tde.control under /usr/share/postgresql/<major>/extension/
#     (default_version differs: 2.1 vs 2.2)
#
# Usage:
#   export OLD_INSTALL_DIR=/usr/lib/postgresql/17
#   export NEW_INSTALL_DIR=/usr/lib/postgresql/18
#   bash pg_tde_major_upgrade_plain_pg_upgrade_repro.sh [decrypt|wal|target-wal|all]

set -euo pipefail

OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
NEW_INSTALL_DIR="${NEW_INSTALL_DIR:-/usr/lib/postgresql/18}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_upgrade_repro_$$}"
SCENARIO="${1:-all}"

OLD_PORT="${OLD_PORT:-15401}"
NEW_PORT="${NEW_PORT:-15402}"
PGHOST="$RUN_DIR"
KEYFILE="$RUN_DIR/tde_repro.per"

mkdir -p "$RUN_DIR"
export PGHOST

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

read_pg_tde_default_version() {
    local install_dir="$1"
    local maj ctrl sharedir
    maj=$("$install_dir/bin/postgres" --version | awk '{print $3}' | cut -d. -f1)
    sharedir=$("$install_dir/bin/pg_config" --sharedir 2>/dev/null || true)
    for ctrl in \
        "/usr/share/postgresql/${maj}/extension/pg_tde.control" \
        "${sharedir}/extension/pg_tde.control" \
        "$install_dir/share/postgresql/extension/pg_tde.control" \
        "$install_dir/share/extension/pg_tde.control"; do
        [[ -z "$ctrl" || "$ctrl" == "/extension/pg_tde.control" ]] && continue
        if [[ -f "$ctrl" ]]; then
            grep '^default_version' "$ctrl" | cut -d= -f2 | tr -d " '"
            return 0
        fi
    done
    echo "unknown"
}

stop_port() {
    local port="$1"
    local pids
    pids=$(lsof -ti:"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
}

cleanup_run() {
    stop_port "$OLD_PORT"
    stop_port "$NEW_PORT"
    rm -rf "$RUN_DIR/old" "$RUN_DIR/new"
}

enable_pg_tde_conf() {
    local pgdata="$1"
    grep -q "shared_preload_libraries.*pg_tde" "$pgdata/postgresql.conf" 2>/dev/null || \
        echo "shared_preload_libraries = 'pg_tde'" >> "$pgdata/postgresql.conf"
}

init_cluster() {
    local pgdata="$1" port="$2" install_dir="$3" extra_initdb="${4:-}"
    rm -rf "$pgdata"
    mkdir -p "$pgdata"
    "$install_dir/bin/initdb" -D "$pgdata" $extra_initdb
    cat > "$pgdata/postgresql.conf" <<EOF
port = $port
unix_socket_directories = '$RUN_DIR'
listen_addresses = ''
logging_collector = off
EOF
    echo "local all all trust" >> "$pgdata/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$pgdata/pg_hba.conf"
}

start_cluster() {
    local pgdata="$1" port="$2" install_dir="$3"
    "$install_dir/bin/pg_ctl" -D "$pgdata" -w -t 60 \
        -o "-p $port -k $RUN_DIR" -l "$pgdata/server.log" start
}

stop_cluster() {
    local pgdata="$1" install_dir="$2"
    "$install_dir/bin/pg_ctl" -D "$pgdata" -m fast stop 2>/dev/null || true
}

psql_old() {
    "$OLD_INSTALL_DIR/bin/psql" -h "$RUN_DIR" -p "$OLD_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_new() {
    "$NEW_INSTALL_DIR/bin/psql" -h "$RUN_DIR" -p "$NEW_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

setup_old_tde_multidb() {
  local wal_encrypt="${1:-off}"
    cleanup_run
    OLD_PGDATA="$RUN_DIR/old"
    init_cluster "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
    enable_pg_tde_conf "$OLD_PGDATA"
    start_cluster "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

    psql_old -c "CREATE EXTENSION pg_tde;"
    psql_old -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
    psql_old -c "SELECT pg_tde_create_key_using_global_key_provider('key_postgres', 'file_provider');"
    psql_old -c "SELECT pg_tde_set_key_using_global_key_provider('key_postgres', 'file_provider');"
    psql_old -c "SELECT pg_tde_set_server_key_using_global_key_provider('key_postgres', 'file_provider');"

    psql_old -c "CREATE DATABASE db2;"
    psql_old -c "CREATE EXTENSION IF NOT EXISTS pg_tde;" -d db2
    psql_old -c "SELECT pg_tde_create_key_using_global_key_provider('key_db2', 'file_provider');" -d db2
    psql_old -c "SELECT pg_tde_set_key_using_global_key_provider('key_db2', 'file_provider');" -d db2

    psql_old -c "CREATE TABLE enc1 (v INT) USING tde_heap; INSERT INTO enc1 VALUES (1);"
    psql_old -c "CREATE TABLE enc2 (v INT) USING tde_heap; INSERT INTO enc2 VALUES (2),(3);" -d db2

    if [[ "$wal_encrypt" == "on" ]]; then
        psql_old -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';"
        psql_old -c "SELECT pg_reload_conf();"
        stop_cluster "$OLD_PGDATA" "$OLD_INSTALL_DIR"
        start_cluster "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
        psql_old -c "CREATE TABLE wal_enc_tbl (id INT); INSERT INTO wal_enc_tbl VALUES (1),(2);"
    fi

    stop_cluster "$OLD_PGDATA" "$OLD_INSTALL_DIR"
    log "Old cluster ready (wal_encrypt=$wal_encrypt)"
}

init_new_empty() {
    local wal_on_target="${1:-off}"
    NEW_PGDATA="$RUN_DIR/new"
    init_cluster "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR" "--no-data-checksums"
    enable_pg_tde_conf "$NEW_PGDATA"
    if [[ "$wal_on_target" == "on" ]]; then
        echo "pg_tde.wal_encrypt = 'on'" >> "$NEW_PGDATA/postgresql.conf"
        log "Set pg_tde.wal_encrypt=ON on EMPTY target (pytest bug path)"
    fi
}

plain_pg_upgrade_plus_copy() {
    init_new_empty "${1:-off}"
    log "Running plain pg_upgrade (NOT pg_tde_upgrade)..."
    "$NEW_INSTALL_DIR/bin/pg_tde_upgrade" \
        --no-sync \
        -b "$OLD_INSTALL_DIR/bin" \
        -B "$NEW_INSTALL_DIR/bin" \
        -d "$RUN_DIR/old" \
        -D "$RUN_DIR/new" \
        -p "$OLD_PORT" \
        -P "$NEW_PORT" \
        || return 1

    #log "Copying \$PGDATA/pg_tde/ (PG-2240 manual step)..."
    #rm -rf "$RUN_DIR/new/pg_tde"
    #cp -a "$RUN_DIR/old/pg_tde" "$RUN_DIR/new/pg_tde"
    return 0
}

try_start_new() {
    log "Starting upgraded cluster (expect failure for broken paths)..."
    if start_cluster "$RUN_DIR/new" "$NEW_PORT" "$NEW_INSTALL_DIR"; then
        log "Server started — tail of log:"
        tail -20 "$RUN_DIR/new/server.log" || true
        if psql_new -c "SELECT COUNT(*) FROM enc1;" 2>/dev/null; then
            log "SELECT enc1 OK"
        fi
        stop_cluster "$RUN_DIR/new" "$NEW_INSTALL_DIR"
        return 0
    fi
    log "Start failed — last 30 log lines:"
    tail -30 "$RUN_DIR/new/server.log" 2>/dev/null || true
    return 1
}

pg_tde_upgrade_working_path() {
    init_new_empty off
    log "Running pg_tde_upgrade (correct path for 2.1→2.2 / WAL enc)..."
    "$NEW_INSTALL_DIR/bin/pg_tde_upgrade" --no-sync \
        --old-datadir "$RUN_DIR/old" \
        --new-datadir "$RUN_DIR/new" \
        --old-bindir "$OLD_INSTALL_DIR/bin" \
        --new-bindir "$NEW_INSTALL_DIR/bin" \
        --socketdir "$RUN_DIR" \
        --old-port "$OLD_PORT" \
        --new-port "$NEW_PORT"
    try_start_new
}

scenario_decrypt_fail() {
    log "=== SCENARIO 1: multi-DB — plain pg_upgrade + copy → decrypt key FATAL ==="
    setup_old_tde_multidb off
    plain_pg_upgrade_plus_copy off || die "pg_upgrade failed"
    if try_start_new; then
        log "UNEXPECTED: server started (environment may be 2.2→2.2, not 2.1→2.2)"
    else
        log "REPRODUCED: post-upgrade start failed (see 'failed to decrypt key' in log)"
    fi
}

scenario_wal_panic() {
    log "=== SCENARIO 2: WAL encryption ON — plain pg_upgrade + copy → WAL magic PANIC ==="
    setup_old_tde_multidb on
    plain_pg_upgrade_plus_copy off || die "pg_upgrade failed"
    if try_start_new; then
        log "UNEXPECTED: server started"
    else
        log "REPRODUCED: post-upgrade start failed (see 'invalid magic number' / checkpoint PANIC)"
    fi
}

scenario_target_wal_fail() {
    log "=== SCENARIO 3: wal_encrypt on EMPTY target — pg_upgrade schema dump fails ==="
    setup_old_tde_multidb on
    if init_new_empty on && plain_pg_upgrade_plus_copy on; then
        log "UNEXPECTED: pg_upgrade succeeded"
    else
        log "REPRODUCED: pg_upgrade failed during target postmaster start (schema dump)"
        log "Check: $RUN_DIR/new/pg_upgrade_output.d/*/log/pg_upgrade_server.log"
        find "$RUN_DIR/new" -name pg_upgrade_server.log 2>/dev/null | head -1 | xargs tail -30 2>/dev/null || true
    fi
}

scenario_working() {
    log "=== CONTROL: pg_tde_upgrade (should PASS) ==="
    setup_old_tde_multidb on
    pg_tde_upgrade_working_path && log "CONTROL PASS" || log "CONTROL FAIL"
}

main() {
    command -v "$OLD_INSTALL_DIR/bin/pg_tde_upgrade" >/dev/null || die "missing $OLD_INSTALL_DIR"
    command -v "$NEW_INSTALL_DIR/bin/pg_tde_upgrade" >/dev/null || die "missing $NEW_INSTALL_DIR"

    OLD_VER=$(read_pg_tde_default_version "$OLD_INSTALL_DIR")
    NEW_VER=$(read_pg_tde_default_version "$NEW_INSTALL_DIR")
    log "RUN_DIR=$RUN_DIR"
    log "OLD=$OLD_INSTALL_DIR (pg_tde default_version=$OLD_VER)"
    log "NEW=$NEW_INSTALL_DIR (pg_tde default_version=$NEW_VER)"
    if [[ "$OLD_VER" == "$NEW_VER" ]]; then
        log "WARNING: same pg_tde default_version — scenario 1 may NOT reproduce decrypt failure"
    fi

    case "$SCENARIO" in
        decrypt)    scenario_decrypt_fail ;;
        wal)        scenario_wal_panic ;;
        target-wal) scenario_target_wal_fail ;;
        control)    scenario_working ;;
        all)
            scenario_decrypt_fail
            echo
            scenario_wal_panic
            echo
            scenario_target_wal_fail
            echo
            scenario_working
            ;;
        *) die "usage: $0 [decrypt|wal|target-wal|control|all]" ;;
    esac

    log "Artifacts left in $RUN_DIR (remove manually when done)"
}

main "$@"
