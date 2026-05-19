#!/usr/bin/env bash
# Ghost relfilenode (drop/recreate ghost_t) + PG17→PG18 pg_tde_upgrade repro.
#
# Two possible outcomes:
#   A) pg_tde_upgrade fails at target start → pg_tde product bug (2.1 keys + 2.2 preload).
#      You never reach SELECT id FROM ghost_t — NOT a relfilenode bug yet.
#   B) pg_tde_upgrade succeeds → SELECT must return id=2 (else file relfilenode bug).
#
# Usage:
#   export OLD=/usr/lib/postgresql/17 NEW=/usr/lib/postgresql/18
#   bash postgresql/bugs/relfile_issue.sh
#
# See: postgresql/bugs/PG_tde_upgrade_21_22_report.md

set -euo pipefail

OLD="${OLD:-/usr/lib/postgresql/17}"
NEW="${NEW:-/usr/lib/postgresql/18}"
RUN="${RUN:-/tmp/ghost_manual}"
OLD_PORT="${OLD_PORT:-15511}"
NEW_PORT="${NEW_PORT:-15512}"
KEYFILE="${KEYFILE:-$RUN/ghost.per}"

export PGHOST="$RUN"
# Avoid pytest cwd/socket pollution when run from postgresql/pytest/
unset PGPORT PGDATABASE 2>/dev/null || true

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

read_pg_tde_ver() {
    local maj=$("$1/bin/postgres" --version | awk '{print $3}' | cut -d. -f1)
    local ctrl="/usr/share/postgresql/${maj}/extension/pg_tde.control"
    [[ -f "$ctrl" ]] && grep '^default_version' "$ctrl" | cut -d= -f2 | tr -d " '" || echo "?"
}

cleanup() {
    log "Cleaning $RUN"
    "$OLD/bin/pg_ctl" -D "$RUN/old" -m fast stop 2>/dev/null || true
    "$NEW/bin/pg_ctl" -D "$RUN/new" -m fast stop 2>/dev/null || true
    lsof -ti:"$OLD_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    lsof -ti:"$NEW_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    rm -rf "$RUN"
    rm -f "$KEYFILE"
}

command -v "$OLD/bin/initdb" >/dev/null || die "missing $OLD"
command -v "$NEW/bin/pg_tde_upgrade" >/dev/null || die "missing $NEW/bin/pg_tde_upgrade"

OLD_TDE=$(read_pg_tde_ver "$OLD")
NEW_TDE=$(read_pg_tde_ver "$NEW")
log "OLD=$OLD (pg_tde $OLD_TDE)  NEW=$NEW (pg_tde $NEW_TDE)"

if [[ "$OLD_TDE" == "$NEW_TDE" ]]; then
    log "WARNING: same pg_tde default_version ($OLD_TDE) — decrypt during upgrade may not reproduce"
fi

cleanup
mkdir -p "$RUN"

# ── Step 1–3: Old cluster + ghost_t relfilenode churn ───────────────────────
log "Step 1: initdb old (PG17)"
"$OLD/bin/initdb" -D "$RUN/old"

cat >> "$RUN/old/postgresql.conf" <<EOF
port = $OLD_PORT
unix_socket_directories = '$RUN'
listen_addresses = '127.0.0.1'
shared_preload_libraries = 'pg_tde'
wal_level = replica
logging_collector = off
EOF
echo "local all all trust" >> "$RUN/old/pg_hba.conf"

log "Step 2: ghost_t create → drop → recreate → VACUUM FULL (pre-upgrade id must be 2)"
"$OLD/bin/pg_ctl" -D "$RUN/old" -w -t 60 -o "-p $OLD_PORT -k $RUN" -l "$RUN/old.log" start

