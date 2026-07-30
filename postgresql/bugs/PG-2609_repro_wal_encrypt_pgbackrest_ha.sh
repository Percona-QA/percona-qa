#!/usr/bin/env bash
#
# PG-2609 — bash repro matching the attached postgresql.log failure.
#
# Jira: https://perconadev.atlassian.net/browse/PG-2609
#
# Observed in the bug (not HA/rewire — backup archiving):
#   pg_tde_archive_decrypt: error: mismatch of segment size in WAL file
#     "00000001000000000000000F" (header: <garbage> bytes, file size: 16777216)
#   → WAL never lands in the repo
#   → pgbackrest backup ERROR [082]: WAL segment … was not archived before timeout
#
# Operator config traits from attachments:
#   pg_tde.wal_encrypt=on
#   Vault/OpenBao global key provider (not file keyring)
#   archive_command='pg_tde_archive_decrypt %f %p "pgbackrest … archive-push %%p" && …waldump…'
#   pgbackrest: archive-header-check=n, checksum-page=n
#
# Usage (OpenBao — default, matches operator Vault path):
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/PG-2609_repro_wal_encrypt_pgbackrest_ha.sh
#   # Boots local OpenBao via PG-2609_openbao_setup.sh (inlined; no pytest scripts).
#
#   # Reuse an already-exported OpenBao env:
#   AUTO_OPENBAO=0 VAULT_ADDR=... VAULT_TOKEN_FILE=... INSTALL_DIR=... bash ...
#
#   # File keyring (no OpenBao) — separate script for local/dev machines:
#   #   postgresql/bugs/PG-2609_repro_wal_encrypt_pgbackrest_file.sh
#   # Or: KEY_PROVIDER=file INSTALL_DIR=... bash ... (this script)
#
#   SKIP_WALDUMP_SIDECHAIN=1 INSTALL_DIR=... bash ...
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to the PostgreSQL install prefix"
  exit 1
fi

# Do not name this ROOT — OpenBao root token must not clobber the workdir path.
REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2609_repro}}"
PRIMARY="$REPRO_ROOT/primary"
SOCK="$REPRO_ROOT/socket"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
KEYFILE="$REPRO_ROOT/keyring.per"
P_PORT="${P_PORT:-25609}"
STANCE="db"
SKIP_WALDUMP_SIDECHAIN="${SKIP_WALDUMP_SIDECHAIN:-0}"
# Real bug log ran ~8 min of continuous checkpoint/archive cycles after the
# wal_encrypt-enabling restart (archive_timeout=60s there). Default here is
# shorter to keep the repro fast but still cover several cycles.
ARCHIVE_TIMEOUT_S="${ARCHIVE_TIMEOUT_S:-15}"
LOAD_DURATION_S="${LOAD_DURATION_S:-90}"
# openbao|vault (default) or file
KEY_PROVIDER="${KEY_PROVIDER:-openbao}"
# Bootstrap local OpenBao if VAULT_* is missing (set AUTO_OPENBAO=0 to require pre-exported env).
AUTO_OPENBAO="${AUTO_OPENBAO:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=PG-2609_openbao_setup.sh
source "$SCRIPT_DIR/PG-2609_openbao_setup.sh"

BIN="$INSTALL_DIR/bin"
PSQL="$BIN/psql"
PG_CTL="$BIN/pg_ctl"
INITDB="$BIN/initdb"
ISREADY="$BIN/pg_isready"
DECRYPT="$BIN/pg_tde_archive_decrypt"
WALDUMP="$BIN/pg_tde_waldump"
PGBR="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB" "$DECRYPT"; do
  [[ -x "$b" ]] || { echo "ERROR: missing $b"; exit 1; }
done
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

# initdb creates a superuser matching the OS user; default DB name is that user
# (e.g. "ubuntu") which does not exist — always use database postgres.
export PGDATABASE=postgres
export PGHOST="$SOCK"
export PGPORT="$P_PORT"
# Do not set PGUSER unless needed; peer/trust as the initdb owner is fine.

sql() { "$PSQL" -h "$SOCK" -p "$P_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"; }

wait_ready() {
  for _ in $(seq 1 90); do
    "$ISREADY" -h "$SOCK" -p "$P_PORT" -d postgres >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: not ready"; exit 1
}

