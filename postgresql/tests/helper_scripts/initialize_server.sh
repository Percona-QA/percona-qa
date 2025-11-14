#!/bin/bash

initialize_server() {
    # Allow overriding via env variables or use defaults
    local port="${PORT:-5432}"
    local install_dir="${INSTALL_DIR:-$HOME/postgresql/bld_18.1.1/install}"
    local data_dir="${PGDATA:-$HOME/postgresql/bld_18.1.1/install/data}"

    # Kill PostgreSQL if running on common ports (5432–5434)
    local pg_pids
    pg_pids=$(lsof -ti :5432 -ti :5433 -ti :5434 2>/dev/null)
    if [[ -n "$pg_pids" ]]; then
        echo "Killing PostgreSQL processes: $pg_pids"
        kill -9 $pg_pids
    fi

    # Clean up data directory
    if [[ -d "$data_dir" ]]; then
        echo "Removing old data directory: $data_dir"
        rm -rf "$data_dir"
    fi

    echo "Initializing database at $data_dir"
    "$install_dir/bin/initdb" -D "$data_dir" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Error: initdb failed"
        return 1
    fi

    # Write basic postgresql.conf
    cat > "$data_dir/postgresql.conf" <<EOF
port = $port
listen_addresses = '*'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
logging_collector = on
log_directory = '$data_dir'
log_filename = 'server.log'
log_statement = 'all'
io_method = 'sync'
EOF

    echo "Server initialized on port $port with data dir $data_dir"
}
