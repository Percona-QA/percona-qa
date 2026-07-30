#!/usr/bin/env bash
#
# PG-2587 — Replica fails after restore with WAL encryption
#
# Jira: https://perconadev.atlassian.net/browse/PG-2587
#
# Reported recipe (Patroni + Percona Operator, 3-node cluster):
#   1. Bootstrap a new cluster with Patroni
#   2. Enable pg_tde
#   3. Enable pg_tde.wal_encrypt
#   4. Create encrypted database and write some data
#   5. CHECKPOINT
#   6. SELECT pg_switch_wal()
#   7. Sleep for archive_timeout seconds
#   8. Create a full backup using pgbackrest
#   9. Restore the full backup using pgbackrest (in place, onto the primary)
#
# After restore, the primary comes back online fine, but replicas fail
# forever with:
#   FATAL:  the database system is starting up
#   LOG:  invalid magic number 1DA0 in WAL segment 00000001000000000000000A, LSN 0/A000000, offset 0
#   LOG:  started streaming WAL from primary at 0/A000000 on timeline 1
#   FATAL:  could not receive data from WAL stream: ERROR:  requested WAL segment
#           00000001000000000000000A has already been removed
#   LOG:  waiting for WAL to become available at 0/A000098
# — repeating every ~5s indefinitely (patroni.log shows this looping for 7+
# minutes straight with no self-recovery), never converging.
#
# Root-cause shape (from the attached logs):
#   - archive_command/restore_command in the failing cluster are PLAIN
#     pgbackrest calls — no pg_tde_archive_decrypt/pg_tde_restore_encrypt
#     wrapper. WAL is shipped to the repo still encrypted end-to-end (this is
#     the "Workaround A" design from PG-2609 — and this bug shows even THAT
#     design has its own failure mode, distinct from PG-2609's decrypt-wrapper
#     race).
#   - An in-place restore onto the primary creates a NEW TIMELINE once
#     recovery reaches consistency and the instance reopens for read/write
#     (patroni.log: "primary_timeline=2" while the replica is still on
#     "Local timeline=1").
#   - The replica needs the OLD-timeline segment (here, …0A) to replay up to
#     the fork point (history: "1  0/B000000"), but the primary has already
#     moved on and no longer serves it via streaming ("has already been
#     removed"), and restore_command apparently never successfully supplies
#     it from the archive either — the replica just spins retrying streaming
#     forever instead of falling back to a working archive-get.
#
# This script drives that exact 9-step recipe against a local primary +
# streaming replica (trust auth, no TLS — irrelevant to the mechanism) and
# watches the replica's log for the same failure signature.
#
# Usage:
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/PG-2587_repro_replica_wal_encrypt_restore.sh
#
#   KEY_PROVIDER=file INSTALL_DIR=... bash ...   # file keyring instead of Vault
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to the PostgreSQL install prefix"
  exit 1
fi

REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2587_repro}}"
PRIMARY="$REPRO_ROOT/primary"
REPLICA="$REPRO_ROOT/replica"
SOCK="$REPRO_ROOT/socket"
SOCK_REPLICA="$REPRO_ROOT/socket_replica"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
KEYFILE="$REPRO_ROOT/keyring.per"
P_PORT="${P_PORT:-25620}"
P_PORT_REPLICA="${P_PORT_REPLICA:-25621}"
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
PG_BASEBACKUP="$BIN/pg_basebackup"
ISREADY="$BIN/pg_isready"
WALDUMP="$BIN/pg_tde_waldump"
PGBR="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB" "$PG_BASEBACKUP"; do
  [[ -x "$b" ]] || { echo "ERROR: missing $b"; exit 1; }
done
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

# initdb creates a superuser matching the OS user (e.g. ubuntu), not "postgres".
# Database name is still "postgres"; do not force -U postgres on clients.
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

