#!/usr/bin/env bash
#
# 3-node Patroni + pg_tde + pgBackRest playground.
#
# Brings up a real 3-node Patroni-managed cluster (1 leader + 2 replicas) on
# localhost, using Patroni's built-in `raft` DCS so no etcd/Consul/ZooKeeper
# is needed. pg_tde is installed with a Vault/OpenBao key provider, and
# pgbackrest archiving/restore is wired up exactly like the operator-generated
# configs attached to PG-2609 and PG-2587 (plain archive_command/restore_command
# — no pg_tde_archive_decrypt/pg_tde_restore_encrypt wrapper, matching what
# those bug reports actually ran).
#
# This is meant to stay running so you can drive different scenarios against
# it interactively — it does NOT tear itself down. Use
# pg_tde_patroni_3node_teardown.sh when done, and see the companion scenario
# scripts:
#   pg_tde_patroni_scenario_wal_encrypt.sh    — PG-2609-style: enable
#     pg_tde.wal_encrypt via `patronictl edit-config` (the real orchestration
#     path — SIGHUP-fails-then-restart, exactly like the bug) and watch
#     archiving for "mismatch of segment size".
#   pg_tde_patroni_scenario_backup_restore.sh — PG-2587-style: full backup +
#     in-place restore onto the leader, watch replicas for "invalid magic
#     number" / "has already been removed".
#
# Prerequisites:
#   pip install 'patroni[raft]'
#   INSTALL_DIR must point at a PostgreSQL install with pg_tde + pgbackrest
#   on PATH.
#
# Usage:
#   INSTALL_DIR=/path/to/pginst/18 \
#     bash postgresql/bugs/pg_tde_patroni_3node_setup.sh
#
#   KEY_PROVIDER=file INSTALL_DIR=... bash ...   # file keyring instead of Vault
#
set -euo pipefail

# OS-aware default INSTALL_DIR (Ubuntu: /usr/lib/postgresql/N, RHEL: /usr/pgsql-N)
# shellcheck source=pg_install_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_install_env.sh"

command -v patroni >/dev/null 2>&1 || { echo "ERROR: patroni not on PATH (pip install 'patroni[raft]')"; exit 1; }
command -v patronictl >/dev/null 2>&1 || { echo "ERROR: patronictl not on PATH"; exit 1; }
python3 -c "import pysyncobj" 2>/dev/null || { echo "ERROR: pysyncobj missing (pip install 'patroni[raft]')"; exit 1; }

ROOT="${PATRONI3_ROOT:-/tmp/pg_tde_patroni3}"
BIN="$INSTALL_DIR/bin"
PGBR="$(command -v pgbackrest || true)"
[[ -x "$BIN/postgres" ]] || { echo "ERROR: $BIN/postgres not found"; exit 1; }
[[ -n "$PGBR" ]] || { echo "ERROR: pgbackrest not on PATH"; exit 1; }

KEY_PROVIDER="${KEY_PROVIDER:-openbao}"
AUTO_OPENBAO="${AUTO_OPENBAO:-1}"
SCOPE="pg_tde_cluster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STANCE="db"
REPO="$ROOT/repo"
CONF="$ROOT/pgbackrest.conf"
export PATRONICTL_CONFIG_FILE="$ROOT/patroni1.yml"

# Node port map: postgres / patroni-restapi / raft
declare -a NAMES=(node1 node2 node3)
declare -a PG_PORTS=(5501 5502 5503)
declare -a API_PORTS=(8008 8009 8010)
declare -a RAFT_PORTS=(2222 2223 2224)

echo "════════════════════════════════════════════════════════"
echo " 3-node Patroni + pg_tde + pgBackRest playground"
echo " ROOT=$ROOT  INSTALL_DIR=$INSTALL_DIR  KEY_PROVIDER=$KEY_PROVIDER"
echo "════════════════════════════════════════════════════════"

if pgrep -f "patroni .*${ROOT}/patroni1.yml" >/dev/null 2>&1; then
  echo "ERROR: a cluster already looks alive under $ROOT — run"
  echo "  bash $SCRIPT_DIR/pg_tde_patroni_3node_teardown.sh"
  echo "first, or set PATRONI3_ROOT to a different path."
  exit 1
fi

