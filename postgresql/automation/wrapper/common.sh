#!/bin/bash

###################################
# Start PostgreSQL
###################################
start_pg() {
    local PGDATA=${1:-$PGDATA}
    local PORT="${2:-$PGPORT}"
    echo "Starting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -w start -o "-p $PORT"

    if ! "$INSTALL_DIR/bin/pg_isready" -p "$PORT" -t 5 > /dev/null; then
        echo "❌ PostgreSQL failed to start"
        return 1
    fi

    echo "PostgreSQL started successfully."
}

###################################
# Stop PostgreSQL
###################################
stop_pg() {
    local PGDATA=$1
    echo "Stopping PostgreSQL..."
    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" stop
    echo "PostgreSQL stopped."
}

###################################
# Restart PostgreSQL
###################################
restart_pg() {
    local PGDATA=${1:-$PGDATA}
    local PORT="${2:-$PGPORT}"
    echo "Restarting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" restart -o "-p $PORT"

    if ! "$INSTALL_DIR/bin/pg_isready" -p "$PORT" -t 60 > /dev/null; then
        echo "❌ PostgreSQL restart failed"
        return 1
    fi

    echo "PostgreSQL restarted successfully."
}

crash_pg() {
    local PGDATA=$1
    local PORT="${2:-$PGPORT}"
    local TIMEOUT=60
    local PID=$(head -1 "$PGDATA/postmaster.pid")
    kill -9 "$PID"

    while kill -0 "$PID" 2>/dev/null; do
      sleep 1
    done

    # Wait for ALL postgres processes using this datadir to exit
    while pgrep -f "$PGDATA" >/dev/null; do
        sleep 1
        TIMEOUT=$((TIMEOUT - 1))
        if [ $TIMEOUT -le 0 ]; then
            echo "ERROR: postgres processes still running after crash"
            pgrep -af "$PGDATA"
            return 1
        fi
    done

    # Give the kernel a moment to release IPC resources (helps on slower ARM systems).
    sleep 2

    rm -f "$PGDATA/postmaster.pid"
    rm -f "$RUN_DIR/.s.PGSQL.$PORT"
}


###################################
# Enable pg_tde Extension
###################################
enable_pg_tde() {
    local PGDATA=${1:-$PGDATA}
    echo "=== Enabling pg_tde extension ==="

    # 1. Add pg_tde to shared_preload_libraries
    echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
    echo "Added shared_preload_libraries = 'pg_tde'"
}

get_pg_major_version() {
    $INSTALL_DIR/bin/postgres --version | awk '{sub(/[^0-9].*/, "", $3); print $3}'
}

# Return the major version from an arbitrary PostgreSQL bin directory.
# Usage: get_pg_major_version_from_dir /path/to/pgsql/bin
get_pg_major_version_from_dir() {
    local bin_dir="$1"
    "$bin_dir/postgres" --version | awk '{sub(/[^0-9].*/, "", $3); print $3}'
}

# Start a PostgreSQL cluster using a specific binary directory.
# Useful for cross-version upgrade tests where old and new binaries differ.
# Usage: start_pg_with_dir /old/pgsql/bin /pgdata 5435
start_pg_with_dir() {
    local bin_dir="$1"
    local pgdata="$2"
    local port="$3"
    echo "Starting PostgreSQL (${bin_dir}) at $pgdata on port $port..."
    "$bin_dir/pg_ctl" -D "$pgdata" -w start -o "-p $port"
    if ! "$bin_dir/pg_isready" -p "$port" -t 60 > /dev/null; then
        echo "❌ PostgreSQL failed to start (dir=$bin_dir, port=$port)"
        return 1
    fi
    echo "PostgreSQL started."
}

# Stop a PostgreSQL cluster using a specific binary directory.
# Usage: stop_pg_with_dir /old/pgsql/bin /pgdata
stop_pg_with_dir() {
    local bin_dir="$1"
    local pgdata="$2"
    echo "Stopping PostgreSQL ($pgdata)..."
    "$bin_dir/pg_ctl" -D "$pgdata" stop
    echo "PostgreSQL stopped."
}

