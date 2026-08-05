#!/usr/bin/env bash

# Usage:
#   INSTALL_DIR=/usr/lib/postgresql/18 \
#     bash postgresql/bugs/PG-2609_repro_wal_encrypt_pgbackrest_file.sh
#
#   SKIP_WALDUMP_SIDECHAIN=1 INSTALL_DIR=... bash ...
#
set -euo pipefail

# OS-aware default INSTALL_DIR (Ubuntu: /usr/lib/postgresql/N, RHEL: /usr/pgsql-N)
# shellcheck source=pg_install_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_install_env.sh"

REPRO_ROOT="${REPRO_ROOT:-${ROOT:-/tmp/PG-2609_repro_file}}"
PRIMARY="$REPRO_ROOT/primary"
SOCK="$REPRO_ROOT/socket"
REPO="$REPRO_ROOT/repo"
CONF="$REPRO_ROOT/pgbackrest.conf"
KEYFILE="$REPRO_ROOT/keyring.per"
P_PORT="${P_PORT:-25619}"
STANCE="db"
SKIP_WALDUMP_SIDECHAIN="${SKIP_WALDUMP_SIDECHAIN:-0}"

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

export PGDATABASE=postgres
export PGHOST="$SOCK"
export PGPORT="$P_PORT"

sql() { "$PSQL" -h "$SOCK" -p "$P_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"; }

wait_ready() {
  for _ in $(seq 1 90); do
    "$ISREADY" -h "$SOCK" -p "$P_PORT" -d postgres >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: not ready"; exit 1
}

setup_tde_keys() {
  echo "── KEY_PROVIDER=file (file keyring) ──"
  sql -c "CREATE EXTENSION pg_tde;"
  sql -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
  sql -c "SELECT pg_tde_create_key_using_global_key_provider('k1', 'file_provider');"
  sql -c "SELECT pg_tde_set_server_key_using_global_key_provider('k1', 'file_provider');"
  sql -c "SELECT pg_tde_set_key_using_global_key_provider('k1', 'file_provider');"
}

cleanup() { "$PG_CTL" -D "$PRIMARY" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

rm -rf "$REPRO_ROOT"
mkdir -p "$SOCK" "$REPO" "$REPRO_ROOT/log" "$REPRO_ROOT/spool"

echo "════════════════════════════════════════════════════════"
echo " PG-2609 repro (file keyring) — archive_decrypt + backup"
echo " INSTALL_DIR=$INSTALL_DIR"
echo " REPRO_ROOT=$REPRO_ROOT"
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

# pgBackRest requires the literal string "pgbackrest" in archive_command (ERROR 068).
INNER_PUSH="${PGBR} --config=${CONF} --stanza=${STANCE} --pg1-path=${PRIMARY} archive-push %%p"
ARCHIVE_CMD="${DECRYPT} %f %p \"${INNER_PUSH}\""

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

cat >> "$PRIMARY/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_tde'
port = $P_PORT
unix_socket_directories = '$SOCK'
listen_addresses = '127.0.0.1'
wal_level = replica
max_wal_senders = 5
archive_mode = on
archive_timeout = 10s
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
wait_ready
setup_tde_keys
sql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"

echo
echo "── Prove SIGHUP cannot enable wal_encrypt ──"
sql -c "SELECT pg_reload_conf();" || true
set +e
SHOW_ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
set -e
echo "after reload SHOW pg_tde.wal_encrypt=$SHOW_ENC (expect off until restart)"

pgbackrest --config="$CONF" --stanza="$STANCE" stanza-create

echo "archive_command = '${ARCHIVE_CMD}'" >> "$PRIMARY/postgresql.auto.conf"
"$PG_CTL" -D "$PRIMARY" -w restart
wait_ready
ENC=$(sql -Atc "SHOW pg_tde.wal_encrypt")
echo "after restart SHOW pg_tde.wal_encrypt=$ENC"
[[ "$ENC" == "on" ]] || { echo "ERROR: wal_encrypt not on after restart"; exit 1; }
ARCH_CMD=$(sql -Atc "SHOW archive_command")
echo "archive_command=$ARCH_CMD"

echo
echo "── Force WAL segment switch + archive ──"
sql -c "CREATE TABLE t1(id int primary key, payload text) USING tde_heap;"
sql -c "INSERT INTO t1 SELECT g, repeat('x',200) FROM generate_series(1,5000) g;"
sql -c "CHECKPOINT; SELECT pg_switch_wal();"
sleep 2
sql -c "INSERT INTO t1 SELECT g, repeat('y',200) FROM generate_series(5001,10000) g;"
sql -c "CHECKPOINT; SELECT pg_switch_wal();"
sleep 3

echo
echo "── Manual archive_decrypt on a completed segment ──"
CUR=$(sql -Atc "SELECT pg_walfile_name(pg_current_wal_lsn())")
# Only completed segments strictly before the current open file.
SEG=$(ls "$PRIMARY/pg_wal" | grep -E '^[0-9A-F]{24}$' | sort | awk -v cur="$CUR" '$0 < cur' | tail -n 1 || true)
if [[ -z "$SEG" ]]; then
  SEG=$(ls "$PRIMARY/pg_wal" | grep -E '^[0-9A-F]{24}$' | sort | grep -v "^${CUR}$" | tail -n 1 || true)
fi
echo "current open segment: $CUR"
echo "probing segment:      $SEG"
set +e
"$DECRYPT" "$SEG" "$PRIMARY/pg_wal/$SEG" "cp %p $REPRO_ROOT/decrypted.$SEG" 2>"$REPRO_ROOT/decrypt.err"
DEC_RC=$?
set -e
echo "pg_tde_archive_decrypt exit=$DEC_RC"
cat "$REPRO_ROOT/decrypt.err" || true
if grep -q "mismatch of segment size" "$REPRO_ROOT/decrypt.err"; then
  echo
  echo "REPRODUCED: same error as PG-2609 postgresql.log"
elif [[ "$DEC_RC" -eq 0 ]]; then
  echo "archive_decrypt OK on completed segment (file keyring)"
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
else
  echo "(no $PRIMARY/log/postgresql-*.log yet)"
fi

echo
echo "════════════════════════════════════════════════════════"
echo " SUMMARY"
echo "════════════════════════════════════════════════════════"
echo " KEY_PROVIDER              : file"
echo " wal_encrypt after restart : $ENC"
echo " archive_decrypt exit      : $DEC_RC"
echo " archived WAL files in repo: $ARCHIVED"
echo " backup exit               : $BRC"
echo " server log                : ${SERVER_LOG:-$PRIMARY/log/}"
echo
echo " Verdict hints:"
echo "  • File keyring path is for local/dev; often decrypt+backup succeed."
echo "  • Operator/Vault repro: PG-2609_repro_wal_encrypt_pgbackrest_ha.sh"
echo "  • SIGHUP cannot turn on wal_encrypt — restart is required."
echo "  • Full server log: $PRIMARY/log/"
exit 0