cleanup() {
  "$PG_CTL" -D "$REPLICA" -m immediate stop >/dev/null 2>&1 || true
  "$PG_CTL" -D "$PRIMARY" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$REPRO_ROOT"
mkdir -p "$SOCK" "$SOCK_REPLICA" "$REPO" "$REPRO_ROOT/log" "$REPRO_ROOT/log_replica" "$REPRO_ROOT/spool"

echo "════════════════════════════════════════════════════════"
echo " PG-2587 repro — replica fails after restore with WAL encryption"
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

# Matches the bug's ACTUAL archive_command/restore_command: PLAIN pgbackrest
# calls, no pg_tde_archive_decrypt/pg_tde_restore_encrypt wrapper anywhere.
# WAL ships (and is fetched back) still encrypted end-to-end.
ARCHIVE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push \"%p\""
if [[ -x "$WALDUMP" ]]; then
  ARCHIVE_CMD="${ARCHIVE_CMD} && timestamp=\$(${WALDUMP} -r Transaction \"%p\" | grep -oP \"COMMIT \\K[^;]+\" | tail -n 1); if [ ! -z \${timestamp} ]; then echo \${timestamp} > ${REPRO_ROOT}/latest_commit_timestamp.txt; fi"
fi
RESTORE_CMD_PRIMARY="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-get %f \"%p\""
RESTORE_CMD_REPLICA="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${REPLICA} archive-get %f \"%p\""

cat >> "$PRIMARY/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
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
echo "── Step 1-2: bootstrap primary, enable pg_tde ──"
"$PG_CTL" -D "$PRIMARY" -w start
wait_ready "$SOCK" "$P_PORT"
setup_tde_keys

echo
echo "── Step 3: enable pg_tde.wal_encrypt (needs restart) ──"
sql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"
sql -c "SELECT pg_reload_conf();" || true
SHOW_ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after reload SHOW pg_tde.wal_encrypt=$SHOW_ENC (expect off until restart)"
"$PG_CTL" -D "$PRIMARY" -w restart
wait_ready "$SOCK" "$P_PORT"
ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after restart SHOW pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || { echo "ERROR: wal_encrypt not on after restart"; exit 1; }

pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create

echo
echo "── Set up streaming replica ──"
"$PG_BASEBACKUP" -h "$SOCK" -p "$P_PORT" -D "$REPLICA" -U "$PG_SUPERUSER" -Fp -Xs -R -w
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
# pg_basebackup -R writes primary_conninfo pointing at $SOCK/$P_PORT already.
"$PG_CTL" -D "$REPLICA" -w start
wait_ready "$SOCK_REPLICA" "$P_PORT_REPLICA"
REPLICA_LOG=$(ls -1t "$REPLICA/log"/postgresql-*.log 2>/dev/null | head -n1)
for _ in $(seq 1 30); do
  grep -q "started streaming WAL from primary" "$REPLICA_LOG" 2>/dev/null && break
  sleep 1
done
echo "replica streaming: $(grep -c "started streaming WAL from primary" "$REPLICA_LOG" 2>/dev/null || echo 0) connection(s) so far"

echo
echo "── Step 4-7: create encrypted table, write data, checkpoint, switch, wait ──"
sql -c "CREATE TABLE t1(id int primary key, payload text) USING tde_heap;"
sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(1,5000) g;"
sql -c "CHECKPOINT;"
sql -c "SELECT pg_switch_wal();"
sleep "${ARCHIVE_TIMEOUT_S}"

echo
echo "── Step 8: full backup ──"
pgbackrest --config="$CONF" --stanza="$STANCE" --type=full backup

echo
echo "── Step 9: restore in place onto the primary (this is what creates the"
echo "   new timeline once it reopens for read/write, per the bug report) ──"
"$PG_CTL" -D "$PRIMARY" -w -m fast stop
pgbackrest --config="$CONF" --stanza="$STANCE" --pg1-path="$PRIMARY" --delta restore
"$PG_CTL" -D "$PRIMARY" -w start
wait_ready "$SOCK" "$P_PORT"
echo "primary back online after restore."

echo
echo "── Watching replica for the PG-2587 failure signature (up to 2 min) ──"
FOUND=0
for _ in $(seq 1 24); do
  sleep 5
  if grep -qE "invalid magic number|has already been removed" "$REPLICA_LOG" 2>/dev/null; then
    FOUND=1
    break
  fi
done

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY"
echo "════════════════════════════════════════════════════════"
if [[ "$FOUND" -eq 1 ]]; then
  echo " REPRODUCED — replica log shows the PG-2587 signature:"
  grep -E "invalid magic number|has already been removed|new target timeline|waiting for WAL to become available" "$REPLICA_LOG" | tail -20
else
  echo " NOT reproduced this pass — replica log tail:"
  tail -n 40 "$REPLICA_LOG" 2>/dev/null || true
fi
echo
echo " Replica log: $REPLICA_LOG"
echo " Primary log: $(ls -1t "$PRIMARY/log"/postgresql-*.log 2>/dev/null | head -n1)"
exit 0
