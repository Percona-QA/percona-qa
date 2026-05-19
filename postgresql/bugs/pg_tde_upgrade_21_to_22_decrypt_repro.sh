#!/usr/bin/env bash
# Reproduce: pg_tde_upgrade PG17+pg_tde 2.1.x → PG18+pg_tde 2.2.x fails during
# pg_upgrade when the empty target has shared_preload_libraries=pg_tde.
#
# Root cause (pg_tde_upgrade.c): copy_pg_tde(old, new) runs BEFORE pg_upgrade.
# pg_upgrade then starts the PG18 postmaster; pg_tde 2.2 loads 2.1 key files
# from $PGDATA/pg_tde and exits with:
#   FATAL: failed to decrypt key, incorrect principal key or corrupted key file
#
# This is NOT a ghost-relfilenode / relfilenode bug — upgrade never completes.
#
# Usage:
#   export OLD=/usr/lib/postgresql/17 NEW=/usr/lib/postgresql/18
#   bash postgresql/bugs/pg_tde_upgrade_21_to_22_decrypt_repro.sh
#
# Report: see postgresql/bugs/PG_tde_upgrade_21_22_report.md

set -euo pipefail

OLD="${OLD:-/usr/lib/postgresql/17}"
NEW="${NEW:-/usr/lib/postgresql/18}"
RUN="${RUN:-/tmp/pg_tde_upgrade_21_22_repro}"
OLD_PORT="${OLD_PORT:-15521}"
NEW_PORT="${NEW_PORT:-15522}"
KEY="${KEY:-$RUN/ghost.per}"

export PGHOST="$RUN"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

read_pg_tde_ver() {
    local maj=$("$1/bin/postgres" --version | awk '{print $3}' | cut -d. -f1)
    local ctrl="/usr/share/postgresql/${maj}/extension/pg_tde.control"
    [[ -f "$ctrl" ]] && grep '^default_version' "$ctrl" | cut -d= -f2 | tr -d " '" || echo "?"
}

cleanup() {
    log "Cleaning $RUN (stop servers, remove datadirs)"
    "$OLD/bin/pg_ctl" -D "$RUN/old" -m fast stop 2>/dev/null || true
    "$NEW/bin/pg_ctl" -D "$RUN/new" -m fast stop 2>/dev/null || true
    lsof -ti:"$OLD_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    lsof -ti:"$NEW_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    rm -rf "$RUN"
}

trap 'log "FAILED — logs: $RUN/new/server.log and pg_upgrade_output.d under $RUN/new"' ERR

command -v "$OLD/bin/initdb" >/dev/null || die "missing $OLD"
command -v "$NEW/bin/pg_tde_upgrade" >/dev/null || die "missing $NEW/bin/pg_tde_upgrade"

OLD_TDE=$(read_pg_tde_ver "$OLD")
NEW_TDE=$(read_pg_tde_ver "$NEW")
log "OLD=$OLD (pg_tde $OLD_TDE)  NEW=$NEW (pg_tde $NEW_TDE)  RUN=$RUN"

cleanup
mkdir -p "$RUN"
rm -f "$KEY"

# ── Old cluster (PG17 + pg_tde 2.1) ─────────────────────────────────────────
log "initdb old cluster"
"$OLD/bin/initdb" -D "$RUN/old" --no-data-checksums
cat >> "$RUN/old/postgresql.conf" <<EOF
port = $OLD_PORT
unix_socket_directories = '$RUN'
listen_addresses = ''
shared_preload_libraries = 'pg_tde'
wal_level = replica
logging_collector = off
EOF
echo "local all all trust" >> "$RUN/old/pg_hba.conf"

log "populate old cluster (ghost_t scenario)"
"$OLD/bin/pg_ctl" -D "$RUN/old" -w -t 60 -o "-p $OLD_PORT -k $RUN" -l "$RUN/old.log" start
"$OLD/bin/psql" -h "$RUN" -p "$OLD_PORT" -d postgres -v ON_ERROR_STOP=1 <<SQL
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
SELECT 'pre-upgrade id=' || id::text FROM ghost_t;
SQL
"$OLD/bin/pg_ctl" -D "$RUN/old" -m fast stop
log "old/pg_tde exists: $(test -d "$RUN/old/pg_tde" && echo yes || echo no)"

# ── New empty cluster (PG18) — typical doc/bash: preload pg_tde before upgrade ─
log "initdb new cluster (empty target, shared_preload_libraries=pg_tde)"
"$NEW/bin/initdb" -D "$RUN/new" --no-data-checksums
cat > "$RUN/new/postgresql.conf" <<EOF
port = $NEW_PORT
unix_socket_directories = '$RUN'
listen_addresses = ''
shared_preload_libraries = 'pg_tde'
logging_collector = off
include_if_exists = 'postgresql.auto.conf'
EOF
echo "local all all trust" >> "$RUN/new/pg_hba.conf"

log "pg_tde_upgrade (copies old/pg_tde → new/pg_tde, then runs pg_upgrade)"
log "new/pg_tde before upgrade: $(test -d "$RUN/new/pg_tde" && echo yes || echo no)"
set +e
"$NEW/bin/pg_tde_upgrade" --no-sync \
    -b "$OLD/bin" -B "$NEW/bin" \
    -d "$RUN/old" -D "$RUN/new" \
    -p "$OLD_PORT" -P "$NEW_PORT"
rc=$?
set -e
log "new/pg_tde after pg_tde_upgrade wrapper started: $(test -d "$RUN/new/pg_tde" && echo yes || echo no)"

if [[ $rc -eq 0 ]]; then
    log "UNEXPECTED: pg_tde_upgrade succeeded (environment may be 2.2→2.2 only)"
    exit 0
fi

log "pg_tde_upgrade failed (expected for 2.1→2.2 with preload on target), rc=$rc"
log "--- pg_upgrade_server.log (last 30 lines) ---"
find "$RUN/new/pg_upgrade_output.d" -name pg_upgrade_server.log 2>/dev/null | head -1 \
    | xargs tail -30 2>/dev/null || true

if grep -rq "failed to decrypt key" "$RUN/new/pg_upgrade_output.d" 2>/dev/null; then
    log ""
    log "VERDICT: REPRODUCED — pg_tde 2.1 key material on new PG18 + pg_tde preload"
    log "          during pg_upgrade target start (see PG_tde_upgrade_21_22_report.md)"
    exit 0
fi

log "VERDICT: failed but no decrypt line in pg_upgrade logs — inspect $RUN"
exit 1
