#!/bin/bash

EXPORT_DIR=$RUN_DIR/vault_export

old_server_cleanup $PGDATA
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA
start_pg $PGDATA $PORT
start_vault_server

$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_database_key_provider_vault_v2('local_vault_provider', '$vault_url', '$secret_mount_point', '$token_file', '$vault_ca')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_vault_provider')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_vault_provider')"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES (100)"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"

rm -rf $EXPORT_DIR
mkdir -p $EXPORT_DIR

export VAULT_ADDR=$vault_url
export VAULT_TOKEN=$token

# Read list from vault and Export Keys
$vault_dir/vault kv list -format=json -tls-skip-verify $secret_mount_point/ | jq -r '.[]' | while read -r key; do
echo "Exporting secret/$key"
$vault_dir/vault kv get -format=json -tls-skip-verify "$secret_mount_point/$key" > "$EXPORT_DIR/$key.json"
done

# Restart new Vault server with new Token
start_vault_server

echo "Stop PG server"
stop_pg $PGDATA

export VAULT_ADDR=$vault_url
export VAULT_TOKEN=$token

echo "=> Importing secrets from $EXPORT_DIR"

for file in "$EXPORT_DIR"/*.json; do
    key_name=$(basename "$file" .json)

    echo "-> Importing $secret_mount_point/$key_name"

    # Extract just the inner secret data
    secret_data=$(jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' "$file")

    # Import cleanly with key=value pairs
    $vault_dir/vault kv put -tls-skip-verify "$secret_mount_point/$key_name" $secret_data
done

echo "✅ Import complete."

CMD="$INSTALL_DIR/bin/pg_tde_change_key_provider -D '$PGDATA' 5 local_vault_provider vault-v2 '$vault_url' '$secret_mount_point' '$token_file' '$vault_ca'"
echo "Running: $CMD"
eval "$CMD"

start_pg $PGDATA $PORT
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"
