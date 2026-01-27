#!/bin/bash

SYSBENCH=$(command -v sysbench)
KEYFILE=$RUN_DIR/keyring.file

run_sysbench_load(){
    local duration=$1
    $SYSBENCH /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --time=$duration --report-interval=10 run > /dev/null 2>&1
}

enable_disable_wal_encryption(){
    local start_time=$1
    local end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        local value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

change_key_provider(){
    local start_time=$1
    local end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        provider_type=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "vault_v2" || echo "file")
        if [ $provider_type == "vault_v2" ]; then
            provider_name=vault_local_provider
            provider_config="'$vault_url','$secret_mount_point','$token_file','$vault_ca'"
        elif [ $provider_type == "file" ]; then
            provider_name=file_local_provider
            provider_config="'$KEYFILE'"
        fi
        $INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_change_database_key_provider_$provider_type('$provider_name',$provider_config)"
        sleep 1
    done
}

# Actual test begins here...
old_server_cleanup $PGDATA
rm -f $KEYFILE || true

echo "1=> Initialize Data directory"
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA

echo "2=> Start Vault server"
start_vault_server

echo "3=> Start PG server"
start_pg $PGDATA $PORT

$INSTALL_DIR/bin/createdb sbtest
$INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('file_local_provider','$KEYFILE');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_global_key_provider_file('file_global_provider','$KEYFILE');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_vault_v2('vault_local_provider','$vault_url','$secret_mount_point','$token_file','$vault_ca');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','file_local_provider');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key_sbtest2','file_global_provider');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','file_local_provider');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_sbtest2','file_global_provider');"

echo "4=>Create tables and insert data"
$SYSBENCH /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=10 --table-size=1000 prepare

for X in $(seq 1 5); do
   # Run Test
  echo "=== Iteration $X ==="
  run_sysbench_load 15 &
  SB_PID=$!

  change_key_provider 15 &
  KP_PID=$!

  sleep 10
  crash_pg $PGDATA $PORT

  wait "$SB_PID" 2>/dev/null || true
  wait "$KP_PID" 2>/dev/null || true

  start_pg $PGDATA $PORT
done
