#!/usr/bin/env bash
# Multi-segment + PG-2397 rewind findings (lab repro helpers).
#
# These are companion scripts for pytest pins in
#   tests/test_tde_rewind_advanced.py::TestTdeRewindMultiSegmentCorruption
#   tests/test_tde_rewind_advanced.py::TestTdeRewindRestoreTargetWalDiscardedKeys
#
# Usage:
#   INSTALL_DIR=/path/to/pginst/18 bash postgresql/bugs/PG_rewind_multisegment_repro.sh
#
# Expected (fixed pg_tde): fingerprints match after rewind; exit 0.
# On a broken build: high-id rows in segment .1 decrypt as garbage / mismatch.
set -euo pipefail

# OS-aware default INSTALL_DIR (Ubuntu: /usr/lib/postgresql/N, RHEL: /usr/pgsql-N)
# shellcheck source=pg_install_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_install_env.sh"

BIN="$INSTALL_DIR/bin"
WORKDIR="${WORKDIR:-/tmp/pg_rewind_multiseg_$$}"
PORT_P="${PORT_P:-25410}"
PORT_S="${PORT_S:-25411}"
ROWS="${ROWS:-700000}"          # >1 GiB main fork with ~1800-byte PLAIN payloads
PAYLOAD_CHARS="${PAYLOAD_CHARS:-1800}"

export PATH="$BIN:$PATH"
export LD_LIBRARY_PATH="${INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"

