#!/usr/bin/env bash
#
# PG-2587 CONTROL #2 — same topology as PG-2587_control_no_tde_replica_restore.sh
# (no pg_tde), but pg_wal is a PLAIN SUBDIRECTORY of PGDATA — NOT symlinked to
# a sibling directory.
#
# Jira: https://perconadev.atlassian.net/browse/PG-2587
#
# Purpose: PG-2587_control_no_tde_replica_restore.sh confirmed the
# stuck-on-old-timeline hang happens with NO pg_tde at all, ruling out
# encryption. That script kept pg_wal symlinked (matching the operator's
# walVolumeClaimSpec layout) to isolate the TDE variable specifically. This
# script isolates the OTHER variable: does the symlink itself matter?
#
# The stuck mechanism (recovery detects the timeline fork via the .history
# file but never updates which TLI it uses to construct restore_command
# filenames) is LSN/TLI bookkeeping in PostgreSQL's recovery code — it
# shouldn't care where pg_wal physically lives on disk. This script tests
# that assumption directly instead of just asserting it.
#
# If this ALSO hangs identically: the symlink is irrelevant to THIS bug (it
# only mattered for PG-2609's tdedir-derivation bug) — the stuck-timeline
# issue is purely about the in-place-restore-with-attached-replica topology.
# If this does NOT hang: the symlink is somehow a contributing factor here
# too, which would be a second, independent way it causes trouble.
#
# Usage:
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/PG-2587_control_plain_pgwal_replica_restore.sh
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to the PostgreSQL install prefix"
  exit 1
fi

REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2587_control_plain_pgwal}}"
PRIMARY="$REPRO_ROOT/primary"
REPLICA="$REPRO_ROOT/replica"
SOCK="$REPRO_ROOT/socket"
SOCK_REPLICA="$REPRO_ROOT/socket_replica"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
P_PORT="${P_PORT:-25640}"
P_PORT_REPLICA="${P_PORT_REPLICA:-25641}"
STANCE="db"
ARCHIVE_TIMEOUT_S="${ARCHIVE_TIMEOUT_S:-15}"

BIN="$INSTALL_DIR/bin"
PSQL="$BIN/psql"
PG_CTL="$BIN/pg_ctl"
INITDB="$BIN/initdb"
PG_BASEBACKUP="$BIN/pg_basebackup"
ISREADY="$BIN/pg_isready"
PGBR="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB" "$PG_BASEBACKUP"; do
  [[ -x "$b" ]] || { echo "ERROR: missing $b"; exit 1; }
done
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

export PGDATABASE=postgres
PG_SUPERUSER="${PGUSER:-$(id -un)}"
sql() { "$PSQL" -h "$SOCK" -p "$P_PORT" -U "$PG_SUPERUSER" -d postgres -v ON_ERROR_STOP=1 "$@"; }

wait_ready() {
  local sock="$1" port="$2"
  for _ in $(seq 1 90); do
    "$ISREADY" -h "$sock" -p "$port" -d postgres >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: not ready ($sock:$port)"; exit 1
}

