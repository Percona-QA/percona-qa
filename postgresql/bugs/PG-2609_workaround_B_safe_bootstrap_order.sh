#!/usr/bin/env bash
#
# PG-2609 — Workaround B: keep pg_tde_archive_decrypt/pg_tde_restore_encrypt
# (matches the published walkthrough:
#  https://percona.community/blog/2026/03/10/running-pgbackrest-with-pg_tde-a-practical-percona-walkthrough/)
# but fix the *sequencing* so the wal_encrypt-enabling restart never overlaps
# with pgBackRest archiving/backup activity.
#
# Jira: https://perconadev.atlassian.net/browse/PG-2609
#
# The bug's own docs already warn about this (community blog, "Critical
# warnings" section): "While a backup is running, you should not change any
# WAL encryption settings, including: ... The pg_tde.wal_encrypt setting."
# Nothing in Patroni or the operator's reconcile loop enforces that — the
# PG-2609 environment flipped wal_encrypt via a live restart on a cluster
# whose stanza already existed and was already archiving.
#
# This script sequences it the safe way instead:
#   1. initdb, start with archive_mode=off (nothing can archive yet at all).
#   2. Set up pg_tde keys (Vault/OpenBao).
#   3. ONE restart that simultaneously flips wal_encrypt=on *and* installs the
#      wrapped archive_command/restore_command — before any stanza exists and
#      before a single WAL segment has ever been archived. There is no window
#      where "backup activity" and "wal_encrypt transition" can overlap,
#      because backup activity is structurally impossible until this step
#      completes.
#   4. Only *after* that restart is confirmed stable: pgbackrest stanza-create,
#      then normal archiving/backups begin.
#
# Usage:
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/PG-2609_workaround_B_safe_bootstrap_order.sh
#
#   KEY_PROVIDER=file INSTALL_DIR=... bash ...   # file keyring instead of Vault
#
set -euo pipefail

# OS-aware default INSTALL_DIR (Ubuntu: /usr/lib/postgresql/N, RHEL: /usr/pgsql-N)
# shellcheck source=pg_install_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_install_env.sh"

REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2609_workaroundB}}"
PRIMARY="$REPRO_ROOT/primary"
SOCK="$REPRO_ROOT/socket"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
KEYFILE="$REPRO_ROOT/keyring.per"
P_PORT="${P_PORT:-25612}"
STANCE="db"
ARCHIVE_TIMEOUT_S="${ARCHIVE_TIMEOUT_S:-15}"
KEY_PROVIDER="${KEY_PROVIDER:-openbao}"
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
RESTORE_ENC="$BIN/pg_tde_restore_encrypt"
WALDUMP="$BIN/pg_tde_waldump"
PGBR="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB" "$DECRYPT"; do
  [[ -x "$b" ]] || { echo "ERROR: missing $b"; exit 1; }
done
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }
[[ -x "$RESTORE_ENC" ]] || echo "NOTE: pg_tde_restore_encrypt not found — restore_command will stay plain archive-get"

export PGDATABASE=postgres
sql() { "$PSQL" -h "$SOCK" -p "$P_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"; }

wait_ready() {
  for _ in $(seq 1 90); do
    "$ISREADY" -h "$SOCK" -p "$P_PORT" -d postgres >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: not ready"; exit 1
}

ensure_openbao_env() {
  mkdir -p "$REPRO_ROOT"
  OPENBAO_RUN_DIR="${OPENBAO_RUN_DIR:-$REPRO_ROOT/openbao}"
  pg2609_ensure_openbao || exit 1

  VAULT_URL="${VAULT_ADDR%/}"
  VAULT_MOUNT="${VAULT_SECRET_MOUNT:-pg_tde}"
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
}

setup_tde_keys() {
  sql -c "CREATE EXTENSION pg_tde;"
  KEY_NAME="global-master-key-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  case "$KEY_PROVIDER" in
    file)
      sql -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
      sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      PROVIDER_NAME="file_provider"
      ;;
    openbao|vault)
      ensure_openbao_env
      if [[ -n "$VAULT_NS" ]]; then
        sql -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL,'$VAULT_NS');"
      else
        sql -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL);"
      fi
      sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
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
echo " PG-2609 Workaround B — safe bootstrap ordering"
echo " (wal_encrypt transition happens strictly BEFORE any archiving/backup"
echo "  activity exists, instead of on an already-archiving live cluster)"
echo " INSTALL_DIR=$INSTALL_DIR  REPRO_ROOT=$REPRO_ROOT  KEY_PROVIDER=$KEY_PROVIDER"
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

