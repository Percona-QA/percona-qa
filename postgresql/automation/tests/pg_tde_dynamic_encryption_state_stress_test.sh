#!/bin/bash

SYSBENCH=$(command -v sysbench)
KEYFILE=$RUN_DIR/keyring.file

alter_encrypt_unencrypt_tables(){
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql  -d sbtest -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
        sleep 1
    done
}

rotate_master_key(){
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
	$INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_create_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');"
        $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');"
    done
}

run_load(){
  local duration=$1
  $SYSBENCH /usr/share/sysbench/oltp_read_write.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=5 --time=$duration --report-interval=10 --events=1870000000 run
}

# Actual test begins here...

# Cleanup
old_server_cleanup $PGDATA
rm $KEYFILE || true

echo "1=> Initialize Data Directory"
initialize_server $PGDATA $PORT
enable_pg_tde $PGDATA

echo "2=> Starting Server"
start_pg $PGDATA $PORT

# Create encryption keys
$INSTALL_DIR/bin/createdb sbtest
$INSTALL_DIR/bin/psql -d sbtest -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$KEYFILE');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d sbtest -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"

echo "3=> Creating Tables"
$SYSBENCH /usr/share/sysbench/oltp_insert.lua --pgsql-db=sbtest --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=5 --table-size=1000 prepare

echo "4=> Run Concurrent Load with rotating MK and alter tables encrypt/unencrypt"
run_load 60 > $RUN_DIR/run_load.log 2>&1 &
rotate_master_key 60 > $RUN_DIR/rotate_master_key.log 2>&1 &
alter_encrypt_unencrypt_tables 60 > $RUN_DIR/alter_enc_dct.log 2>&1 &

wait

echo "5=> Verify tables are accessible after encryption state toggle"
for i in $(seq 1 5); do
  $INSTALL_DIR/bin/psql -d sbtest -c "SELECT COUNT(*) FROM sbtest$i"
  $INSTALL_DIR/bin/psql -d sbtest -c "SELECT pg_tde_is_encrypted('sbtest$i')"
done
