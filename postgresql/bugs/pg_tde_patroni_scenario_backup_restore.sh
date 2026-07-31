#!/usr/bin/env bash
#
# Scenario: PG-2587-style. Full backup, then in-place restore onto the
# current leader while Patroni is paused (matching how the operator's
# PerconaPGRestore pauses reconciliation, restores, then resumes). Watches
# the replicas' logs for "invalid magic number" / "has already been removed".
#
# Run against the cluster from pg_tde_patroni_3node_setup.sh. Requires
# pg_tde.wal_encrypt already on (run pg_tde_patroni_scenario_wal_encrypt.sh
# first, or flip it yourself via patronictl edit-config).
#
# Usage:
#   source /tmp/pg_tde_patroni3/env.sh
#   bash postgresql/bugs/pg_tde_patroni_scenario_backup_restore.sh
#
set -uo pipefail

ROOT="${PATRONI3_ROOT:-/tmp/pg_tde_patroni3}"
SCOPE="${PG_TDE_PATRONI3_SCOPE:-pg_tde_cluster}"
CFG="$ROOT/patroni0.yml"
BIN="${PG_TDE_PATRONI3_BIN:-}"
PGBR="${PG_TDE_PATRONI3_PGBR:-$(command -v pgbackrest || true)}"
CONF="${PG_TDE_PATRONI3_CONF:-$ROOT/pgbackrest.conf}"
STANCE="${PG_TDE_PATRONI3_STANCE:-db}"
ARCHIVE_TIMEOUT_S="${ARCHIVE_TIMEOUT_S:-15}"

[[ -f "$CFG" ]] || { echo "ERROR: $CFG not found — run pg_tde_patroni_3node_setup.sh first"; exit 1; }
[[ -n "$BIN" ]] || { echo "ERROR: PG_TDE_PATRONI3_BIN unset — source $ROOT/env.sh first"; exit 1; }

echo "════════════════════════════════════════════════════════"
echo " Scenario: full backup + in-place restore onto the leader"
echo "════════════════════════════════════════════════════════"

get_leader() {
  patronictl -c "$CFG" list "$SCOPE" --format json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print([m for m in d if m.get('Role') in ('Leader','leader')][0]['Member'])"
}

LEADER_NAME="$(get_leader)"
[[ -n "$LEADER_NAME" ]] || { echo "ERROR: could not determine current leader"; exit 1; }
LEADER_DATADIR="$ROOT/data_${LEADER_NAME}"
LEADER_SOCK=""
LEADER_PORT=""
for i in 1 2 3; do
  p=$((5500+i))
  s="$ROOT/socket${i}"
  if "$BIN/psql" -h "$s" -p "$p" -U postgres -d postgres -Atc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q t; then
    LEADER_SOCK="$s"; LEADER_PORT="$p"
    break
  fi
done
[[ -n "$LEADER_SOCK" ]] || { echo "ERROR: could not find current leader's live socket"; exit 1; }
echo "leader: $LEADER_NAME  datadir=$LEADER_DATADIR  socket=$LEADER_SOCK  port=$LEADER_PORT"

sql() { "$BIN/psql" -h "$LEADER_SOCK" -p "$LEADER_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
ENC="$(sql -Atc "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo off)"
echo "pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || echo "WARNING: wal_encrypt is off — run pg_tde_patroni_scenario_wal_encrypt.sh first to match the bug's preconditions"

echo
echo "── Writing data, checkpoint, switch, wait ──"
sql -c "CREATE TABLE IF NOT EXISTS scenario_restore(id int primary key, payload text) USING tde_heap;"
sql -c "INSERT INTO scenario_restore SELECT g, repeat('x',200) FROM generate_series(1,5000) g;"
sql -c "CHECKPOINT;"
sql -c "SELECT pg_switch_wal();"
sleep "$ARCHIVE_TIMEOUT_S"

echo
echo "── Full backup ──"
"$PGBR" --config="$CONF" --stanza="$STANCE" --pg1-path="$LEADER_DATADIR" --pg1-port="$LEADER_PORT" --pg1-socket-path="$LEADER_SOCK" --type=full backup

echo
echo "── Pausing Patroni cluster-wide (so it doesn't fight us over the leader"
echo "   while we stop/restore/start it directly) ──"
patronictl -c "$CFG" pause "$SCOPE" --wait

echo "── Stopping leader postgres directly ──"
"$BIN/pg_ctl" -D "$LEADER_DATADIR" -m fast -w stop

echo "── Restoring backup in place ──"
"$PGBR" --config="$CONF" --stanza="$STANCE" --pg1-path="$LEADER_DATADIR" --pg1-port="$LEADER_PORT" --pg1-socket-path="$LEADER_SOCK" --delta restore

echo "── Starting leader postgres back up ──"
"$BIN/pg_ctl" -D "$LEADER_DATADIR" -w start

echo "── Resuming Patroni ──"
patronictl -c "$CFG" resume "$SCOPE" --wait

echo
echo "── Watching replica logs for the PG-2587 failure signature (up to 3 min) ──"
FOUND=0
FOUND_IN=""
for _ in $(seq 1 36); do
  sleep 5
  for name in node1 node2 node3; do
    [[ "$name" == "$LEADER_NAME" ]] && continue
    log="$ROOT/log/postgresql-${name}.log"
    [[ -f "$log" ]] || continue
    if grep -qE "invalid magic number|has already been removed" "$log"; then
      FOUND=1
      FOUND_IN="$log"
      break 2
    fi
  done
done

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY"
echo "════════════════════════════════════════════════════════"
if [[ "$FOUND" -eq 1 ]]; then
  echo " REPRODUCED — $FOUND_IN shows:"
  grep -E "invalid magic number|has already been removed|new target timeline|waiting for WAL to become available" "$FOUND_IN" | tail -20
else
  echo " Not reproduced this pass. patronictl list:"
  patronictl -c "$CFG" list "$SCOPE" || true
  echo " Replica logs are under $ROOT/log/postgresql-node*.log"
fi
exit 0
