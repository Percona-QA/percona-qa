#!/usr/bin/env bash
# Reproduce / verify: dropped-and-recreated tde_heap table after major upgrade
# (pytest: TestTdeUpgradeExtremeCornerCases.test_upgrade_dropped_and_recreated_tables)
#
# What you are testing
# --------------------
# On the OLD cluster:
#   CREATE ghost_t → INSERT 1 → DROP → CREATE ghost_t → INSERT 2 → VACUUM FULL
#
# After PG17+pg_tde 2.1.x → PG18+pg_tde 2.2.x upgrade, SELECT id FROM ghost_t must be 2.
# If it is 1 (or errors), that is a real relfilenode / smgr-key mapping bug in pg_tde.
#
# What is NOT a ghost bug
# -----------------------
# FATAL: failed to decrypt key, incorrect principal key or corrupted key file
# right after upgrade when you used plain pg_upgrade + cp pg_tde/ (no pg_tde_upgrade,
# no ALTER EXTENSION pg_tde UPDATE). That is wrong procedure / harness mistake.
#
# Prerequisites
# -------------
#   OLD_INSTALL_DIR=/usr/lib/postgresql/17   (pg_tde control default_version 2.1)
#   NEW_INSTALL_DIR=/usr/lib/postgresql/18   (pg_tde control default_version 2.2)
#
# Usage
# -----
#   export OLD_INSTALL_DIR=/usr/lib/postgresql/17
#   export NEW_INSTALL_DIR=/usr/lib/postgresql/18
#   bash postgresql/bugs/pg_tde_ghost_relfilenode_upgrade_repro.sh [wrong|correct|all|print]
#
#   wrong   — plain pg_upgrade + copy pg_tde/ (expect decrypt FATAL; NOT a product bug)
#   correct — pg_tde_upgrade + start + ALTER EXTENSION (expect id=2; if not → product bug)
#   all     — run wrong then correct (separate RUN_DIR suffixes)
#   print   — echo manual step-by-step commands only

set -euo pipefail

OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-/usr/lib/postgresql/17}"
NEW_INSTALL_DIR="${NEW_INSTALL_DIR:-/usr/lib/postgresql/18}"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_ghost_repro_$$}"
SCENARIO="${1:-all}"

OLD_PORT="${OLD_PORT:-15501}"
NEW_PORT="${NEW_PORT:-15502}"
IO_METHOD="${IO_METHOD:-worker}"

OLD_BIN="$OLD_INSTALL_DIR/bin"
NEW_BIN="$NEW_INSTALL_DIR/bin"
mkdir -p "$RUN_DIR"
export PGHOST="$RUN_DIR"

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