rm -rf "$ROOT"
mkdir -p "$ROOT/log" "$REPO" "$ROOT/spool"

cat > "$CONF" <<EOF
[global]
repo1-path=$REPO
repo1-retention-full=2
start-fast=y
log-level-console=info
log-level-file=detail
log-path=$ROOT/log
spool-path=$ROOT/spool
archive-async=n
archive-header-check=n
checksum-page=n

[$STANCE]
pg1-port=${PG_PORTS[0]}
pg1-socket-path=$ROOT/socket1
pg1-database=postgres
EOF

# Matches PG-2609/PG-2587 attachments: PLAIN pgbackrest calls, no
# pg_tde_archive_decrypt/pg_tde_restore_encrypt wrapper. Change this to test
# the wrapped variant (see PG-2609_repro_wal_encrypt_pgbackrest_ha.sh for that
# archive_command shape) as one of your own scenarios.
ARCHIVE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} archive-push \"%p\""
RESTORE_CMD="${PGBR} --config=${CONF} --stanza=${STANCE} archive-get %f \"%p\""

for i in 0 1 2; do
  name="${NAMES[$i]}"
  pgport="${PG_PORTS[$i]}"
  apiport="${API_PORTS[$i]}"
  raftport="${RAFT_PORTS[$i]}"
  datadir="$ROOT/data_$name"
  sockdir="$ROOT/socket$((i+1))"
  raftdir="$ROOT/raft_$name"
  mkdir -p "$sockdir" "$raftdir"

  # partner_addrs = the other two raft ports
  partners=""
  for j in 0 1 2; do
    [[ "$j" -eq "$i" ]] && continue
    partners="${partners}  - 127.0.0.1:${RAFT_PORTS[$j]}
"
  done

  cat > "$ROOT/patroni${i}.yml" <<EOF
scope: ${SCOPE}
name: ${name}

restapi:
  listen: 127.0.0.1:${apiport}
  connect_address: 127.0.0.1:${apiport}

raft:
  self_addr: 127.0.0.1:${raftport}
  partner_addrs:
${partners}  data_dir: ${raftdir}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 5
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: logical
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        wal_keep_size: 128MB
        shared_preload_libraries: pg_tde
        track_commit_timestamp: "true"
  initdb:
  - encoding: UTF8
  - data-checksums
  pg_hba:
  - local all all trust
  - host replication all 127.0.0.1/32 trust
  - host all all 127.0.0.1/32 trust

postgresql:
  listen: 127.0.0.1:${pgport}
  connect_address: 127.0.0.1:${pgport}
  data_dir: ${datadir}
  bin_dir: ${BIN}
  authentication:
    replication:
      username: replicator
      password: replpass
    superuser:
      username: postgres
      password: pgpass
    rewind:
      username: rewind_user
      password: rewindpass
  parameters:
    unix_socket_directories: '${sockdir}'
    archive_mode: "on"
    archive_timeout: ${ARCHIVE_TIMEOUT_S:-15}s
    archive_command: '${ARCHIVE_CMD}'
    restore_command: '${RESTORE_CMD}'
    logging_collector: "on"
    log_directory: '${ROOT}/log'
    log_filename: 'postgresql-${name}.log'
    log_min_messages: info
    log_line_prefix: '%m [%p] '

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

  echo "starting ${name} (pg=${pgport} api=${apiport} raft=${raftport})"
  nohup patroni "$ROOT/patroni${i}.yml" >"$ROOT/log/patroni-${name}.out" 2>&1 &
  echo $! > "$ROOT/patroni-${name}.pid"
  sleep 2
done

echo
echo "── Waiting for cluster to converge (leader + 2 replicas) ──"
LEADER_PORT=""
for _ in $(seq 1 60); do
  OUT="$(patronictl -c "$ROOT/patroni0.yml" list "$SCOPE" 2>/dev/null || true)"
  if echo "$OUT" | grep -q "Leader" && [[ "$(echo "$OUT" | grep -c "running")" -ge 3 ]]; then
    echo "$OUT"
    break
  fi
  sleep 2
done
patronictl -c "$ROOT/patroni0.yml" list "$SCOPE" || true

LEADER_NAME="$(patronictl -c "$ROOT/patroni0.yml" list "$SCOPE" 2>/dev/null | awk '/Leader/{print $2}')"
if [[ -z "$LEADER_NAME" ]]; then
  echo "ERROR: no leader elected — check $ROOT/log/patroni-*.out"
  exit 1