# Resolve Vault/OpenBao env for KEY_PROVIDER=openbao|vault.
# Copies token into $REPRO_ROOT so archive_decrypt (FE) can read it.
ensure_openbao_env() {
  mkdir -p "$REPRO_ROOT"
  OPENBAO_RUN_DIR="${OPENBAO_RUN_DIR:-$REPRO_ROOT/openbao}"
  pg2609_ensure_openbao || exit 1

  VAULT_URL="${VAULT_ADDR%/}"
  VAULT_MOUNT="${VAULT_SECRET_MOUNT:-pg_tde}"
  # OpenBao uses trailing slash; HashiCorp may omit namespace.
  VAULT_NS="${VAULT_NAMESPACE:-}"
  if [[ "${KEY_PROVIDER}" == "openbao" && -z "$VAULT_NS" ]]; then
    VAULT_NS="pg_tde_ns1/"
  fi
  if [[ -n "$VAULT_NS" && "${VAULT_NS}" != */ ]]; then
    VAULT_NS="${VAULT_NS}/"
  fi

  TOKEN_DST="$REPRO_ROOT/vault_token"
  if [[ -n "${VAULT_TOKEN_FILE:-}" && -f "${VAULT_TOKEN_FILE}" ]]; then
    cp -f "${VAULT_TOKEN_FILE}" "$TOKEN_DST"
  elif [[ -n "${VAULT_TOKEN:-}" ]]; then
    printf '%s' "${VAULT_TOKEN}" > "$TOKEN_DST"
  else
    echo "ERROR: need VAULT_TOKEN_FILE or VAULT_TOKEN"
    exit 1
  fi
  chmod 600 "$TOKEN_DST"
  VAULT_TOKEN_PATH="$TOKEN_DST"

  echo " Vault/OpenBao:"
  echo "   VAULT_ADDR=$VAULT_URL"
  echo "   mount=$VAULT_MOUNT  namespace=${VAULT_NS:-(none)}"
  echo "   token_file=$VAULT_TOKEN_PATH"
}

setup_tde_keys() {
  sql -c "CREATE EXTENSION pg_tde;"
  # Match the operator's actual bootstrap SQL verbatim (postgresql.log shows
  # this exact call, issued twice ~70ms apart — idempotent retry from the
  # operator's reconcile loop). Using this single call instead of the separate
  # create_key/set_server_key/set_key calls matters: per
  # tde_principal_key.c:pg_tde_set_default_key_using_global_key_provider(),
  # "Without this, the server key is only materialized lazily during the next
  # startup when WAL encryption is initialized" — i.e. server(WAL)-key
  # materialization timing differs from calling set_server_key explicitly
  # ahead of time, which is what v1 of this repro did (and did NOT reproduce).
  KEY_NAME="global-master-key-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  case "$KEY_PROVIDER" in
    file)
      echo "── KEY_PROVIDER=file (file keyring) ──"
      sql -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
      # set_default_key_using_global_key_provider requires the key to already
      # exist in the provider (tde_principal_key.c:257 set_principal_key_with_keyring
      # -> KeyringGetKey fails otherwise). The operator must provision the key
      # in Vault out-of-band before running the SQL captured in the bug log.
      sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      PROVIDER_NAME="file_provider"
      ;;
    openbao|vault)
      echo "── KEY_PROVIDER=$KEY_PROVIDER (vault_v2 / OpenBao) ──"
      ensure_openbao_env
      # Match automation: vault_v2(url, mount, token_path, ca, namespace)
      if [[ -n "$VAULT_NS" ]]; then
        sql -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL,'$VAULT_NS');"
      else
        sql -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL);"
      fi
      # Key must pre-exist in Vault before set_default_key_using_... can use it.
      sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
      # Called twice like the real bug log (bootstrap retry).
      sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
      sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
      PROVIDER_NAME="vault-provider"
      ;;
    *)
      echo "ERROR: KEY_PROVIDER must be openbao, vault, or file (got: $KEY_PROVIDER)"
      exit 1
      ;;
  esac
  echo " using provider: $PROVIDER_NAME (key: $KEY_NAME)"
}

