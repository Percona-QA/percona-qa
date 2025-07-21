#!/bin/bash

INSTALL_DIR=$HOME/postgresql/bld_tde/install
DATA_DIR=$INSTALL_DIR/data
EXPORT_DIR=vault_export
PORT=5432

initialize_server() {

    # Kill PostgreSQL if running on common port (5432)
    local pg_pids
    pg_pids=$(lsof -ti :5432 2>/dev/null)
    if [[ -n "$pg_pids" ]]; then
       echo "Killing PostgreSQL processes: $pg_pids"
       kill -9 $pg_pids
    fi

    # Clean up data directory
    if [[ -d "$DATA_DIR" ]]; then
       echo "Removing old data directory: $DATA_DIR"
       rm -rf "$DATA_DIR"
    fi

    echo "Initializing database at $DATA_DIR"
    "$INSTALL_DIR/bin/initdb" -D "$DATA_DIR" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
       echo "Error: initdb failed"
       return 1
    fi

    # Write basic postgresql.conf
    cat > "$DATA_DIR/postgresql.conf" <<EOF
port = $PORT
listen_addresses = '*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$DATA_DIR'
log_filename = 'server.log'
log_statement = 'all'
EOF

    echo "Server initialized on port $PORT with data dir $DATA_DIR"
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $DATA_DIR start 
    $INSTALL_DIR/bin/psql  -d postgres -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $DATA_DIR restart
}

start_vault_server() {
     script_dir="${SCRIPT_DIR:-$(pwd)}"
     vault_dir="$script_dir/vault"
     config_file="$vault_dir/keyring_vault_ps.cnf"
     filename="/tmp/token_$(date '+%Y%m%d_%H%M%S')"

     echo "=> Killing any running Vault processes..."
     killall vault > /dev/null 2>&1

     echo "=> Starting Vault server..."

     mkdir -p "$vault_dir"
     rm -rf "$vault_dir"/*

      "$script_dir/helper_scripts/vault_test_setup.sh" \
         --workdir="$vault_dir" \
         --use-ssl > /dev/null 2>&1

      if [[ ! -f "$config_file" ]]; then
         echo "Error: Vault config file not found at $config_file"
         return 1
      fi

      vault_url=$(grep 'vault_url' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
      secret_mount_point=$(grep 'secret_mount_point' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
      token=$(grep 'token' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
      vault_ca=$(grep 'vault_ca' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')

      echo ".. Vault server started"
      echo "$token" > $filename

}

initialize_server
start_server
start_vault_server

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_database_key_provider_vault_v2('local_vault_provider', '$vault_url', '$secret_mount_point', '$filename', '$vault_ca')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_vault_provider')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_vault_provider')"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES (100)"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"

rm -rf $EXPORT_DIR
mkdir -p $EXPORT_DIR

export VAULT_ADDR=$vault_url
export VAULT_TOKEN=$token

# Read list from vault
$script_dir/vault/vault kv list -format=json -tls-skip-verify $secret_mount_point/ | jq -r '.[]' | while read -r key; do
echo "Exporting secret/$key"
$script_dir/vault/vault kv get -format=json -tls-skip-verify "$secret_mount_point/$key" > "$EXPORT_DIR/$key.json"
done


start_vault_server
echo "Restarting PG server"
restart_server
echo "It should fail to fetch data"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"

export VAULT_ADDR=$vault_url
export VAULT_TOKEN=$token

EXPORT_DIR=vault_export

echo "=> Importing secrets from $EXPORT_DIR"

for file in "$EXPORT_DIR"/*.json; do
    key_name=$(basename "$file" .json)

    echo "-> Importing $secret_mount_point/$key_name"

    # Extract just the inner secret data
    secret_data=$(jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' "$file")

    # Import cleanly with key=value pairs
    $script_dir/vault/vault kv put -tls-skip-verify "$secret_mount_point/$key_name" $secret_data
done

echo "✅ Import complete."

echo "It should still fail to fetch table data"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"

echo "SELECT pg_tde_change_database_key_provider_vault_v2('local_vault_provider', '$vault_url', '$secret_mount_point', '$filename', '$vault_ca')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_change_database_key_provider_vault_v2('local_vault_provider', '$vault_url', '$secret_mount_point', '$filename', '$vault_ca')"
echo "Must be successful"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"