cleanup() {
  "$BIN/pg_ctl" -D "$WORKDIR/primary" -m immediate stop >/dev/null 2>&1 || true
  "$BIN/pg_ctl" -D "$WORKDIR/standby" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{primary,standby,archive}

echo "== init primary =="
"$BIN/initdb" -D "$WORKDIR/primary" --no-data-checksums >/dev/null
cat >> "$WORKDIR/primary/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
port = $PORT_P
unix_socket_directories = '$WORKDIR'
listen_addresses = '127.0.0.1'
wal_level = replica
max_wal_senders = 5
hot_standby = on
wal_log_hints = on
logging_collector = off
EOF
echo "local all all trust" >> "$WORKDIR/primary/pg_hba.conf"
echo "local replication all trust" >> "$WORKDIR/primary/pg_hba.conf"
echo "host all all 127.0.0.1/32 trust" >> "$WORKDIR/primary/pg_hba.conf"
echo "host replication all 127.0.0.1/32 trust" >> "$WORKDIR/primary/pg_hba.conf"

"$BIN/pg_ctl" -D "$WORKDIR/primary" -w start
psql -h "$WORKDIR" -p "$PORT_P" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('file_provider', '$WORKDIR/keyring.per');
SELECT pg_tde_create_key_using_global_key_provider('k1', 'file_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('k1', 'file_provider');
SELECT pg_tde_set_key_using_global_key_provider('k1', 'file_provider');
SQL

echo "== basebackup standby (before large table) =="
"$BIN/pg_tde_basebackup" -h "$WORKDIR" -p "$PORT_P" -D "$WORKDIR/standby" \
  --checkpoint=fast -R >/dev/null
cat >> "$WORKDIR/standby/postgresql.conf" <<EOF
port = $PORT_S
unix_socket_directories = '$WORKDIR'
EOF
"$BIN/pg_ctl" -D "$WORKDIR/standby" -w start

echo "== create multi-segment tde_heap AFTER standby init ($ROWS rows) =="
# PLAIN keeps payload on the main heap fork (no TOAST compress / out-of-line),
# so base/<node> and base/<node>.1 appear once size exceeds 1 GiB.
psql -h "$WORKDIR" -p "$PORT_P" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE multi_seg (id BIGSERIAL PRIMARY KEY, payload TEXT NOT NULL) USING tde_heap;
ALTER TABLE multi_seg ALTER COLUMN payload SET STORAGE PLAIN;
INSERT INTO multi_seg(payload)
  SELECT rpad(g::text, $PAYLOAD_CHARS, md5(g::text))
  FROM generate_series(1, $ROWS) g;
CHECKPOINT;
SQL

# Wait for catchup
for i in $(seq 1 120); do
  LSN=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_P" -d postgres -Atc "SELECT pg_current_wal_lsn()")
  REPLAY=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_S" -d postgres -Atc "SELECT pg_last_wal_replay_lsn()")
  if [[ -n "$REPLAY" && "$REPLAY" != "" ]]; then
    ok=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_P" -d postgres -Atc \
      "SELECT '$REPLAY'::pg_lsn >= '$LSN'::pg_lsn")
    [[ "$ok" == "t" ]] && break
  fi
  sleep 1
done

SEG0=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_P" -d postgres -Atc \
  "SELECT d.oid || '/' || c.relfilenode FROM pg_class c, pg_database d
   WHERE c.relname='multi_seg' AND d.datname=current_database()")
if [[ ! -f "$WORKDIR/primary/base/${SEG0}.1" ]]; then
  echo "FAIL: expected segment .1 at base/${SEG0}.1 (relation not >1GB?)"
  ls -la "$WORKDIR/primary/base/$(dirname "$SEG0")/" | head
  exit 2
fi
echo "OK: multi-segment files present for $SEG0"

echo "== promote standby, diverge, rewind old primary =="
"$BIN/psql" -h "$WORKDIR" -p "$PORT_S" -d postgres -c "SELECT pg_promote(wait_seconds => 60)"
"$BIN/psql" -h "$WORKDIR" -p "$PORT_S" -d postgres -v ON_ERROR_STOP=1 <<SQL
UPDATE multi_seg SET payload = repeat('S', 100)
 WHERE id <= 100 OR id > (SELECT max(id) - 100 FROM multi_seg);
CHECKPOINT;
SQL
"$BIN/psql" -h "$WORKDIR" -p "$PORT_P" -d postgres -v ON_ERROR_STOP=1 <<SQL
UPDATE multi_seg SET payload = repeat('P', 100) WHERE id BETWEEN 200 AND 300;
CHECKPOINT;
SQL

SRC_FP=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_S" -d postgres -Atc \
  "SELECT md5(count(*)::text || '|' || sum(id)::text || '|' || sum(length(payload))::text) FROM multi_seg")

"$BIN/pg_ctl" -D "$WORKDIR/primary" -m fast -w stop
"$BIN/pg_ctl" -D "$WORKDIR/standby" -m fast -w stop

REWIND_BIN="$BIN/pg_tde_rewind"
[[ -x "$REWIND_BIN" ]] || REWIND_BIN="$BIN/pg_rewind"
"$REWIND_BIN" --target-pgdata="$WORKDIR/primary" --source-pgdata="$WORKDIR/standby"

# Fix port after rewind copies source conf
echo "port = $PORT_P" >> "$WORKDIR/primary/postgresql.conf"
rm -f "$WORKDIR/primary/standby.signal" "$WORKDIR/primary/recovery.signal"

"$BIN/pg_ctl" -D "$WORKDIR/primary" -w start
"$BIN/pg_ctl" -D "$WORKDIR/standby" -w start

TGT_FP=$("$BIN/psql" -h "$WORKDIR" -p "$PORT_P" -d postgres -Atc \
  "SELECT md5(count(*)::text || '|' || coalesce(sum(id),0)::text || '|' || coalesce(sum(length(payload)),0)::text) FROM multi_seg" \
  || echo "QUERY_FAILED")

echo "source fingerprint=$SRC_FP"
echo "target fingerprint=$TGT_FP"
if [[ "$TGT_FP" == "$SRC_FP" ]]; then
  echo "PASS: multi-segment data intact after rewind (product fix present?)"
  exit 0
fi
echo "REPRODUCED: multi-segment corruption / unreadability after rewind"
exit 1
