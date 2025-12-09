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
        return 1
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
        return 1
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
    PORT=$2
    echo "Initializing PostgreSQL clusteri at $PGDATA..."

    rm -rf "$PGDATA"
    "$INSTALL_DIR/bin/initdb" -D "$PGDATA" > "$HOME/initdb.log" 2>&1
    cat > "$PGDATA/postgresql.conf" <<SQL
port=$PORT
listen_addresses='*'
io_method = 'sync'
logging_collector = on
log_directory = '$PGDATA'
log_filename = 'server.log'
log_statement = 'all'
default_table_access_method = 'tde_heap'
SQL

    echo "Cluster initialized at $PGDATA"
}

###################################
# Previous Server cleanup
# #################################
old_server_cleanup() {
    PGDATA=$1
    PG_PIDS=$(lsof -ti:5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi

    rm -rf $PGDATA
}