pg_major() {
    "$1/bin/postgres" --version | awk '{print $3}' | cut -d. -f1
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

cleanup_dirs() {
    local base="$1"
    stop_port "$OLD_PORT"
    stop_port "$NEW_PORT"
    rm -rf "${base}/old" "${base}/new"
}

init_cluster() {
    local pgdata="$1" port="$2" bindir="$3" extra_initdb="${4:-}"
    rm -rf "$pgdata"
    mkdir -p "$pgdata"
    "$bindir/initdb" -D "$pgdata" --no-data-checksums $extra_initdb
    cat > "$pgdata/postgresql.conf" <<EOF
port = $port
unix_socket_directories = '$RUN_DIR'
listen_addresses = ''
logging_collector = off
shared_preload_libraries = 'pg_tde'
wal_level = replica
include_if_exists = 'postgresql.auto.conf'
EOF
    echo "local all all trust" >> "$pgdata/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$pgdata/pg_hba.conf"
}

# Empty target for pg_upgrade (matches pytest write_pg_upgrade_target_config)
init_upgrade_target() {
    local pgdata="$1" port="$2" bindir="$3"
    local old_ver new_ver preload=""
    old_ver=$(read_pg_tde_default_version "$OLD_INSTALL_DIR")
    new_ver=$(read_pg_tde_default_version "$NEW_INSTALL_DIR")
    if [[ "$old_ver" == "$new_ver" || "$old_ver" == "unknown" || "$new_ver" == "unknown" ]]; then
        preload=$'shared_preload_libraries = \'pg_tde\'\n'
    fi
    rm -rf "$pgdata"
    mkdir -p "$pgdata"
    "$bindir/initdb" -D "$pgdata" --no-data-checksums
    cat > "$pgdata/postgresql.conf" <<EOF
port = $port
unix_socket_directories = '$RUN_DIR'
${preload}include_if_exists = 'postgresql.auto.conf'
EOF
}

finalize_new_conf() {
    local pgdata="$1" port="$2"
    local new_maj
    new_maj=$(pg_major "$NEW_INSTALL_DIR")
    cat > "$pgdata/postgresql.conf" <<EOF
port = $port
unix_socket_directories = '$RUN_DIR'
listen_addresses = ''
logging_collector = off
shared_preload_libraries = 'pg_tde'
wal_level = replica
include_if_exists = 'postgresql.auto.conf'
EOF
    if [[ "$new_maj" -ge 18 ]]; then
        echo "io_method = '$IO_METHOD'" >> "$pgdata/postgresql.conf"
    fi
    grep -q "local all all trust" "$pgdata/pg_hba.conf" 2>/dev/null || \
        echo "local all all trust" >> "$pgdata/pg_hba.conf"
    grep -q "host all all 127.0.0.1/32 trust" "$pgdata/pg_hba.conf" 2>/dev/null || \
        echo "host all all 127.0.0.1/32 trust" >> "$pgdata/pg_hba.conf"
}

start_cluster() {
    local pgdata="$1" port="$2" bindir="$3"
    "$bindir/pg_ctl" -D "$pgdata" -w -t 90 \
        -o "-p $port -k $RUN_DIR" -l "$pgdata/server.log" start
}

stop_cluster() {
    local pgdata="$1" bindir="$2"
    "$bindir/pg_ctl" -D "$pgdata" -m fast stop 2>/dev/null || true
}

psql_old() {
    "$OLD_BIN/psql" -h "$RUN_DIR" -p "$OLD_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_new() {
    "$NEW_BIN/psql" -h "$RUN_DIR" -p "$NEW_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

setup_ghost_on_old() {
    local base="$1"
    KEYFILE="$base/ghost_upgrade.per"
    OLD_PGDATA="$base/old"
    cleanup_dirs "$base"
    init_cluster "$OLD_PGDATA" "$OLD_PORT" "$OLD_BIN"
    start_cluster "$OLD_PGDATA" "$OLD_PORT" "$OLD_BIN"

    rm -f "$KEYFILE"
    psql_old -c "CREATE EXTENSION pg_tde;"
    psql_old -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
    psql_old -c "SELECT pg_tde_create_key_using_global_key_provider('test_key', 'file_provider');"
    psql_old -c "SELECT pg_tde_set_server_key_using_global_key_provider('test_key', 'file_provider');"
    psql_old -c "SELECT pg_tde_set_key_using_global_key_provider('test_key', 'file_provider');"

    psql_old -c "CREATE TABLE ghost_t (id INT) USING tde_heap;"
    psql_old -c "INSERT INTO ghost_t VALUES (1);"
    psql_old -c "DROP TABLE ghost_t;"
    psql_old -c "CREATE TABLE ghost_t (id INT) USING tde_heap;"
    psql_old -c "INSERT INTO ghost_t VALUES (2);"
    psql_old -c "VACUUM FULL;"

    log "OLD cluster: ghost_t should have id=2 before upgrade"
    psql_old -c "SELECT 'pre-upgrade' AS phase, id FROM ghost_t;"
    psql_old -c "SELECT relname, relfilenode FROM pg_class WHERE relname = 'ghost_t';"

    stop_cluster "$OLD_PGDATA" "$OLD_BIN"
    log "OLD cluster stopped at $OLD_PGDATA"
}

run_plain_pg_upgrade_plus_copy() {
    local base="$1"
    NEW_PGDATA="$base/new"
    init_upgrade_target "$NEW_PGDATA" "$NEW_PORT" "$NEW_BIN"

    log "Running plain pg_upgrade (NOT pg_tde_upgrade)..."
    "$NEW_BIN/pg_upgrade" --no-sync \
        -b "$OLD_BIN" \
        -B "$NEW_BIN" \
        -d "$base/old" \
        -D "$NEW_PGDATA" \
        -p "$OLD_PORT" \
        -P "$NEW_PORT"

    if [[ -d "$base/old/pg_tde" && ! -d "$NEW_PGDATA/pg_tde" ]]; then
        log "Copying pg_tde/ (manual PG-2240 step — breaks 2.1→2.2 decrypt)"
        cp -a "$base/old/pg_tde" "$NEW_PGDATA/pg_tde"
    fi
    finalize_new_conf "$NEW_PGDATA" "$NEW_PORT"
}

run_pg_tde_upgrade() {
    local base="$1"
    NEW_PGDATA="$base/new"
    init_upgrade_target "$NEW_PGDATA" "$NEW_PORT" "$NEW_BIN"

    if [[ ! -x "$NEW_BIN/pg_tde_upgrade" ]]; then
        die "missing $NEW_BIN/pg_tde_upgrade (required for pg_tde 2.1→2.2)"
    fi

    log "Running pg_tde_upgrade..."
    if "$NEW_BIN/pg_tde_upgrade" --help 2>&1 | grep -q old-datadir; then
        "$NEW_BIN/pg_tde_upgrade" --no-sync \
            --old-datadir "$base/old" \
            --new-datadir "$NEW_PGDATA" \
            --old-bindir "$OLD_BIN" \
            --new-bindir "$NEW_BIN" \
            --socketdir "$RUN_DIR" \
            --old-port "$OLD_PORT" \
            --new-port "$NEW_PORT"
    else
        "$NEW_BIN/pg_tde_upgrade" --no-sync \
            -b "$OLD_BIN" \
            -B "$NEW_BIN" \
            -d "$base/old" \
            -D "$NEW_PGDATA" \
            -p "$OLD_PORT" \
            -P "$NEW_PORT"
    fi
    finalize_new_conf "$NEW_PGDATA" "$NEW_PORT"
}

try_start_and_query() {
    local base="$1" label="$2"
    NEW_PGDATA="$base/new"

    log "Starting NEW cluster ($label)..."
    if ! start_cluster "$NEW_PGDATA" "$NEW_PORT" "$NEW_BIN"; then
        log "START FAILED — last 25 lines of server.log:"
        tail -25 "$NEW_PGDATA/server.log" 2>/dev/null || true
        return 1
    fi

    if ! psql_new -c "SELECT 1 FROM pg_extension WHERE extname='pg_tde';" | grep -q 1; then
        log "pg_tde extension missing on new cluster"
        stop_cluster "$NEW_PGDATA" "$NEW_BIN"
        return 1
    fi

    log "ALTER EXTENSION pg_tde UPDATE (2.1→2.2 migration scripts)..."
    psql_new -c "ALTER EXTENSION pg_tde UPDATE;" || {
        log "ALTER EXTENSION failed (may be no-op if already 2.2)"
    }

    psql_new -c "SELECT extname, extversion FROM pg_extension WHERE extname='pg_tde';"
    psql_new -c "SELECT relname, relfilenode FROM pg_class WHERE relname = 'ghost_t';"

    local val
    val=$(psql_new -t -A -c "SELECT id FROM ghost_t;" 2>/dev/null | tr -d '[:space:]')
    log "SELECT id FROM ghost_t => '$val' (expect 2)"

    stop_cluster "$NEW_PGDATA" "$NEW_BIN"

    if [[ "$val" == "2" ]]; then
        log "PASS ($label): correct row (ghost relfilenode mapping OK)"
        return 0
    fi
    log "FAIL ($label): expected id=2, got '$val' — possible pg_tde relfilenode bug"
    return 2
}

scenario_wrong() {
    local base="${RUN_DIR}/wrong"
    mkdir -p "$base"
    export RUN_DIR
    # shellcheck disable=SC2034
    RUN_DIR="$base"
    export PGHOST="$RUN_DIR"
    OLD_PORT=$((OLD_PORT + 100))
    NEW_PORT=$((NEW_PORT + 100))

    log "======== SCENARIO: wrong (plain pg_upgrade + copy) ========"
    setup_ghost_on_old "$base"
    run_plain_pg_upgrade_plus_copy "$base"

    if try_start_and_query "$base" "wrong-path"; then
        log "UNEXPECTED: wrong path succeeded (maybe 2.2→2.2 only — check pg_tde.control versions)"
    else
        if grep -q "failed to decrypt key" "$base/new/server.log" 2>/dev/null; then
            log "VERDICT (wrong path): decrypt FATAL — procedure bug / expected for 2.1→2.2, NOT ghost relfilenode"
        else
            log "VERDICT (wrong path): start or query failed — see server.log"
        fi
    fi
}

scenario_correct() {
    local base="${RUN_DIR}/correct"
    mkdir -p "$base"
    export RUN_DIR
    # shellcheck disable=SC2034
    RUN_DIR="$base"
    export PGHOST="$RUN_DIR"
    OLD_PORT=$((OLD_PORT + 200))
    NEW_PORT=$((NEW_PORT + 200))

    log "======== SCENARIO: correct (pg_tde_upgrade + ALTER EXTENSION) ========"
    setup_ghost_on_old "$base"
    run_pg_tde_upgrade "$base"

    if try_start_and_query "$base" "correct-path"; then
        log "VERDICT (correct path): PASS — no ghost relfilenode bug observed"
    else
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            log "VERDICT (correct path): FAIL — report to pg_tde (relfilenode / smgr key mapping)"
        else
            log "VERDICT (correct path): upgrade or start failed — check pg_upgrade logs under $base/new/"
            find "$base/new" -name 'pg_upgrade*.log' 2>/dev/null | head -3
        fi
        return "$rc"
    fi
}

print_manual() {
    cat <<'MANUAL'
# ── Manual reproduction (copy/paste on Ubuntu host) ─────────────────────────
export OLD=/usr/lib/postgresql/17
export NEW=/usr/lib/postgresql/18
export RUN=/tmp/ghost_manual_$$
export PGHOST=$RUN
export OLD_PORT=15511 NEW_PORT=15512
export KEY=$RUN/ghost.per
mkdir -p $RUN

# 1) Old cluster + ghost table
$OLD/bin/initdb -D $RUN/old --no-data-checksums
cat >> $RUN/old/postgresql.conf <<EOF
port = $OLD_PORT
unix_socket_directories = '$RUN'
shared_preload_libraries = 'pg_tde'
wal_level = replica
EOF
echo "local all all trust" >> $RUN/old/pg_hba.conf
$OLD/bin/pg_ctl -D $RUN/old -w -o "-p $OLD_PORT -k $RUN" -l $RUN/old.log start

$OLD/bin/psql -h $RUN -p $OLD_PORT -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEY');
SELECT pg_tde_create_key_using_global_key_provider('test_key', 'file_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('test_key', 'file_provider');
SELECT pg_tde_set_key_using_global_key_provider('test_key', 'file_provider');
CREATE TABLE ghost_t (id INT) USING tde_heap;
INSERT INTO ghost_t VALUES (1);
DROP TABLE ghost_t;
CREATE TABLE ghost_t (id INT) USING tde_heap;
INSERT INTO ghost_t VALUES (2);
VACUUM FULL;
SELECT id FROM ghost_t;
SQL
$OLD/bin/pg_ctl -D $RUN/old -m fast stop

# 2) Empty new cluster (minimal conf for upgrade; NO pg_tde preload on 2.1→2.2)
$NEW/bin/initdb -D $RUN/new --no-data-checksums
cat > $RUN/new/postgresql.conf <<EOF
port = $NEW_PORT
unix_socket_directories = '$RUN'
EOF
# shared_preload_libraries = 'pg_tde' only when pg_tde.control versions match (2.2→2.2)

# 3a) WRONG (expect decrypt FATAL at start) — for comparison only:
# $NEW/bin/pg_upgrade --no-sync -b $OLD/bin -B $NEW/bin -d $RUN/old -D $RUN/new -p $OLD_PORT -P $NEW_PORT
# cp -a $RUN/old/pg_tde $RUN/new/
# $NEW/bin/pg_ctl -D $RUN/new -w -o "-p $NEW_PORT -k $RUN" -l $RUN/new_wrong.log start
# tail $RUN/new_wrong.log   # → failed to decrypt key

# 3b) CORRECT (use pg_tde_upgrade when 2.1→2.2):
$NEW/bin/pg_tde_upgrade --no-sync \
  -b $OLD/bin -B $NEW/bin -d $RUN/old -D $RUN/new -p $OLD_PORT -P $NEW_PORT
# Or long options if your build requires: --old-datadir $RUN/old --new-datadir $RUN/new ...

# 4) Start + migrate extension + verify
echo "shared_preload_libraries = 'pg_tde'" >> $RUN/new/postgresql.conf
echo "local all all trust" >> $RUN/new/pg_hba.conf
$NEW/bin/pg_ctl -D $RUN/new -w -o "-p $NEW_PORT -k $RUN" -l $RUN/new.log start
$NEW/bin/psql -h $RUN -p $NEW_PORT -d postgres -c "ALTER EXTENSION pg_tde UPDATE;"
$NEW/bin/psql -h $RUN -p $NEW_PORT -d postgres -c "SELECT id FROM ghost_t;"
# Expected: id = 2.  If id = 1 → file pg_tde bug (ghost relfilenode).

$NEW/bin/pg_ctl -D $RUN/new -m fast stop
MANUAL
}

main() {
    command -v "$OLD_BIN/postgres" >/dev/null || die "missing $OLD_BIN"
    command -v "$NEW_BIN/postgres" >/dev/null || die "missing $NEW_BIN"

    OLD_VER=$(read_pg_tde_default_version "$OLD_INSTALL_DIR")
    NEW_VER=$(read_pg_tde_default_version "$NEW_INSTALL_DIR")
    log "OLD=$OLD_INSTALL_DIR pg_tde=$OLD_VER  NEW=$NEW_INSTALL_DIR pg_tde=$NEW_VER"
    log "RUN_DIR=$RUN_DIR  scenario=$SCENARIO"

    case "$SCENARIO" in
        wrong)   scenario_wrong ;;
        correct) scenario_correct ;;
        all)
            scenario_wrong || true
            echo
            scenario_correct
            ;;
        print)   print_manual ;;
        *)
            die "usage: $0 [wrong|correct|all|print]"
            ;;
    esac

    log "Artifacts under ${RUN_DIR}/wrong and ${RUN_DIR}/correct (if all/wrong/correct ran)"
}

main "$@"