###################################
# Write postgresql.conf
###################################
write_postgresql_conf() {
    local PGDATA=${1:-$PGDATA}
    local PORT=${2:-$PGPORT}
    local ROLE="${3:-primary}"   # primary | replica
    local PG_MAJOR=$(get_pg_major_version)

    cat > "$PGDATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$PGDATA'
log_filename = 'server.log'
log_statement = 'ddl'
log_min_error_statement = 'error'
max_wal_senders = 5
wal_log_hints = on
EOF

    # io_method exists only in PG 18+
    if [[ "$PG_MAJOR" -ge 18 ]]; then
        echo "io_method = '$IO_METHOD'" >> "$PGDATA/postgresql.conf"
    fi

    if [[ "$ROLE" == "replica" ]]; then
        cat >> "$PGDATA/postgresql.conf" <<EOF
wal_level = replica
wal_compression = on
wal_keep_size = 512MB
max_replication_slots = 2
max_wal_senders = 5
EOF
    fi
}


###################################
# Initialize a fresh cluster
###################################
initialize_server() {
    local PGDATA=${1:-$PGDATA}
    local PORT=${2:-$PGPORT}
    local EXTRA_ARG="${3:-}"

    echo "Initializing PostgreSQL cluster at $PGDATA..."

    rm -rf "$PGDATA" || true
    $INSTALL_DIR/bin/initdb $EXTRA_ARG -D "$PGDATA" > "$RUN_DIR/initdb.log" 2>&1
    write_postgresql_conf "$PGDATA" "$PORT" "primary"
    echo "Cluster initialized at $PGDATA"
}

###################################
# Previous Server cleanup
# #################################
old_server_cleanup() {
    local PGDATA=${1:-$PGDATA}
    local PORT=${2:-$PGPORT}
    local PG_PIDS=$(lsof -ti:$PORT -ti:${PRIMARY_PORT:-5433} -ti:${REPLICA_PORT:-5434} 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS || true
    fi

    sleep 5
    rm -rf -- "$PGDATA"
}

install_pgbackrest() {
    if command -v pgbackrest >/dev/null 2>&1; then
        echo "pgBackRest is already installed: $(pgbackrest version)"
        return 0
    fi

    if [ -f /etc/debian_version ]; then
        sudo apt-get update
        wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        sudo dpkg -i percona-release_latest.generic_all.deb
        sudo percona-release enable-only ppg-18
        sudo apt-get update -y
        sudo apt-get install -y percona-pgbackrest
    elif [ -f /etc/redhat-release ]; then
	wget -q https://repo.percona.com/yum/percona-release-latest.noarch.rpm
	sudo yum install -y ./percona-release-latest.noarch.rpm
	sudo percona-release enable-only ppg-18
	sudo yum install -y percona-pgbackrest
    fi
}

install_patroni_and_etcd() {
    local need_patroni=0
    local need_etcd=0

    if command -v patroni >/dev/null 2>&1; then
        echo "patroni is already installed: $(patroni --version)"
    else
        need_patroni=1
    fi

    if command -v etcd >/dev/null 2>&1; then
        echo "etcd is already installed: $(etcd --version | head -1 | awk '{print $3}')"
    else
        need_etcd=1
    fi

    [ $need_patroni -eq 0 ] && [ $need_etcd -eq 0 ] && return 0

    if [ -f /etc/debian_version ]; then
        sudo apt-get update
        [ $need_patroni -eq 1 ] && sudo apt-get install -y patroni
        [ $need_etcd -eq 1 ] && sudo apt-get install -y etcd-server

    elif [ -f /etc/redhat-release ]; then
        # Install Patroni if needed
        if [ $need_patroni -eq 1 ]; then
            sudo dnf install -y patroni || sudo pip3 install patroni
        fi

        # Install etcd if needed
        if [ $need_etcd -eq 1 ]; then
            local ETCD_VER=v3.5.30
            local arch

            case $(uname -m) in
                x86_64|amd64) arch=amd64 ;;
                aarch64|arm64) arch=arm64 ;;
                *)
                    echo "Unsupported architecture: $(uname -m)"
                    return 1
                    ;;
            esac

            curl -L \
              "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-${arch}.tar.gz" \
              -o /tmp/etcd.tar.gz

            tar -xzf /tmp/etcd.tar.gz -C /tmp

            sudo install -m 0755 /tmp/etcd-${ETCD_VER}-linux-${arch}/etcd /usr/local/bin/etcd
            sudo install -m 0755 /tmp/etcd-${ETCD_VER}-linux-${arch}/etcdctl /usr/local/bin/etcdctl
        fi
    fi
}


