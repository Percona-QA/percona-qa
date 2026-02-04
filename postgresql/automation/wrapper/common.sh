#!/bin/bash

###################################
# Start PostgreSQL
###################################
start_pg() {
    local PGDATA=$1
    local PORT=$2
    echo "Starting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -w start

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
    local PGDATA=$1
    local PORT=$2
    echo "Restarting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" restart

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
    $INSTALL_DIR/bin/postgres --version | awk '{print $3}' | cut -d. -f1
}

###################################
# Write postgresql.conf
###################################
write_postgresql_conf() {
    local PGDATA=$1
    local PORT=$2
    local ROLE="${3:-primary}"   # primary | replica
    local PG_MAJOR=$(get_pg_major_version)

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
EOF

    # io_method exists only in PG 18+
    if [[ "$PG_MAJOR" -ge 18 ]]; then
        echo "io_method = '$IO_METHOD'" >> "$PGDATA/postgresql.conf"
    fi

    if [[ "$ROLE" == "replica" ]]; then
        cat >> "$PGDATA/postgresql.conf" <<EOF
wal_level = replica
wal_compression = on
wal_log_hints = on
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
    local PGDATA=$1
    local PORT=$2
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
    local PGDATA=$1
    local PG_PIDS=$(lsof -ti:5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS || true
    fi

    sleep 5
    rm -rf -- "$PGDATA"
}
