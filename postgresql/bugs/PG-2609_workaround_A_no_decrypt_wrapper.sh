#!/usr/bin/env bash
#
# PG-2609 — Workaround A: skip pg_tde_archive_decrypt / pg_tde_restore_encrypt
# entirely and let WAL stay encrypted end-to-end (on primary disk *and* in the
# pgBackRest repo). Only the running Postgres backend ever decrypts it, via the
# same code path it already uses to replay its own local encrypted WAL.
#
# Jira: https://perconadev.atlassian.net/browse/PG-2609
#
# Why this avoids the bug:
#   The "mismatch of segment size" failure comes from pg_tde_archive_decrypt —
#   a standalone binary spawned once per WAL segment by archive_command — reading
#   WAL-key history from disk independently of the live backend
#   (pg_tde_fetch_wal_keys() in pg_tde_xlog_smgr.c). That's a race against the
#   backend's own WAL-key materialization right after a wal_encrypt-enabling
#   restart. Removing the decrypt/re-encrypt wrapper removes that whole race:
#   there is no separate process reading WAL-key state at all.
#
#   This matches the *current in-progress design direction* on the operator's
#   own K8SPG-911-wal-encryption branch: commit 2ba84735d ("tde_archive_decrypt")
#   added the pg_tde_archive_decrypt wrapper; the very next commit, 56d6c503b
#   ("full WAL encryption"), removed it again in favor of shipping WAL still
#   encrypted — i.e. exactly this approach.
#
# What this script proves:
#   1. archive_command/restore_command are PLAIN pgbackrest calls (no pg_tde_*
#      wrapper) with pg_tde.wal_encrypt=on the whole time.
#   2. Sustained WAL generation + full backup succeed with zero decrypt errors
#      (there's nothing to decrypt at archive time — nothing CAN mismatch).
#   3. A real restore into a fresh data directory replays the (still-encrypted)
#      WAL correctly and comes up clean — proving the backend's normal WAL-read
#      path handles decryption on its own, no separate re-encrypt step needed.
#
# Usage (OpenBao — default, matches operator Vault path):
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/PG-2609_workaround_A_no_decrypt_wrapper.sh
#
#   KEY_PROVIDER=file INSTALL_DIR=... bash ...   # file keyring instead of Vault
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to the PostgreSQL install prefix"
  exit 1
fi

# Do not name this ROOT — OpenBao root token must not clobber the workdir path.
REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2609_workaroundA}}"
PRIMARY="$REPRO_ROOT/primary"
RESTORED="$REPRO_ROOT/restored"
SOCK="$REPRO_ROOT/socket"
SOCK_RESTORED="$REPRO_ROOT/socket_restored"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
CONF_RESTORED="$REPRO_ROOT/pgbackrest_restored.conf"
KEYFILE="$REPRO_ROOT/keyring.per"
P_PORT="${P_PORT:-25610}"
P_PORT_RESTORED="${P_PORT_RESTORED:-25611}"
STANCE="db"
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
PGBR="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB"; do
  [[ -x "$b" ]] || { echo "ERROR: missing $b"; exit 1; }
done
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

export PGDATABASE=postgres
sql() { "$PSQL" -h "$SOCK" -p "$P_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"; }
sql_restored() { "$PSQL" -h "$SOCK_RESTORED" -p "$P_PORT_RESTORED" -d postgres -v ON_ERROR_STOP=1 "$@"; }

wait_ready() {
  local sock="$1" port="$2"
  for _ in $(seq 1 90); do
    "$ISREADY" -h "$sock" -p "$port" -d postgres >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: not ready ($sock:$port)"; exit 1
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
  local target_sql_fn="$1"
  $target_sql_fn -c "CREATE EXTENSION pg_tde;"
  KEY_NAME="global-master-key-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  case "$KEY_PROVIDER" in
    file)
      $target_sql_fn -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
      $target_sql_fn -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      $target_sql_fn -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
      PROVIDER_NAME="file_provider"
      ;;
    openbao|vault)
      ensure_openbao_env
      if [[ -n "$VAULT_NS" ]]; then
        $target_sql_fn -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL,'$VAULT_NS');"
      else
        $target_sql_fn -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$VAULT_TOKEN_PATH',NULL);"
      fi
      $target_sql_fn -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
      $target_sql_fn -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
      PROVIDER_NAME="vault-provider"
      ;;
    *)
      echo "ERROR: KEY_PROVIDER must be openbao, vault, or file (got: $KEY_PROVIDER)"
      exit 1
      ;;
  esac
  echo " using provider: $PROVIDER_NAME (key: $KEY_NAME)"
}

