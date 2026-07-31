#!/usr/bin/env bash
#
# Scenario: PG-2609-style. Enable pg_tde.wal_encrypt via `patronictl
# edit-config` — the REAL orchestration path (Patroni pushes the dynamic
# config, SIGHUP fails since it's postmaster-context, Patroni then restarts
# the member) — instead of raw ALTER SYSTEM + pg_ctl restart. Run against the
# cluster from pg_tde_patroni_3node_setup.sh.
#
# Then generates WAL activity and a full backup, watching the leader's log
# for "mismatch of segment size" / pgbackrest ERROR 082.
#
# Usage:
#   source /tmp/pg_tde_patroni3/env.sh   # or: PATRONI3_ROOT=... first
#   bash postgresql/bugs/pg_tde_patroni_scenario_wal_encrypt.sh
#
#   ARCHIVE_TIMEOUT_S=15 bash ...   # cadence to wait between switches
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

[[ -f "$CFG" ]] || { echo "ERROR: $CFG not found — run pg_tde_patroni_3node_setup.sh first (or source its env.sh)"; exit 1; }
[[ -n "$BIN" ]] || { echo "ERROR: PG_TDE_PATRONI3_BIN unset — source $ROOT/env.sh first"; exit 1; }

echo "════════════════════════════════════════════════════════"
echo " Scenario: enable pg_tde.wal_encrypt via patronictl edit-config"
echo "════════════════════════════════════════════════════════"

get_leader() {
  patronictl -c "$CFG" list "$SCOPE" --format json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print([m for m in d if m.get('Role') in ('Leader','leader')][0]['Member'])"
}

LEADER_NAME="$(get_leader)"
[[ -n "$LEADER_NAME" ]] || { echo "ERROR: could not determine current leader"; exit 1; }
echo "current leader: $LEADER_NAME"

echo
echo "── Show current dynamic config ──"
patronictl -c "$CFG" show-config "$SCOPE"

echo
echo "── Merging pg_tde.wal_encrypt=on into dynamic config (flat GUC key,"
echo "   not nested — pg_tde.wal_encrypt is a literal Postgres parameter"
echo "   name, same as archive_timeout) ──"
PATCH_FILE="$ROOT/wal_encrypt_patch.yaml"
patronictl -c "$CFG" show-config "$SCOPE" 2>/dev/null | python3 -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin) or {}
cfg.setdefault('postgresql', {}).setdefault('parameters', {})['pg_tde.wal_encrypt'] = 'on'
yaml.safe_dump(cfg, sys.stdout, default_flow_style=False)
" > "$PATCH_FILE"
cat "$PATCH_FILE"

patronictl -c "$CFG" edit-config "$SCOPE" --replace "$PATCH_FILE" --force

echo
echo "── Watching for Patroni to notice it needs a restart, and apply it ──"
for _ in $(seq 1 60); do
  OUT="$(patronictl -c "$CFG" list "$SCOPE" 2>/dev/null || true)"
  if ! echo "$OUT" | grep -q "\* $"; then
    :
  fi
  echo "$OUT" | grep -q "Pending restart" || true
  sleep 2
  if patronictl -c "$CFG" list "$SCOPE" 2>/dev/null | grep -qi "running" ; then
    :
  fi
  # Patroni auto-applies pending restarts on its own schedule; nudge it now.
  patronictl -c "$CFG" restart "$SCOPE" "$LEADER_NAME" --pending --force >/dev/null 2>&1 || true
  ENC="$("$BIN/psql" -h "${ROOT}/socket1" -p 5501 -U postgres -d postgres -Atc "SHOW pg_tde.wal_encrypt" 2>/dev/null || echo "?")"
  if [[ "$ENC" == "on" ]]; then
    echo "pg_tde.wal_encrypt is on (leader restarted)"
    break
  fi
done

echo
echo "── Generating WAL activity + full backup ──"
LEADER_SOCK="$ROOT/socket1"
LEADER_PORT=5501
# Recompute in case a failover moved the leader elsewhere.
for i in 1 2 3; do
  p=$((5500+i))
  s="$ROOT/socket${i}"
  if "$BIN/psql" -h "$s" -p "$p" -U postgres -d postgres -Atc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q t; then
    LEADER_SOCK="$s"; LEADER_PORT="$p"
    break
  fi
done
echo "using leader socket=$LEADER_SOCK port=$LEADER_PORT"

sql() { "$BIN/psql" -h "$LEADER_SOCK" -p "$LEADER_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
sql -c "CREATE TABLE IF NOT EXISTS scenario_wal_encrypt(id int primary key, payload text) USING tde_heap;"
for i in $(seq 1 6); do
  s=$(( (i-1)*2000 + 1 )); e=$(( i*2000 ))
  sql -c "INSERT INTO scenario_wal_encrypt SELECT g, repeat('x',200) FROM generate_series($s,$e) g; CHECKPOINT; SELECT pg_switch_wal();" >/dev/null
  sleep "$ARCHIVE_TIMEOUT_S"
  echo "  cycle $i done"
done

echo
echo "── Full backup ──"
LEADER_DATADIR="$ROOT/data_${LEADER_NAME}"
set +e
"$PGBR" --config="$CONF" --stanza="$STANCE" --pg1-path="$LEADER_DATADIR" --pg1-port="$LEADER_PORT" --pg1-socket-path="$LEADER_SOCK" --type=full backup
BRC=$?
set -e

echo
echo "── Checking leader log for the mismatch signature ──"
LEADER_LOG=$(ls -1t "$ROOT/log"/postgresql-"${LEADER_NAME}"*.log 2>/dev/null | head -n1)
if [[ -n "$LEADER_LOG" ]] && grep -q "mismatch of segment size" "$LEADER_LOG"; then
  echo "REPRODUCED — mismatch of segment size:"
  grep -B2 -A2 "mismatch of segment size" "$LEADER_LOG"
else
  echo "Not seen this pass. backup exit=$BRC. Log: $LEADER_LOG"
fi
exit 0
