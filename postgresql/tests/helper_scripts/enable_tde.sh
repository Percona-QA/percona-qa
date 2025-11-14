#!/bin/bash

enable_tde() {
    local install_dir="${INSTALL_DIR:-$HOME/postgresql/bld_18.0.1/install}"
    local pgdata="${PGDATA:-$HOME/pgdata}"
    local db_name="${DB_NAME:-postgres}"
    local keyring_file="${KEYRING_FILE:-$pgdata/keyring.file}"

    if [[ ! -x "$install_dir/bin/psql" ]]; then
        echo "Error: psql not found at $install_dir/bin/psql"
        return 1
    fi

    rm -rf $keyring_file

    echo "=> Enabling Transparent Data Encryption (TDE) on database: $db_name"
    "$install_dir/bin/psql" -d "$db_name" -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_add_global_key_provider_file('global_keyring', '$keyring_file');"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_add_database_key_provider_file('local_keyring', '$keyring_file');"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_keyring');"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_create_key_using_database_key_provider('table_key', 'local_keyring');"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_keyring');"
    "$install_dir/bin/psql" -d "$db_name" -c "SELECT pg_tde_set_key_using_database_key_provider('table_key', 'local_keyring');"
    echo ".. TDE enabled"
}
