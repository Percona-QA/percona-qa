#!/bin/bash
#
# Failback lab: pg_tde.wal_encrypt + pgBackRest wrappers + pg_tde_rewind -c
#
# Covered in pytest by:
#   tests/test_pg_tde_pgbackrest.py::TestPgBackRestReplicationAndRewind::
#   test_pgbackrest_restore_then_tde_rewind_failback
#
# Archive / restore pattern (Percona walkthrough):
#   https://percona.community/blog/2026/03/10/running-pgbackrest-with-pg_tde-a-practical-percona-walkthrough/
#
#   archive_command =
#     pg_tde_archive_decrypt %f %p "pgbackrest --config=... --stanza=... archive-push %%p"
#
#   restore (sets restore_command via --recovery-option):
#     pgbackrest ... restore \
#       --recovery-option=restore_command='pg_tde_restore_encrypt %f %p "pgbackrest ... archive-get %%f %%p"'
#
# Usage:
#   INSTALL_DIR=/path/to/pg/install bash postgresql/bugs/pgbackrest_tde_rewind_failback.sh
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to the PostgreSQL install prefix"
  exit 1
fi

PSQL="$INSTALL_DIR/bin/psql"
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
INITDB="$INSTALL_DIR/bin/initdb"
PG_ISREADY="$INSTALL_DIR/bin/pg_isready"
PG_BASEBACKUP="$INSTALL_DIR/bin/pg_tde_basebackup"
PG_REWIND="$INSTALL_DIR/bin/pg_tde_rewind"
DECRYPT="$INSTALL_DIR/bin/pg_tde_archive_decrypt"
ENCRYPT="$INSTALL_DIR/bin/pg_tde_restore_encrypt"
PGBACKREST="$(command -v pgbackrest || true)"

for b in "$PSQL" "$PG_CTL" "$INITDB" "$PG_BASEBACKUP" "$PG_REWIND" "$DECRYPT" "$ENCRYPT"; do
  [[ -x "$b" ]] || { echo "ERROR: missing executable: $b"; exit 1; }