cleanup() {
  "$PG_CTL" -D "$RESTORED" -m immediate stop >/dev/null 2>&1 || true
  "$PG_CTL" -D "$PRIMARY" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$REPRO_ROOT"
mkdir -p "$SOCK" "$SOCK_RESTORED" "$REPO" "$REPRO_ROOT/log" "$REPRO_ROOT/spool"

echo "════════════════════════════════════════════════════════"
echo " PG-2609 Workaround A — no decrypt/re-encrypt wrapper"
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
archive_mode = on
archive_timeout = 15s
archive_command = '/bin/true'
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
wait_ready "$SOCK" "$P_PORT"
setup_tde_keys sql
sql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"

pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create

# The whole point of workaround A: PLAIN archive_command/restore_command, no
# pg_tde_archive_decrypt / pg_tde_restore_encrypt wrapper anywhere. Single %p,
# not %%p, since there's no wrapper consuming the escape.
ARCHIVE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push %p"
echo "archive_command = '${ARCHIVE_CMD}'" >> "$PRIMARY/postgresql.auto.conf"
"$PG_CTL" -D "$PRIMARY" -w restart
wait_ready "$SOCK" "$P_PORT"
ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after restart SHOW pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || { echo "ERROR: wal_encrypt not on after restart"; exit 1; }
ARCH_CMD=$(sql -Atc "SHOW archive_command")
echo "archive_command=$ARCH_CMD"

echo
echo "── Sustained WAL generation (same cadence as the PG-2609 repro) ──"
sql -c "CREATE TABLE t1(id int primary key, payload text) USING tde_heap;"
for i in $(seq 1 6); do
  RANGE_START=$(( (i-1) * 2000 + 1 ))
  RANGE_END=$(( i * 2000 ))
  sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(${RANGE_START},${RANGE_END}) g;" >/dev/null
  sql -c "CHECKPOINT; SELECT pg_switch_wal();" >/dev/null
  sleep 15
  echo "  cycle $i done"
done
ROWS_BEFORE=$(sql -Atc "SELECT count(*) FROM t1;")
echo "rows inserted: $ROWS_BEFORE"

echo
echo "── pgbackrest check + full backup ──"
set +e
pgbackrest --config="$CONF" --stanza="$STANCE" check 2>&1 | tee "$REPRO_ROOT/check.out"
pgbackrest --config="$CONF" --stanza="$STANCE" --type=full backup 2>"$REPRO_ROOT/backup.err" | tee "$REPRO_ROOT/backup.out"
BRC=${PIPESTATUS[0]}
set -e
cat "$REPRO_ROOT/backup.err" || true

SERVER_LOG=$(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1 || true)
DECRYPT_ERRORS=0
if [[ -n "$SERVER_LOG" ]] && grep -qiE "pg_tde_archive_decrypt|mismatch of segment size" "$SERVER_LOG"; then
  DECRYPT_ERRORS=1
fi

echo
echo "── Restore into a fresh data directory (proves decrypt-on-replay works) ──"
mkdir -p "$REPRO_ROOT/spool_restored"
cat > "$CONF_RESTORED" <<EOF
[global]
repo1-path=$REPO
log-level-console=info
log-level-file=detail
log-path=$REPRO_ROOT/log
spool-path=$REPRO_ROOT/spool_restored

[$STANCE]
pg1-path=$RESTORED
pg1-port=$P_PORT_RESTORED
pg1-socket-path=$SOCK_RESTORED
pg1-database=postgres
EOF

pgbackrest --config="$CONF_RESTORED" --stanza="$STANCE" --pg1-path="$RESTORED" restore
# Plain restore_command here too — no pg_tde_restore_encrypt. The backend
# decrypts WAL on replay via its normal (already-key-aware) read path.
cat >> "$RESTORED/postgresql.conf" <<EOF
port = $P_PORT_RESTORED
unix_socket_directories = '$SOCK_RESTORED'
listen_addresses = '127.0.0.1'
restore_command = '${PGBR} --config=${CONF_RESTORED} --stanza=${STANCE} --pg1-path=${RESTORED} archive-get %f "%p"'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
EOF
mkdir -p "$RESTORED/log"

"$PG_CTL" -D "$RESTORED" -w start
wait_ready "$SOCK_RESTORED" "$P_PORT_RESTORED"
ROWS_AFTER=$(sql_restored -Atc "SELECT count(*) FROM t1;" 2>&1 || echo "QUERY_FAILED")
echo "rows after restore+replay: $ROWS_AFTER (expected: $ROWS_BEFORE)"

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY — Workaround A (no decrypt/re-encrypt wrapper)"
echo "════════════════════════════════════════════════════════"
echo " wal_encrypt                : $ENC"
echo " archive_command            : $ARCH_CMD"
echo " decrypt/mismatch errors    : $([[ $DECRYPT_ERRORS -eq 0 ]] && echo "NONE (expected)" || echo "FOUND (unexpected — investigate)")"
echo " backup exit                : $BRC"
echo " rows before backup         : $ROWS_BEFORE"
echo " rows after restore+replay  : $ROWS_AFTER"
if [[ "$ROWS_AFTER" == "$ROWS_BEFORE" && $DECRYPT_ERRORS -eq 0 ]]; then
  echo
  echo " PASS: WAL stayed encrypted end-to-end, archived and restored cleanly,"
  echo "       and the backend decrypted it correctly on replay with no"
  echo "       standalone decrypt/re-encrypt step in the loop."
else
  echo
  echo " FAIL: check backup.out/backup.err and $SERVER_LOG"
fi
exit 0