###################################
# Poll until a node has finished recovery (pg_is_in_recovery() = false).
# Use after a promote instead of a fixed `sleep N`.
#   wait_for_recovery_end [PORT] [TIMEOUT_SECONDS]
###################################
wait_for_recovery_end() {
    local PORT="${1:-$PGPORT}"
    local TIMEOUT="${2:-120}"
    local elapsed=0 in_rec
    while true; do
        in_rec=$("$INSTALL_DIR/bin/psql" -p "$PORT" -d postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
        if [[ "$in_rec" == "f" ]]; then
            echo "Recovery complete on port $PORT (${elapsed}s)"
            return 0
        fi
        if (( elapsed >= TIMEOUT )); then
            echo "❌ Timed out after ${TIMEOUT}s waiting for recovery to end on port $PORT"
            return 1
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
}

###################################
# Poll until a streaming replica has replayed all WAL the primary had
# written at call time (replay_lsn >= primary's current LSN snapshot).
# Use instead of a fixed `sleep N` waiting for replication to catch up.
#   wait_for_replica_catchup [PRIMARY_PORT] [REPLICA_PORT] [TIMEOUT_SECONDS]
###################################
wait_for_replica_catchup() {
    local P_PORT="${1:-$PRIMARY_PORT}"
    local R_PORT="${2:-$REPLICA_PORT}"
    local TIMEOUT="${3:-120}"
    local elapsed=0 target replayed caught
    target=$("$INSTALL_DIR/bin/psql" -p "$P_PORT" -d postgres -tAc "SELECT pg_current_wal_lsn();" 2>/dev/null)
    while true; do
        replayed=$("$INSTALL_DIR/bin/psql" -p "$R_PORT" -d postgres -tAc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null)
        if [[ -n "$target" && -n "$replayed" ]]; then
            caught=$("$INSTALL_DIR/bin/psql" -p "$P_PORT" -d postgres -tAc \
                "SELECT pg_wal_lsn_diff('$replayed', '$target') >= 0;" 2>/dev/null)
            if [[ "$caught" == "t" ]]; then
                echo "Replica (port $R_PORT) caught up to $target (${elapsed}s)"
                return 0
            fi
        fi
        if (( elapsed >= TIMEOUT )); then
            echo "❌ Timed out after ${TIMEOUT}s waiting for replica catch-up (target=$target last=$replayed)"
            return 1
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
}

cleanup_patroni_cluster()
{
    echo "Cleaning Patroni cluster"

    sudo pkill -x patroni || true
    sudo pkill -x etcd || true

    sleep 2

    sudo pkill -9 -x patroni || true
    sudo pkill -9 -x etcd || true

    # Free ports explicitly
    for p in 2379 2380
    do
      local pids
      pids=$(lsof -tiTCP:$p -sTCP:LISTEN 2>/dev/null || true)
      if [ -n "$pids" ]; then
        sudo kill -9 $pids 2>/dev/null || true
      fi
    done

    rm -rf "$PATRONI_BASE" "$ETCD_DATA"
    mkdir -p "$PATRONI_BASE" "$ETCD_DATA"
    sudo chown -R "$(id -u):$(id -g)" "$PATRONI_BASE" "$ETCD_DATA"
}

start_etcd()
{
    echo "Starting etcd"

    etcd \
        --name=default \
        --data-dir="$ETCD_DATA" \
        --listen-client-urls=http://127.0.0.1:2379 \
        --advertise-client-urls=http://127.0.0.1:2379 \
        --listen-peer-urls=http://127.0.0.1:2380 \
        --initial-advertise-peer-urls=http://127.0.0.1:2380 \
        --initial-cluster="default=http://127.0.0.1:2380" \
        --initial-cluster-state=new \
        > "$PATRONI_BASE/etcd.log" 2>&1 &

    ETCD_PID=$!
    echo $ETCD_PID > "$PATRONI_BASE/etcd.pid"

    sleep 2
    ps -ef | grep [e]tcd
    ss -ltnp | grep 2379 || true
    cat $PATRONI_BASE/etcd.log || true

    if ! kill -0 $ETCD_PID 2>/dev/null; then
        echo "etcd failed to start"
        cat "$PATRONI_BASE/etcd.log"
        return 1
    fi

    wait_for_port 2379 || return 1
    wait_for_port 2380 || return 1

    for i in {1..30}
    do
        if ETCDCTL_API=3 etcdctl \
            --endpoints=http://127.0.0.1:2379 \
            endpoint health >/dev/null 2>&1
        then
            echo "etcd is healthy"
            return 0
        fi
        sleep 1
    done

    echo "etcd failed health check"
    cat "$PATRONI_BASE/etcd.log"
    return 1
}

generate_patroni_config()
{
    local node=$1
    local port=$((5431 + node))
    local rest=$((8007 + node))

    local dir="$PATRONI_BASE/node$node"

    mkdir -p "$dir"
    rm -rf "$dir/data"

    cat > "$dir/patroni.yml" <<EOF
scope: $PATRONI_CLUSTER
name: node$node

restapi:
  listen: 127.0.0.1:$rest
  connect_address: 127.0.0.1:$rest

etcd3:
  host: 127.0.0.1:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true

  initdb:
    - encoding: UTF8
    - data-checksums

  users:
    replicator:
      password: replpass
      options:
        - replication

postgresql:
  listen: 127.0.0.1:$port
  connect_address: 127.0.0.1:$port

  data_dir: $dir/data
  bin_dir: $INSTALL_DIR/bin

  authentication:
    replication:
      username: replicator
      password: replpass
    superuser:
      username: postgres
      password: postgres

  create_replica_methods:
    - basebackup

  basebackup:
    checkpoint: fast

  parameters:
    shared_preload_libraries: 'pg_tde'
    wal_level: replica
    hot_standby: on
    max_wal_senders: 10
    max_replication_slots: 10
    shared_buffers: 256MB
    logging_collector: on
    log_destination: stderr

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
EOF
}

initialize_patroni_cluster()
{
    local nodes=$1

    cleanup_patroni_cluster

    start_etcd

    for i in $(seq 1 $nodes)
    do
        generate_patroni_config $i
    done
}

start_patroni_cluster()
{
    local nodes=$1

    echo "Starting Patroni cluster ($nodes nodes)"

    # Start node1 first
    patroni "$PATRONI_BASE/node1/patroni.yml" \
       > "$PATRONI_BASE/node1/patroni.log" 2>&1 &

    wait_for_patroni_leader

    # Start remaining nodes
    for i in $(seq 2 $nodes)
    do
        local dir="$PATRONI_BASE/node$i"
        patroni "$dir/patroni.yml" \
           > "$dir/patroni.log" 2>&1 &
    done

    if [ $nodes -gt 1 ]; then
        wait_for_patroni_replicas $((nodes - 1))
    fi
}

wait_for_patroni_leader()
{
    echo "Waiting for Patroni leader"

    for i in {1..60}
    do
        local leader

	leader=$(patronictl -c \
	    "$PATRONI_BASE/node1/patroni.yml" \
	    list 2>/dev/null | awk -F'|' '/Leader/ {gsub(/ /, "", $2); print $2}')

        if [ -n "$leader" ]
        then
            echo "Leader: $leader"
            return 0
        fi

        sleep 1
    done

    echo "Leader not elected"
    exit 1
}

wait_for_patroni_replicas()
{
    local expected=$1
    echo "Waiting for $expected replica(s)"

    for i in {1..120}
    do
        local count
        count=$(patronictl -c "$PATRONI_BASE/node1/patroni.yml" list 2>/dev/null | awk -F'|' '
            {
                role=$4
                gsub(/^[ \t]+|[ \t]+$/, "", role)
                if (role == "Replica")
                    count++
            }
            END {
                print count+0
            }')

        echo "Attempt $i: replica count=$count expected=$expected"

        if [ "$count" -eq "$expected" ] ; then
            echo "Replicas ready"
            return 0
        fi

        sleep 1
    done

    echo "Replicas did not join"
    exit 1
}

wait_for_port()
{
    local port=$1
    local host=${2:-127.0.0.1}
    local timeout=${3:-60}

    echo "Waiting for $host:$port"

    for i in $(seq 1 $timeout)
    do
        if nc -z "$host" "$port" >/dev/null 2>&1
        then
            echo "Port $port is ready"
            return 0
        fi

        sleep 1
    done

    echo "ERROR: Timeout waiting for $host:$port"
    echo "===== ss output ====="
    ss -ltnp | grep -E "2379|2380" || true
    echo "===== etcd process ====="
    ps -ef | grep [e]tcd || true
    echo "===== etcd log ====="
    cat "$PATRONI_BASE/etcd.log" || true
    return 1
}
