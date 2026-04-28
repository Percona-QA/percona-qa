#!/bin/bash

###################################
# Start PostgreSQL
###################################
start_pg() {
    local PGDATA=$1
    local PORT=$2
    local INSTALL_DIR=$3

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
    local INSTALL_DIR=$2

    echo "Stopping PostgreSQL..."
    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" stop
    echo "PostgreSQL stopped."
}

###################################
# Restart PostgreSQL
###################################
restart_pg() {
    local PGDATA=$1
    local PORT=$2
    local INSTALL_DIR=$3

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
    local PORT=$2
    local TIMEOUT=60
    local PID=$(head -1 "$PGDATA/postmaster.pid")
    kill -9 "$PID"

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

    rm -f "$PGDATA/postmaster.pid"
    rm -f "$RUN_DIR/.s.PGSQL.$PORT"
}


###################################
# Enable pg_tde Extension
###################################
enable_pg_tde() {
    local PGDATA=$1
    echo "=== Enabling pg_tde extension ==="

    # 1. Add pg_tde to shared_preload_libraries
    echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
    echo "Added shared_preload_libraries = 'pg_tde'"
}

get_pg_major_version() {
    local INSTALL_DIR=$1
    $INSTALL_DIR/bin/postgres --version | awk '{print $3}' | cut -d. -f1
}

###################################
# Initialize a fresh cluster
###################################
initialize_server() {
    local PGDATA=$1
    local PORT=$2
    local INSTALL_DIR=$3
    local EXTRA_ARG="${4:-}"

    echo "Initializing PostgreSQL cluster at $PGDATA..."

    rm -rf "$PGDATA" || true
    $INSTALL_DIR/bin/initdb $EXTRA_ARG -D "$PGDATA" > "$RUN_DIR/initdb.log" 2>&1
    cat > "$PGDATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$PGDATA'
log_filename = 'server.log'
log_statement = 'all'
default_table_access_method = 'tde_heap'
max_wal_senders = 5
wal_level = replica
EOF
    echo "Cluster initialized at $PGDATA"
}

###################################
# Previous Server cleanup
# #################################
old_server_cleanup() {
    local PGDATA=$1
    local PORT=$2
    local PG_PID=$(lsof -ti:"$PORT" || true)
    if [[ -n "$PG_PID" ]]; then
        echo "Killing PostgreSQL processes: $PG_PID"
        kill -9 $PG_PID || true
    fi

    sleep 5
    rm -rf -- "$PGDATA"
}