cat >> "$PRIMARY/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
port = $P_PORT
unix_socket_directories = '$SOCK'
listen_addresses = '127.0.0.1'
wal_level = logical
max_wal_senders = 10
track_commit_timestamp = on
# Step 1: archiving is OFF. No stanza, no backup, no archive-push can happen
# at all yet — there is nothing for a wal_encrypt transition to race against.
archive_mode = off
archive_timeout = ${ARCHIVE_TIMEOUT_S}s
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
echo "── Step 2: set up pg_tde keys (archive_mode still off) ──"
setup_tde_keys

INNER_PUSH="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push %%p"
ARCHIVE_CMD="${DECRYPT} %f %p \"${INNER_PUSH}\""
RESTORE_CMD_INNER="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-get %%f \\\"%%p\\\""
if [[ -x "$RESTORE_ENC" ]]; then
  RESTORE_CMD="${RESTORE_ENC} %f %p \"${RESTORE_CMD_INNER}\""
else
  RESTORE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-get %f \"%p\""
fi

echo
echo "── Step 3: ONE restart — flips wal_encrypt on AND installs the wrapped"
echo "   archive_command/restore_command simultaneously, before stanza-create ──"
sql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"
sql -c "ALTER SYSTEM SET archive_mode = on;"
{
  echo "archive_command = '${ARCHIVE_CMD}'"
  echo "restore_command = '${RESTORE_CMD}'"
} >> "$PRIMARY/postgresql.auto.conf"
"$PG_CTL" -D "$PRIMARY" -w restart
wait_ready
ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after restart SHOW pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || { echo "ERROR: wal_encrypt not on after restart"; exit 1; }
ARCH_CMD=$(sql -Atc "SHOW archive_command")
echo "archive_command=$ARCH_CMD"

echo
echo "── Step 4: only NOW does the stanza exist / can archiving begin ──"
pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create

echo
echo "── Sustained WAL generation (same cadence as the PG-2609 repro) ──"
sql -c "CREATE TABLE t1(id int primary key, payload text) USING tde_heap;"
for i in $(seq 1 6); do
  RANGE_START=$(( (i-1) * 2000 + 1 ))
  RANGE_END=$(( i * 2000 ))
  sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(${RANGE_START},${RANGE_END}) g;" >/dev/null
  sql -c "CHECKPOINT; SELECT pg_switch_wal();" >/dev/null
  sleep "${ARCHIVE_TIMEOUT_S}"
  SERVER_LOG_NOW=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
  if [[ -n "$SERVER_LOG_NOW" ]] && grep -q "mismatch of segment size" "$SERVER_LOG_NOW"; then
    echo "  cycle $i: UNEXPECTED — 'mismatch of segment size' seen despite safe ordering"
    break
  fi
  echo "  cycle $i done (no mismatch)"
done

echo
echo "── pgbackrest check + full backup ──"
set +e
pgbackrest --config="$CONF" --stanza="$STANCE" check 2>&1 | tee "$REPRO_ROOT/check.out"
pgbackrest --config="$CONF" --stanza="$STANCE" --type=full backup 2>"$REPRO_ROOT/backup.err" | tee "$REPRO_ROOT/backup.out"
BRC=${PIPESTATUS[0]}
set -e
cat "$REPRO_ROOT/backup.err" || true

SERVER_LOG=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
MISMATCH=0
if [[ -n "$SERVER_LOG" ]] && grep -q "mismatch of segment size" "$SERVER_LOG"; then
  MISMATCH=1
fi

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY — Workaround B (safe bootstrap ordering)"
echo "════════════════════════════════════════════════════════"
echo " wal_encrypt                : $ENC"
echo " archive_command            : $ARCH_CMD"
echo " mismatch of segment size   : $([[ $MISMATCH -eq 0 ]] && echo "NONE (expected)" || echo "FOUND (unexpected — investigate)")"
echo " backup exit                : $BRC"
if [[ $MISMATCH -eq 0 && "$BRC" -eq 0 ]]; then
  echo
  echo " PASS: wal_encrypt was enabled (and the decrypt wrapper installed)"
  echo "       strictly before any stanza/archiving/backup activity existed —"
  echo "       no transition raced against pgBackRest, no mismatch."
else
  echo
  echo " FAIL: check backup.out/backup.err and $SERVER_LOG"
fi
exit 0
