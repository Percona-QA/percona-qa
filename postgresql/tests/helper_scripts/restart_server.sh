#!/bin/bash

restart_server() {
    local install_dir="${INSTALL_DIR:-$HOME/postgresql/pg_tde/bld_tde/install}"
    local data_dir="${PGDATA:-$install_dir/data}"
    local log_file="${LOG_FILE:-$data_dir/server.log}"

    if [[ ! -x "$install_dir/bin/pg_ctl" ]]; then
        echo "Error: pg_ctl not found at $install_dir/bin/pg_ctl"
        return 1
    fi

    if [[ ! -d "$data_dir" ]]; then
        echo "Error: PGDATA directory does not exist: $data_dir"
        return 1
    fi

    echo "Starting PostgreSQL server..."
    "$install_dir/bin/pg_ctl" -D "$data_dir" -l "$log_file" restart
}