cleanup() {
  "$PG_CTL" -D "$REPLICA" -m immediate stop >/dev/null 2>&1 || true
  "$PG_CTL" -D "$PRIMARY" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$REPRO_ROOT"
mkdir -p "$SOCK" "$SOCK_REPLICA" "$REPO" "$REPRO_ROOT/log" "$REPRO_ROOT/spool"

echo "════════════════════════════════════════════════════════"
echo " PG-2587 CONTROL #2 — no pg_tde, pg_wal is a PLAIN subdirectory"
echo " (not symlinked — isolates the symlink variable specifically)"
echo " INSTALL_DIR=$INSTALL_DIR  REPRO_ROOT=$REPRO_ROOT"
echo "════════════════════════════════════════════════════════"

cat > "$CONF" <<EOF
[global]
repo1-path=$REPO
repo1-retention-full=2
start-fast=y
log-level-console=info
log-level-file=detail
log-path=$REPRO_ROOT/log
spool-path=$REPRO_ROOT/spool
archive-async=n
archive-header-check=n
checksum-page=n

[$STANCE]
pg1-path=$PRIMARY
pg1-port=$P_PORT
pg1-socket-path=$SOCK
pg1-database=postgres
EOF

"$INITDB" -D "$PRIMARY" --no-data-checksums >/dev/null
# NOTE: no pg_wal symlink step here — pg_wal stays exactly what initdb made.

ARCHIVE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push \"%p\""
RESTORE_CMD_PRIMARY="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-get %f \"%p\""
RESTORE_CMD_REPLICA="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${REPLICA} archive-get %f \"%p\""

cat >> "$PRIMARY/postgresql.conf" <<EOF
port = $P_PORT
unix_socket_directories = '$SOCK'
listen_addresses = '127.0.0.1'
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
track_commit_timestamp = on
archive_mode = on
archive_timeout = ${ARCHIVE_TIMEOUT_S}s
archive_command = '${ARCHIVE_CMD}'
restore_command = '${RESTORE_CMD_PRIMARY}'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_statement = 'none'
log_min_messages = info
log_line_prefix = '%m [%p] '
EOF
mkdir -p "$PRIMARY/log"
echo "local all all trust" >> "$PRIMARY/pg_hba.conf"
echo "local replication all trust" >> "$PRIMARY/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$PRIMARY/pg_hba.conf"
echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY/pg_hba.conf"

echo
echo "── Bootstrap primary (no pg_tde, plain pg_wal directory) ──"
"$PG_CTL" -D "$PRIMARY" -w start
wait_ready "$SOCK" "$P_PORT"
echo "pg_wal is: $(ls -ld "$PRIMARY/pg_wal" | awk '{print $1}') (should NOT start with 'l')"

pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create

echo
echo "── Set up streaming replica (vanilla pg_basebackup, plain pg_wal) ──"
"$PG_BASEBACKUP" -h "$SOCK" -p "$P_PORT" -D "$REPLICA" -U "$PG_SUPERUSER" -Fp -Xs -R -w
# NOTE: no symlink step for the replica's pg_wal either.

cat >> "$REPLICA/postgresql.conf" <<EOF
port = $P_PORT_REPLICA
unix_socket_directories = '$SOCK_REPLICA'
listen_addresses = '127.0.0.1'
restore_command = '${RESTORE_CMD_REPLICA}'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_min_messages = info
log_line_prefix = '%m [%p] '
EOF
mkdir -p "$REPLICA/log"
"$PG_CTL" -D "$REPLICA" -w start
wait_ready "$SOCK_REPLICA" "$P_PORT_REPLICA"
REPLICA_LOG=$(ls -1t "$REPLICA/log"/postgresql-*.log 2>/dev/null | head -n1)
for _ in $(seq 1 30); do
  grep -q "started streaming WAL from primary" "$REPLICA_LOG" 2>/dev/null && break
  sleep 1
done
echo "replica streaming: $(grep -c "started streaming WAL from primary" "$REPLICA_LOG" 2>/dev/null || echo 0) connection(s) so far"

echo
echo "── Create table, write data, checkpoint, switch, wait ──"
sql -c "CREATE TABLE t1(id int primary key, payload text);"
sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(1,5000) g;"
sql -c "CHECKPOINT;"
sql -c "SELECT pg_switch_wal();"
sleep "${ARCHIVE_TIMEOUT_S}"

echo
echo "── Full backup ──"
pgbackrest --config="$CONF" --stanza="$STANCE" --type=full backup

RESTORE_MARKER_LINE=$(wc -l < "$REPLICA_LOG" | tr -d ' ')

echo
echo "── Restore in place onto the primary ──"
"$PG_CTL" -D "$PRIMARY" -w -m fast stop
pgbackrest --config="$CONF" --stanza="$STANCE" --pg1-path="$PRIMARY" --delta restore
"$PG_CTL" -D "$PRIMARY" -w start
wait_ready "$SOCK" "$P_PORT"
echo "primary back online after restore."

echo
echo "── Keep the primary generating fresh (timeline-2) WAL, watching whether"
echo "   the replica's recovery ever advances past the fork point or stays"
echo "   permanently stuck at the same LSN ──"
FOUND=0
LAST_WAITING_LSN=""
STUCK_COUNT=0
for i in $(seq 1 24); do
  sql -c "INSERT INTO t1 SELECT g, repeat('y',200) FROM generate_series($((10000+i)),$((10000+i))) g;" >/dev/null 2>&1 || true
  sql -c "CHECKPOINT; SELECT pg_switch_wal();" >/dev/null 2>&1 || true
  sleep 5

  NEW_LINES="$(tail -n "+$((RESTORE_MARKER_LINE+1))" "$REPLICA_LOG" 2>/dev/null)"
  if echo "$NEW_LINES" | grep -qE "invalid magic number|has already been removed"; then
    FOUND=1
  fi

  CUR_WAITING_LSN="$(echo "$NEW_LINES" | grep -oE "waiting for WAL to become available at [0-9A-F/]+" | tail -n1)"
  if [[ -n "$CUR_WAITING_LSN" ]]; then
    if [[ "$CUR_WAITING_LSN" == "$LAST_WAITING_LSN" ]]; then
      STUCK_COUNT=$((STUCK_COUNT+1))
    else
      STUCK_COUNT=0
      LAST_WAITING_LSN="$CUR_WAITING_LSN"
    fi
  fi
  echo "  cycle $i: waiting_lsn='${CUR_WAITING_LSN:-<none>}' stuck_count=$STUCK_COUNT"
  if [[ "$STUCK_COUNT" -ge 4 ]]; then
    FOUND=1
    break
  fi
done

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY (no pg_tde, plain pg_wal directory — no symlink)"
echo "════════════════════════════════════════════════════════"
POST_RESTORE_LOG="$(tail -n "+$((RESTORE_MARKER_LINE+1))" "$REPLICA_LOG" 2>/dev/null)"
if [[ "$FOUND" -eq 1 && "$STUCK_COUNT" -ge 4 ]]; then
  echo " HANGS THE SAME WAY WITHOUT THE SYMLINK TOO — replica stuck at the"
  echo " same LSN ($LAST_WAITING_LSN) across $STUCK_COUNT consecutive checks"
  echo " despite the primary producing new timeline-2 WAL. The symlink is"
  echo " NOT a factor in this bug — it's purely the in-place-restore-with-"
  echo " attached-replica topology. Post-restore replica log:"
  echo "$POST_RESTORE_LOG" | tail -30
elif [[ "$FOUND" -eq 1 ]]; then
  echo " Saw the magic-number/removed-segment text but did not stay stuck for"
  echo " 4+ consecutive checks. Post-restore log:"
  echo "$POST_RESTORE_LOG" | tail -30
else
  echo " DID NOT HANG — replica caught up fine WITHOUT the symlink. That"
  echo " would mean the symlink IS a contributing factor to this specific"
  echo " hang after all, on top of its separate, already-confirmed role in"
  echo " PG-2609. Post-restore replica log:"
  echo "$POST_RESTORE_LOG" | tail -30
fi
echo
echo " Replica log: $REPLICA_LOG"
echo " Primary log: $(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1)"
exit 0