"$OLD/bin/psql" -h "$RUN" -p "$OLD_PORT" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');
SELECT pg_tde_create_key_using_global_key_provider('test_key', 'file_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('test_key', 'file_provider');
SELECT pg_tde_set_key_using_global_key_provider('test_key', 'file_provider');
CREATE TABLE ghost_t (id INT) USING tde_heap;
INSERT INTO ghost_t VALUES (1);
DROP TABLE ghost_t;
CREATE TABLE ghost_t (id INT) USING tde_heap;
INSERT INTO ghost_t VALUES (2);
VACUUM FULL;
SELECT 'pre-upgrade' AS phase, id FROM ghost_t;
SQL

log "Step 3: stop old"
"$OLD/bin/pg_ctl" -D "$RUN/old" -m fast stop
test -d "$RUN/old/pg_tde" || die "old cluster has no pg_tde/ — setup failed"

# ── Step 4–5: Empty new cluster + pg_tde_upgrade ─────────────────────────────
log "Step 4: initdb new (PG18) — shared_preload_libraries=pg_tde (required for TDE docs)"
"$NEW/bin/initdb" -D "$RUN/new" --no-data-checksums

cat > "$RUN/new/postgresql.conf" <<EOF
port = $NEW_PORT
unix_socket_directories = '$RUN'
listen_addresses = '127.0.0.1'
shared_preload_libraries = 'pg_tde'
logging_collector = off
include_if_exists = 'postgresql.auto.conf'
EOF
echo "local all all trust" >> "$RUN/new/pg_hba.conf"

log "Step 5: pg_tde_upgrade (copies old/pg_tde → new/pg_tde BEFORE pg_upgrade)"
log "        new/pg_tde before wrapper: $(test -d "$RUN/new/pg_tde" && echo yes || echo no)"

set +e
# --socketdir: required if you run this from postgresql/pytest/ (else pg_upgrade
# may use cwd and you see ".s.PGSQL.*" under pytest/ in the error text).
"$NEW/bin/pg_tde_upgrade" --no-sync \
    --socketdir "$RUN" \
    --old-datadir "$RUN/old" \
    --new-datadir "$RUN/new" \
    --old-bindir "$OLD/bin" \
    --new-bindir "$NEW/bin" \
    --old-port "$OLD_PORT" \
    --new-port "$NEW_PORT"
UPGRADE_RC=$?
set -e

SERVER_LOG=$(find "$RUN/new/pg_upgrade_output.d" -name pg_upgrade_server.log 2>/dev/null | head -1 || true)

if [[ $UPGRADE_RC -ne 0 ]]; then
    log ""
    log "========== UPGRADE FAILED (rc=$UPGRADE_RC) =========="
    if [[ -n "$SERVER_LOG" ]]; then
        log "--- tail of pg_upgrade_server.log ---"
        tail -20 "$SERVER_LOG"
    fi
    if [[ -n "$SERVER_LOG" ]] && grep -q "failed to decrypt key" "$SERVER_LOG"; then
        log ""
        log "VERDICT: PG-2381 smgr key migration (fixed in pg_tde PR #582)."
        log "  Empty key-file slots (DROP TABLE) and/or 0-byte *_keys (VACUUM FULL)"
        log "  made pg_tde 2.2 fail while migrating keys during pg_upgrade target start."
        log "  Install pg_tde with PR #582, then re-run; see TestPg2381EmptyKeyMigration."
        log ""
        log "  Not a relfilenode bug until upgrade completes and SELECT id is wrong."
    else
        log "VERDICT: upgrade failed for another reason — inspect $RUN/new/pg_upgrade_output.d/"
    fi
    exit 2
fi

# ── Steps 6–9: Only if upgrade succeeded — relfilenode verification ──────────
log "Step 6: pg_tde_upgrade succeeded — start new cluster"
"$NEW/bin/pg_ctl" -D "$RUN/new" -w -t 90 -o "-p $NEW_PORT -k $RUN" -l "$RUN/new.log" start

log "Step 7: ALTER EXTENSION pg_tde UPDATE (2.1 → 2.2 catalog migration)"
"$NEW/bin/psql" -h "$RUN" -p "$NEW_PORT" -d postgres -v ON_ERROR_STOP=1 \
    -c "ALTER EXTENSION pg_tde UPDATE;"

log "Step 8: relfilenode / identity check"
RESULT=$("$NEW/bin/psql" -h "$RUN" -p "$NEW_PORT" -d postgres -t -A \
    -c "SELECT id FROM ghost_t;" | tr -d '[:space:]')

"$NEW/bin/psql" -h "$RUN" -p "$NEW_PORT" -d postgres -c \
    "SELECT relname, relfilenode FROM pg_class WHERE relname = 'ghost_t';"

"$NEW/bin/pg_ctl" -D "$RUN/new" -m fast stop

if [[ "$RESULT" == "2" ]]; then
    log ""
    log "VERDICT: PASS — ghost_t id=2 after upgrade (no relfilenode mapping bug)"
    exit 0
fi

log ""
log "VERDICT: RELFILENODE BUG — expected id=2, got '$RESULT'"
exit 1
