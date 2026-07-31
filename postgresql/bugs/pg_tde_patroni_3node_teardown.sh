#!/usr/bin/env bash
# Stop the 3-node Patroni playground started by pg_tde_patroni_3node_setup.sh.
#
# Usage:
#   bash postgresql/bugs/pg_tde_patroni_3node_teardown.sh
#   PATRONI3_ROOT=/custom/path bash postgresql/bugs/pg_tde_patroni_3node_teardown.sh
#   KEEP_DATA=1 bash ...   # stop processes but leave $ROOT on disk for inspection
#
set -uo pipefail

ROOT="${PATRONI3_ROOT:-/tmp/pg_tde_patroni3}"

if [[ ! -d "$ROOT" ]]; then
  echo "Nothing to tear down at $ROOT"
  exit 0
fi

for pidfile in "$ROOT"/patroni-node*.pid; do
  [[ -f "$pidfile" ]] || continue
  pid="$(cat "$pidfile")"
  name="$(basename "$pidfile" .pid)"
  if kill -0 "$pid" 2>/dev/null; then
    echo "stopping $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
  fi
done

sleep 3

# Force-stop anything still lingering (patroni sometimes needs a nudge to let
# postgres shut down cleanly first — give it a moment, then escalate).
pkill -f "patroni ${ROOT}/patroni" 2>/dev/null || true
sleep 2
pkill -9 -f "patroni ${ROOT}/patroni" 2>/dev/null || true

if command -v pg2609_ensure_openbao >/dev/null 2>&1 || [[ -n "${OPENBAO_PID:-}" ]]; then
  kill "${OPENBAO_PID:-0}" 2>/dev/null || true
fi
pkill -f "bao server .*${ROOT}/openbao" 2>/dev/null || true

if [[ "${KEEP_DATA:-0}" == "1" ]]; then
  echo "processes stopped, data kept at $ROOT"
else
  rm -rf "$ROOT"
  echo "torn down and removed $ROOT"
fi
