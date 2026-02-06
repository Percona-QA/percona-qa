#!/bin/bash

# Cleanup
old_server_cleanup $PGDATA

echo "1=> Initialize Data directory"
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA

echo "2=> Start PG Server"
start_pg $PGDATA $PORT

echo "3=> Start OpenBao Vault Server"
start_openbao_server

echo "############################################################################"
echo "# Scenario 1: Token can use KV but cannot read mount metadata              #"
echo "############################################################################"

cat > $RUN_DIR/policy_kv_only.hcl <<EOF
path "pg_tde/data/*" {
  capabilities = ["create", "read"]
}

path "pg_tde/metadata/*" {
  capabilities = ["read", "list"]
}

path "sys/internal/ui/mounts/*" {
  capabilities = []
}

path "sys/mounts/*" {
  capabilities = []
}

EOF

export VAULT_NAMESPACE=pg_tde_ns1
create_bao_token "kv_only" "$RUN_DIR/policy_kv_only.hcl" "$RUN_DIR/token_kv_only"

$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring1','$vault_url','$secret_mount_point', '$RUN_DIR/token_kv_only',NULL,'$VAULT_NAMESPACE/');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring2','$vault_url','$secret_mount_point', '$RUN_DIR/token_kv_only',NULL,'$VAULT_NAMESPACE/');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_database_key_provider('vault_key1','vault_keyring1');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_create_key_using_global_key_provider('server_key1','vault_keyring2');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('vault_key1','vault_keyring1');"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('server_key1','vault_keyring2');"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE t1(a INT) USING tde_heap;"
$INSTALL_DIR/bin/psql -d postgres -c"INSERT INTO t1 VALUES (100),(200);"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"

restart_pg $PGDATA $PORT

$INSTALL_DIR/bin/psql -d postgres -c"SELECT * FROM t1;"