done
[[ -n "$PGBACKREST" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

ROOT="${ROOT:-/tmp/pgbackrest_tde_rewind_failback}"
PRIMARY_DATA="$ROOT/primary"
REPLICA_DATA="$ROOT/replica"
SOCKET_DIR="$ROOT/socket"
REPO="$ROOT/pgbackrest_repo"
CONF="$ROOT/pgbackrest.conf"
KEYFILE="$ROOT/keyring.file"
PRIMARY_PORT="${PRIMARY_PORT:-55432}"
REPLICA_PORT="${REPLICA_PORT:-55433}"
STANCE="demo"

sql() {
  local port=$1; shift
  "$PSQL" -h "$SOCKET_DIR" -p "$port" -d postgres -v ON_ERROR_STOP=1 "$@"
}

wait_ready() {
  local port=$1
  for _ in $(seq 1 60); do
    "$PG_ISREADY" -h "$SOCKET_DIR" -p "$port" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "ERROR: port $port not ready"
  exit 1
}

wait_not_in_recovery() {
  local port=$1
  for _ in $(seq 1 120); do
    local r
    r=$(sql "$port" -Atc "SELECT pg_is_in_recovery()" 2>/dev/null || echo t)
    [[ "$r" == "f" ]] && return 0
    sql "$port" -c "SELECT pg_promote(wait := true, wait_seconds := 15);" >/dev/null 2>&1 || true
    sleep 1
  done
  echo "ERROR: port $port still in recovery"
  exit 1
}

write_pgbackrest_conf() {
  local pgdata=$1 port=$2
  mkdir -p "$REPO" "$REPO/logs" "$REPO/lock" "$REPO/spool"
  # Walkthrough: compress-type=none (encrypted pages don't compress).
  # checksum-page=n: needed for tde_heap pages in this lab.
  cat > "$CONF" <<EOF
[$STANCE]
pg1-path=$pgdata
pg1-port=$port
pg1-socket-path=$SOCKET_DIR

[global]
repo1-path=$REPO
repo1-retention-full=2
log-path=$REPO/logs
lock-path=$REPO/lock
spool-path=$REPO/spool
log-level-console=info
start-fast=y
compress-type=none
checksum-page=n
EOF
  chmod 600 "$CONF"
}

# Walkthrough archive_command (%% → literal % for the wrapper).
archive_command() {
  echo "$DECRYPT %f %p \"$PGBACKREST --config=$CONF --stanza=$STANCE archive-push %%p\""
}

# Walkthrough restore_command string (used with --recovery-option on restore,
# and in postgresql.conf so pg_tde_rewind -c can fetch WAL).
restore_command() {
  echo "$ENCRYPT %f %p \"$PGBACKREST --config=$CONF --stanza=$STANCE archive-get %%f %%p\""
}

write_primary_conf() {
  local data=$1 port=$2
  local arch rest
  arch="$(archive_command)"
  rest="$(restore_command)"
  cat > "$data/postgresql.conf" <<EOF
port = $port
unix_socket_directories = '$SOCKET_DIR'
listen_addresses = '*'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
wal_level = replica
max_wal_senders = 4
wal_log_hints = on
hot_standby = on
wal_keep_size = '128MB'
archive_mode = on
archive_timeout = 5s
archive_command = '$arch'
restore_command = '$rest'
logging_collector = on
log_directory = '$data'
log_filename = 'server.log'
include_if_exists = 'postgresql.auto.conf'
EOF
  cat > "$data/pg_hba.conf" <<EOF
local all all trust
local replication all trust
host all all 127.0.0.1/32 trust
host replication all 127.0.0.1/32 trust
EOF
}

# wipe + restore with --recovery-option=restore_command=...
pgbackrest_restore_into() {
  local dest=$1
  local rest
  rest="$(restore_command)"
  echo "Walkthrough-style restore:"
  echo "  pgbackrest --config=$CONF --stanza=$STANCE --pg1-path=$dest restore \\"
  echo "    --recovery-option=restore_command='${rest}'"
  find "$dest" -mindepth 1 -delete
  "$PGBACKREST" \
    --config="$CONF" \
    --stanza="$STANCE" \
    --pg1-path="$dest" \
    --recovery-option="restore_command=${rest}" \
    restore
}

cleanup() {
  "$PG_CTL" -D "$PRIMARY_DATA" stop -m immediate >/dev/null 2>&1 || true
  "$PG_CTL" -D "$REPLICA_DATA" stop -m immediate >/dev/null 2>&1 || true
  "$PG_CTL" -D "$ROOT/restored" stop -m immediate >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$ROOT"
mkdir -p "$SOCKET_DIR"

#############################################
# 1. Primary (walkthrough archive_command)
#############################################
echo "== 1) Init primary + pg_tde + wal_encrypt =="
"$INITDB" -D "$PRIMARY_DATA" --no-data-checksums >/dev/null
write_pgbackrest_conf "$PRIMARY_DATA" "$PRIMARY_PORT"
write_primary_conf "$PRIMARY_DATA" "$PRIMARY_PORT"

"$PG_CTL" -D "$PRIMARY_DATA" -w start >/dev/null
wait_ready "$PRIMARY_PORT"

sql "$PRIMARY_PORT" -c "CREATE EXTENSION pg_tde;"
sql "$PRIMARY_PORT" -c "SELECT pg_tde_add_global_key_provider_file('global-file-provider','$KEYFILE');"
sql "$PRIMARY_PORT" -c "SELECT pg_tde_create_key_using_global_key_provider('global-master-key','global-file-provider');"
sql "$PRIMARY_PORT" -c "SELECT pg_tde_set_default_key_using_global_key_provider('global-master-key','global-file-provider');"
sql "$PRIMARY_PORT" -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';"
"$PG_CTL" -D "$PRIMARY_DATA" -w restart >/dev/null
wait_ready "$PRIMARY_PORT"
sql "$PRIMARY_PORT" -c "SHOW pg_tde.wal_encrypt;"

"$PGBACKREST" --config="$CONF" --stanza="$STANCE" stanza-create

#############################################
# 2. Replica
#############################################
echo "== 2) Create replica (pg_tde_basebackup -E) =="
mkdir -p "$REPLICA_DATA"
chmod 700 "$REPLICA_DATA"
cp -a "$PRIMARY_DATA/pg_tde" "$REPLICA_DATA/"
"$PG_BASEBACKUP" -D "$REPLICA_DATA" -R -X stream -c fast -E \
  -h "$SOCKET_DIR" -p "$PRIMARY_PORT"

write_primary_conf "$REPLICA_DATA" "$REPLICA_PORT"
# Keep standby.signal / primary_conninfo from -R (do not rewrite auto.conf).

"$PG_CTL" -D "$REPLICA_DATA" -w start >/dev/null
wait_ready "$REPLICA_PORT"
sql "$REPLICA_PORT" -c "SELECT pg_is_in_recovery();"
sql "$PRIMARY_PORT" -c "SELECT application_name, state FROM pg_stat_replication;"

#############################################
# 3. Workload + full backup
#############################################
echo "== 3) Workload + full backup =="
sql "$PRIMARY_PORT" <<'SQL'
CREATE TABLE rw_t (id INT PRIMARY KEY, marker TEXT, payload TEXT) USING tde_heap;
INSERT INTO rw_t SELECT i, 'shared', md5(i::text) FROM generate_series(1, 40) i;
CHECKPOINT;
SELECT pg_switch_wal();
SQL
sleep 3
"$PGBACKREST" --config="$CONF" --stanza="$STANCE" --type=full backup
"$PGBACKREST" --config="$CONF" --stanza="$STANCE" info

#############################################
# 4. Promote replica → new primary
#############################################
echo "== 4) Promote replica =="
sql "$REPLICA_PORT" -c "SELECT pg_promote(wait := true, wait_seconds := 60);"
wait_ready "$REPLICA_PORT"
wait_not_in_recovery "$REPLICA_PORT"
sql "$REPLICA_PORT" -c "INSERT INTO rw_t VALUES (9101, 'new_primary', md5('np'));"

write_pgbackrest_conf "$REPLICA_DATA" "$REPLICA_PORT"
write_primary_conf "$REPLICA_DATA" "$REPLICA_PORT"
rm -f "$REPLICA_DATA/recovery.signal" "$REPLICA_DATA/standby.signal"
"$PG_CTL" -D "$REPLICA_DATA" -w restart >/dev/null
wait_ready "$REPLICA_PORT"
wait_not_in_recovery "$REPLICA_PORT"
sql "$REPLICA_PORT" -c "CHECKPOINT; SELECT pg_switch_wal();"
sleep 5

#############################################
# 5. Diverge old primary, stop, rewind
#############################################
echo "== 5) Diverge old primary, pg_tde_rewind -c =="
sql "$PRIMARY_PORT" -c "INSERT INTO rw_t VALUES (9102, 'old_primary', md5('op'));"
"$PG_CTL" -D "$PRIMARY_DATA" -w stop -m fast >/dev/null

write_pgbackrest_conf "$REPLICA_DATA" "$REPLICA_PORT"
# Target already has walkthrough restore_command in postgresql.conf for -c.
"$PG_REWIND" \
  --target-pgdata="$PRIMARY_DATA" \
  --source-server="host=$SOCKET_DIR port=$REPLICA_PORT dbname=postgres" \
  -c \
  --write-recovery-conf

write_primary_conf "$PRIMARY_DATA" "$PRIMARY_PORT"
# primary_conninfo from --write-recovery-conf stays in auto.conf (not hand-edited).
touch "$PRIMARY_DATA/standby.signal"
rm -f "$PRIMARY_DATA/recovery.signal" "$PRIMARY_DATA/promote.signal"

"$PG_CTL" -D "$PRIMARY_DATA" -w start >/dev/null
wait_ready "$PRIMARY_PORT"
sleep 5

echo "== 6) Verify failback =="
sql "$PRIMARY_PORT" -c "SELECT pg_is_in_recovery();"
sql "$REPLICA_PORT" -c "SELECT application_name, state FROM pg_stat_replication;"
sql "$PRIMARY_PORT" -c "SELECT COUNT(*) AS new_primary_rows FROM rw_t WHERE marker = 'new_primary';"
sql "$PRIMARY_PORT" -c "SELECT COUNT(*) AS old_primary_rows FROM rw_t WHERE marker = 'old_primary';"

NEW_CNT=$(sql "$PRIMARY_PORT" -Atc "SELECT COUNT(*) FROM rw_t WHERE marker = 'new_primary'")
OLD_CNT=$(sql "$PRIMARY_PORT" -Atc "SELECT COUNT(*) FROM rw_t WHERE marker = 'old_primary'")
IN_REC=$(sql "$PRIMARY_PORT" -Atc "SELECT pg_is_in_recovery()")

if [[ "$IN_REC" != "t" || "$NEW_CNT" != "1" || "$OLD_CNT" != "0" ]]; then
  echo "FAIL: in_recovery=$IN_REC new_primary=$NEW_CNT old_primary=$OLD_CNT (expect t / 1 / 0)"
  tail -n 80 "$PRIMARY_DATA/server.log" || true
  exit 1
fi

echo "PASS: rewind failback OK"
echo
echo "== 7) Optional: walkthrough wipe + restore into a fresh PGDATA =="
RESTORE_DATA="$ROOT/restored"
mkdir -p "$RESTORE_DATA"
chmod 700 "$RESTORE_DATA"
write_pgbackrest_conf "$REPLICA_DATA" "$REPLICA_PORT"
pgbackrest_restore_into "$RESTORE_DATA"
write_primary_conf "$RESTORE_DATA" "$((PRIMARY_PORT + 2))"
# Keep recovery.signal from restore; start and promote.
"$PG_CTL" -D "$RESTORE_DATA" -w start >/dev/null || true
wait_ready "$((PRIMARY_PORT + 2))"
wait_not_in_recovery "$((PRIMARY_PORT + 2))"
sql "$((PRIMARY_PORT + 2))" -c "SELECT COUNT(*) FROM rw_t WHERE marker = 'shared';"
sql "$((PRIMARY_PORT + 2))" -c "SELECT pg_tde_is_encrypted('rw_t');"
"$PG_CTL" -D "$RESTORE_DATA" -w stop -m fast >/dev/null || true

echo "PASS: walkthrough restore with --recovery-option also OK"
echo "Artifacts under: $ROOT"
echo
echo "archive_command:"
archive_command
echo "restore_command (for --recovery-option):"
restore_command
