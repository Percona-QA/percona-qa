#!/bin/bash

###################################
# Start PostgreSQL
###################################
start_pg() {
    PGDATA=$1
    PORT=$2
    echo "Starting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" -l "$PGLOG" start

    sleep 2

    if ! "$INSTALL_DIR/bin/pg_isready" -p "$PORT" -t 5 > /dev/null; then
        echo "❌ PostgreSQL failed to start"
        exit 1
    fi

    echo "PostgreSQL started successfully."
}

###################################
# Stop PostgreSQL
###################################
stop_pg() {
    PGDATA=$1
    echo "Stopping PostgreSQL..."
    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" stop
    echo "PostgreSQL stopped."
}

###################################
# Restart PostgreSQL
###################################
restart_pg() {
    PGDATA=$1
    PORT=$2
    echo "Restarting PostgreSQL..."

    "$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" restart

    if ! "$INSTALL_DIR/bin/pg_isready" -p "$PORT" -t 60 > /dev/null; then
        echo "❌ PostgreSQL restart failed"
        exit 1
    fi

    echo "PostgreSQL restarted successfully."
}

###################################
# Enable pg_tde Extension
###################################
enable_pg_tde() {
    PGDATA=$1
    echo "=== Enabling pg_tde extension ==="

    # 1. Add pg_tde to shared_preload_libraries
    echo "shared_preload_libraries = 'pg_tde'" >> "$PGDATA/postgresql.conf"
    echo "Added shared_preload_libraries = 'pg_tde'"
}

###################################
# Initialize a fresh cluster
###################################
initialize_server() {
    PGDATA=$1
    echo "Initializing PostgreSQL clusteri at $PGDATA..."

    rm -rf "$PGDATA"
    "$INSTALL_DIR/bin/initdb" -D "$PGDATA" > "$HOME/initdb.log" 2>&1

    echo "Cluster initialized at $PGDATA"
}

###################################
# Previous Server cleanup
# #################################
old_server_cleanup() {
    PG_PIDS=$(lsof -ti:5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
}
