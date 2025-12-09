#!/bin/bash

EXPORT_DIR=$RUN_DIR/vault_export

# Actual test begins here...

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

# Read list from vault
$HELPER_DIR/vault/vault kv list -format=json -tls-skip-verify $secret_mount_point/ | jq -r '.[]' | while read -r key; do
echo "Exporting secret/$key"
$HELPER_DIR/vault/vault kv get -format=json -tls-skip-verify "$secret_mount_point/$key" > "$EXPORT_DIR/$key.json"
done

# Start a fresh Vault server, old keys are lost
start_vault_server
cp /tmp/token_file /tmp/token_file2
rm /tmp/token_file

echo "Restarting PG server"
restart_pg $PGDATA $PORT
if ! $INSTALL_DIR/bin/psql -d postgres -c "SELECT * FROM t1" ; then
    echo "Expected failure - ERROR: key \"local_key\" not found in key provider \"local_vault_provider\""
else
    echo "ERROR: Query unexpectedly succeeded"
    exit 1
fi

export VAULT_ADDR=$vault_url
export VAULT_TOKEN=$token

echo "=> Importing secrets from $EXPORT_DIR"

for file in "$EXPORT_DIR"/*.json; do
    key_name=$(basename "$file" .json)

    echo "-> Importing $secret_mount_point/$key_name"

    # Extract just the inner secret data
    secret_data=$(jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' "$file")

    # Import cleanly with key=value pairs
    $HELPER_DIR/vault/vault kv put -tls-skip-verify "$secret_mount_point/$key_name" $secret_data
done

echo "✅ Import complete."

if ! $INSTALL_DIR/bin/psql -d postgres -c "SELECT * FROM t1" ; then
    echo "Expected failure - ERROR: key \"local_key\" not found in key provider \"local_vault_provider\""
else
    echo "ERROR: Query unexpectedly succeeded"
    exit 1
fi

$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_change_database_key_provider_vault_v2('local_vault_provider', '$vault_url', '$secret_mount_point', '/tmp/token_file2', '$vault_ca')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1"