cleanup() { "$PG_CTL" -D "$PRIMARY" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

rm -rf "$REPRO_ROOT"
mkdir -p "$SOCK" "$REPO" "$REPRO_ROOT/log" "$REPRO_ROOT/spool"

echo "════════════════════════════════════════════════════════"
echo " PG-2609 repro — archive_decrypt + wal_encrypt + backup"
echo " INSTALL_DIR=$INSTALL_DIR"
echo " REPRO_ROOT=$REPRO_ROOT"
echo " KEY_PROVIDER=$KEY_PROVIDER"
echo "════════════════════════════════════════════════════════"

# Match attachment (encrypted-in-repo flags even though decrypt wrappers are used —
# that mix is what the operator shipped).
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

# ROOT CAUSE (confirmed by the pg_tde dev team, 2026-07-30): pg_tde_archive_decrypt
# derives its key directory as `<dir-containing-the-segment>/../pg_tde`
# (pg_tde_fe_archive_common.h:derive_tde_dir_from_segment_path — pure string
# concat, not a real path resolution). That's correct when pg_wal is a plain
# subdirectory of PGDATA (`..` walks back to PGDATA) — which is what every
# earlier pass of this script had, and why none of them ever reproduced the
# bug. But the operator supports a SEPARATE WAL VOLUME (instances[].walVolumeClaimSpec),
# making pg_wal a symlink to a SIBLING of PGDATA (e.g. PGDATA=/pgdata/pg18,
# pg_wal -> /pgdata/pg18_wal). The OS resolves the symlink *during* traversal,
# so `pg_wal/../pg_tde` lands at /pgdata/pg_tde (parent of the WAL volume) —
# the WRONG directory — instead of the real /pgdata/pg18/pg_tde. The tool
# silently misses the actual key state, decrypts garbage, and produces
# exactly the "mismatch of segment size" error. Reproducing that here by
# moving pg_wal out to a sibling directory and symlinking it back, matching
# the operator's actual on-disk layout.
WAL_DIR="$REPRO_ROOT/primary_wal"
mv "$PRIMARY/pg_wal" "$WAL_DIR"
ln -s "$WAL_DIR" "$PRIMARY/pg_wal"
echo "pg_wal is now a symlink to a sibling dir (matches operator's walVolumeClaimSpec layout):"
ls -l "$PRIMARY/pg_wal"

# pgBackRest check/backup require the literal string "pgbackrest" in the
# archive_command GUC (ERROR 068 if only a wrapper script path is set).
# Match pytest BackupManager: decrypt wraps archive-push; %%p survives conf escape.
# Use absolute pgbackrest path so the archiver need not inherit a custom PATH.
INNER_PUSH="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push %%p"
ARCHIVE_CMD="${DECRYPT} %f %p \"${INNER_PUSH}\""

# Optional operator waldump scrape stays in a side script so postgresql.conf
# never sees [0-9] character classes (syntax error near "[").
WALDUMP_SH="$REPRO_ROOT/waldump_sidechain.sh"
cat > "$WALDUMP_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SEGPATH="\${2:?missing %p}"
[[ -x $(printf '%q' "$WALDUMP") ]] || exit 0
timestamp=\$($(printf '%q' "$WALDUMP") -r Transaction "\$SEGPATH" 2>/dev/null \\
  | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \\
  | tail -n1 || true)
if [[ -n "\$timestamp" ]]; then
  echo "\$timestamp" > $(printf '%q' "$REPRO_ROOT/latest_commit_timestamp.txt")
fi
EOF
chmod +x "$WALDUMP_SH"
if [[ "$SKIP_WALDUMP_SIDECHAIN" != "1" && -x "$WALDUMP" ]]; then
  ARCHIVE_CMD="${ARCHIVE_CMD} && ${WALDUMP_SH} %f %p"
fi

# K8SPG-911/PG-2609: pg_tde_archive_decrypt no-ops on unencrypted WAL (it's a
# passthrough unless the LSN range is marked encrypted). The real bug's
# archive_command was ALREADY this wrapped command from the very first start —
# it archived segments 1-8 in harmless passthrough mode, then kept running as
# wal_encrypt flipped on mid-stream for segment 9 onward. Earlier passes of
# this script only installed the wrapper AT the same restart that enabled
# wal_encrypt (archive_command was '/bin/true' before that) and never
# reproduced the mismatch — so this time the wrapper is live from t=0,
# matching the bug's structure exactly instead of approximating it.
cat >> "$PRIMARY/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
port = $P_PORT
unix_socket_directories = '$SOCK'
listen_addresses = '127.0.0.1'
wal_level = logical
max_wal_senders = 10
track_commit_timestamp = on
archive_mode = on
archive_timeout = ${ARCHIVE_TIMEOUT_S:-15}s
archive_command = '${ARCHIVE_CMD}'
# Server log under PGDATA so archive/decrypt failures are easy to inspect.
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

"$PG_CTL" -D "$PRIMARY" -w start
wait_ready

echo
echo "── Stanza-create + let a few plaintext segments archive first (matches bug: ──"
echo "   segments 1-8 archived fine through this same wrapped command before ──"
echo "   wal_encrypt ever turned on) ──"
pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create
sql -c "CREATE TABLE t1(id int primary key, payload text);"
sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(1,2000) g; CHECKPOINT; SELECT pg_switch_wal();" >/dev/null

setup_tde_keys
sql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"

echo
echo "── Prove SIGHUP cannot enable wal_encrypt (bug log line) ──"
sql -c "SELECT pg_reload_conf();" || true
set +e
SHOW_ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
set -e
echo "after reload SHOW pg_tde.wal_encrypt=$SHOW_ENC (expect off until restart)"

# archive_command is ALREADY the wrapped command (installed before first start
# above) — this restart's only real config change is wal_encrypt itself.
"$PG_CTL" -D "$PRIMARY" -w restart
wait_ready
ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after restart SHOW pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || { echo "ERROR: wal_encrypt not on after restart"; exit 1; }
ARCH_CMD=$(sql -Atc "SHOW archive_command")
echo "archive_command=$ARCH_CMD"

echo
echo "── Idle wait — let archive_timeout alone drive the first post-restart"
echo "   segment switch, no manual INSERT/pg_switch_wal(). The bug's log shows"
echo "   a quiet ~70s gap between restart and the first post-restart checkpoint/"
echo "   archive attempt — every previous pass of this script forced immediate"
echo "   manual WAL activity right after the restart instead, which may have"
echo "   let the backend's lazy WAL-key-location persistence (tde_ensure_xlog_key_location()"
echo "   in pg_tde_xlog_smgr.c) complete before the archiver ever saw the segment."

MISMATCH_FOUND=0
for idle_cycle in 1 2 3; do
  sleep "${ARCHIVE_TIMEOUT_S}"
  SERVER_LOG_NOW=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
  if [[ -n "$SERVER_LOG_NOW" ]] && grep -q "mismatch of segment size" "$SERVER_LOG_NOW"; then
    echo "  idle cycle $idle_cycle: REPRODUCED — 'mismatch of segment size' with zero manual WAL activity"
    MISMATCH_FOUND=1
    break
  fi
  echo "  idle cycle $idle_cycle done (no mismatch yet, archive_timeout-driven switches only)"
done

if [[ "$MISMATCH_FOUND" -eq 0 ]]; then
  echo
  echo "── Idle wait alone didn't reproduce it — falling back to sustained WAL"
  echo "   generation across multiple archive_timeout cycles (same as prior passes) ──"
fi
LOAD_END=$(( $(date +%s 2>/dev/null || echo 0) + LOAD_DURATION_S ))
i=0
while [[ "$MISMATCH_FOUND" -eq 0 ]]; do
  i=$((i+1))
  RANGE_START=$(( 2000 + (i-1) * 2000 + 1 ))
  RANGE_END=$(( 2000 + i * 2000 ))
  sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(${RANGE_START},${RANGE_END}) g;" >/dev/null
  sql -c "CHECKPOINT;" >/dev/null
  # Force a switch every cycle instead of waiting purely on archive_timeout —
  # generates the same segment-per-cycle cadence seen in the bug log while
  # keeping the repro's wall-clock bounded.
  sql -c "SELECT pg_switch_wal();" >/dev/null
  sleep "${ARCHIVE_TIMEOUT_S}"
  NOW=$(date +%s 2>/dev/null || echo 0)
  SERVER_LOG_NOW=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
  if [[ -n "$SERVER_LOG_NOW" ]] && grep -q "mismatch of segment size" "$SERVER_LOG_NOW"; then
    echo "  cycle $i: REPRODUCED — 'mismatch of segment size' seen in server log, stopping load loop early"
    break
  fi
  echo "  cycle $i done (no mismatch yet)"
  [[ "$NOW" -ge "$LOAD_END" ]] && break
done

echo
echo "── Manual archive_decrypt on a *completed* segment (not the open one) ──"
CUR=$(sql -Atc "SELECT pg_walfile_name(pg_current_wal_lsn())")
# Only segments strictly before the current open file (lexicographic WAL names
# sort numerically here since they're fixed-width zero-padded hex). No unsafe
# fallback: WAL recycling renames old, already-processed segments into
# preallocated placeholder slots *ahead* of the current file (e.g. …000B
# while current is …000A) — probing one of those isn't a real segment yet
# and produces a false "mismatch of segment size". If nothing qualifies,
# skip the manual probe; the server-log / pgbackrest checks below are the
# authoritative signal (they reflect what the real archiver actually tried).
SEG=$(ls "$PRIMARY/pg_wal" | grep -E '^[0-9A-F]{24}$' | sort | awk -v cur="$CUR" '$0 < cur' | tail -n 1 || true)
echo "current open segment: $CUR"
echo "probing segment:      ${SEG:-<none — no completed segment on disk yet>}"
if [[ -z "$SEG" ]]; then
  echo "NOTE: no completed WAL segment to probe yet — skipping manual probe (not a failure)"
  DEC_RC=0
  : > "$REPRO_ROOT/decrypt.err"
else
  set +e
  "$DECRYPT" "$SEG" "$PRIMARY/pg_wal/$SEG" "cp %p $REPRO_ROOT/decrypted.$SEG" 2>"$REPRO_ROOT/decrypt.err"
  DEC_RC=$?
  set -e
  echo "pg_tde_archive_decrypt exit=$DEC_RC"
  cat "$REPRO_ROOT/decrypt.err" || true
  if grep -q "mismatch of segment size" "$REPRO_ROOT/decrypt.err"; then
    echo
    echo "REPRODUCED (manual FE probe): same error as PG-2609 postgresql.log"
    echo "  Note: this path writes to decrypt.err — it does NOT go through the"
    echo "  archiver, so it will not appear in the server log unless archive_command"
    echo "  hits the same failure (look for 'mismatch of segment size' there)."
  elif [[ "$DEC_RC" -eq 0 ]]; then
    echo "archive_decrypt OK on completed segment (KEY_PROVIDER=$KEY_PROVIDER)"
  elif grep -qiE 'vault|token|permission|failed to|unwrap|http' "$REPRO_ROOT/decrypt.err"; then
    echo "NOTE: decrypt failed with Vault/key access error — check token path / VAULT_ADDR reachability"
  fi
fi

echo
echo "── pgbackrest check + full backup ──"
set +e
pgbackrest --config="$CONF" --stanza="$STANCE" check 2>&1 | tee "$REPRO_ROOT/check.out"
pgbackrest --config="$CONF" --stanza="$STANCE" --type=full backup 2>"$REPRO_ROOT/backup.err" | tee "$REPRO_ROOT/backup.out"
BRC=${PIPESTATUS[0]}
set -e
cat "$REPRO_ROOT/backup.err" || true
if grep -qE 'not archived before|ERROR: \[082\]' "$REPRO_ROOT/backup.out" "$REPRO_ROOT/backup.err" 2>/dev/null; then
  echo
  echo "REPRODUCED: backup timeout waiting for archived WAL (pgbackrest ERROR 082)"
fi

ARCHIVED=$(find "$REPO" -type f -name '000000*' 2>/dev/null | wc -l | tr -d ' ')
echo
echo "── Server log (tail) ──"
SERVER_LOG=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
if [[ -n "$SERVER_LOG" ]]; then
  echo "log file: $SERVER_LOG"
  tail -n 60 "$SERVER_LOG" || true
  if grep -q "mismatch of segment size" "$SERVER_LOG"; then
    echo
    echo "REPRODUCED in server log: pg_tde_archive_decrypt segment-size mismatch"
  fi
  if grep -q 'database "ubuntu" does not exist' "$SERVER_LOG"; then
    echo "NOTE: earlier 'database ubuntu does not exist' is from pgBackRest default DB;"
    echo "      this script now sets pg1-database=postgres / PGDATABASE=postgres."
  fi
else
  echo "(no $PRIMARY/log/postgresql-*.log yet)"
fi

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY"
echo "════════════════════════════════════════════════════════"
echo " KEY_PROVIDER              : $KEY_PROVIDER"
echo " wal_encrypt after restart : $ENC"
echo " archive_decrypt exit      : $DEC_RC"
echo " archived WAL files in repo: $ARCHIVED"
echo " backup exit               : $BRC"
echo " server log                : ${SERVER_LOG:-$PRIMARY/log/}"
echo
echo " Verdict hints:"
echo "  • Default KEY_PROVIDER=openbao uses vault_v2 (operator-like)."
echo "  • Look for 'mismatch of segment size' in decrypt.err / server log."
echo "  • Compare: KEY_PROVIDER=file INSTALL_DIR=... $0"
echo "  • SIGHUP cannot turn on wal_encrypt — restart is required."
echo "  • Full server log: $PRIMARY/log/"
exit 0