fi
for i in 0 1 2; do
  [[ "${NAMES[$i]}" == "$LEADER_NAME" ]] && LEADER_PORT="${PG_PORTS[$i]}" && LEADER_SOCK="$ROOT/socket$((i+1))"
done
echo "leader: $LEADER_NAME  port=$LEADER_PORT"

sql() { "$BIN/psql" -h "$LEADER_SOCK" -p "$LEADER_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

echo
echo "── Bootstrap pg_tde on the leader ──"
sql -c "CREATE EXTENSION pg_tde;"
KEY_NAME="global-master-key-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
case "$KEY_PROVIDER" in
  file)
    KEYFILE="$ROOT/keyring.per"
    sql -c "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE');"
    sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
    sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'file_provider');"
    ;;
  openbao|vault)
    # shellcheck source=PG-2609_openbao_setup.sh
    source "$SCRIPT_DIR/PG-2609_openbao_setup.sh"
    OPENBAO_RUN_DIR="${OPENBAO_RUN_DIR:-$ROOT/openbao}"
    pg2609_ensure_openbao || exit 1
    VAULT_URL="${VAULT_ADDR%/}"
    VAULT_MOUNT="${VAULT_SECRET_MOUNT:-pg_tde}"
    VAULT_NS="${VAULT_NAMESPACE:-pg_tde_ns1/}"
    TOKEN_DST="$ROOT/vault_token"
    if [[ -n "${VAULT_TOKEN_FILE:-}" && -f "${VAULT_TOKEN_FILE}" ]]; then
      cp -f "${VAULT_TOKEN_FILE}" "$TOKEN_DST"
    else
      printf '%s' "${VAULT_TOKEN}" > "$TOKEN_DST"
    fi
    chmod 600 "$TOKEN_DST"
    sql -c "SELECT pg_tde_add_global_key_provider_vault_v2('vault-provider','$VAULT_URL','$VAULT_MOUNT','$TOKEN_DST',NULL,'$VAULT_NS');"
    sql -c "SELECT pg_tde_create_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
    sql -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', 'vault-provider');"
    ;;
  *)
    echo "ERROR: KEY_PROVIDER must be openbao, vault, or file"; exit 1
    ;;
esac
echo "pg_tde bootstrapped (key: $KEY_NAME, provider: $KEY_PROVIDER)"

echo
echo "── pgbackrest stanza-create (against the leader) ──"
"$PGBR" --config="$CONF" --stanza="$STANCE" --pg1-path="$ROOT/data_${LEADER_NAME}" --pg1-port="$LEADER_PORT" --pg1-socket-path="$LEADER_SOCK" stanza-create

cat > "$ROOT/env.sh" <<EOF
# source this to get handy vars for driving scenarios against this cluster
export PATRONI3_ROOT="$ROOT"
export PATRONICTL_CONFIG_FILE="$ROOT/patroni0.yml"
export PG_TDE_PATRONI3_SCOPE="$SCOPE"
export PG_TDE_PATRONI3_CONF="$CONF"
export PG_TDE_PATRONI3_STANCE="$STANCE"
export PG_TDE_PATRONI3_BIN="$BIN"
export PG_TDE_PATRONI3_PGBR="$PGBR"
EOF

echo
echo "════════════════════════════════════════════════════════"
echo " Cluster is up. Play with it:"
echo "════════════════════════════════════════════════════════"
echo " source $ROOT/env.sh"
echo " patronictl -c $ROOT/patroni0.yml list $SCOPE"
echo " patronictl -c $ROOT/patroni0.yml edit-config $SCOPE   # e.g. flip pg_tde.wal_encrypt"
echo " psql -h $LEADER_SOCK -p $LEADER_PORT -U postgres -d postgres"
echo
echo " Scenario scripts:"
echo "   bash postgresql/bugs/pg_tde_patroni_scenario_wal_encrypt.sh"
echo "   bash postgresql/bugs/pg_tde_patroni_scenario_backup_restore.sh"
echo
echo " Tear down: bash postgresql/bugs/pg_tde_patroni_3node_teardown.sh"
echo "════════════════════════════════════════════════════════"
exit 0
