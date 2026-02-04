#!/bin/bash

# Set variable
DB_NAME=test_db
SYSBENCH=$(command -v sysbench)
SYSBENCH_TABLES=5

alter_encrypt_unencrypt_tables(){
  local duration=$1
  local end_time=$((SECONDS + duration))
  while [ $SECONDS -lt $end_time ]; do
    local RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
    local HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
    echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
    sleep 1
  done
}

rotate_wal_key(){
  local duration=$1
  local end_time=$((SECONDS + duration))
  while [ $SECONDS -lt $end_time ]; do
    local RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
    echo "Rotating Global master key: principal_key_test$RAND_KEY"
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."
    $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."
    done
}

run_sysbench_load(){
    local time=$1
    $SYSBENCH /usr/share/sysbench/oltp_read_write.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$SYSBENCH_TABLES --time=$time --report-interval=10 run &
    $SYSBENCH /usr/share/sysbench/oltp_delete.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$SYSBENCH_TABLES --time=$time --table-size=1000 &
    $SYSBENCH /usr/share/sysbench/oltp_update_index.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$SYSBENCH_TABLES --time=$time --table-size=1000 &

}

enable_disable_wal_encryption(){
    local start_time=$1
    local end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        local value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d $DB_NAME  -p $PRIMARY_PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

rotate_master_key(){
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        local RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continue..."
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continue..."
    done
}

create_keys_and_load() {
  $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"CREATE DATABASE $DB_NAME;"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_add_database_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_key_provider');"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_key_provider');"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_global_key_provider('global_key','global_key_provider');"
  $INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_key','global_key_provider');"

  echo "Create some tables on Primary Node"
  $SYSBENCH /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$SYSBENCH_TABLES --table-size=1000 prepare
  $SYSBENCH /usr/share/sysbench/bulk_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$SYSBENCH_TABLES --table-size=1000
}

# Actual test starts here...

old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA

echo "1=>Create Data Directory"
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL

echo "2=>Start Primary Server"
start_pg $PRIMARY_DATA $PRIMARY_PORT
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"CREATE USER repuser replication;"

echo "3=>Start Replica Server"
$INSTALL_DIR/bin/pg_tde_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=$PRIMARY_PORT

cat > "$REPLICA_DATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
port=$REPLICA_PORT
unix_socket_directories = '$RUN_DIR'
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
SQL

start_pg $REPLICA_DATA $REPLICA_PORT

echo "4=>Create pg_tde keys on Primary Server"
create_keys_and_load

echo "Running Sysbench Load"
run_sysbench_load 300 > /dev/null 2>&1 &
pid1=$!
rotate_wal_key 60 >/dev/null 2>&1 &
pid2=$!
enable_disable_wal_encryption 60 2>&1 > /dev/null &
pid3=$!
rotate_master_key 60 >/dev/null 2>&1  &
pid4=$!
alter_encrypt_unencrypt_tables 300   > /dev/null 2>&1 &
pid5=$!

for i in $(seq 1 3); do
    sleep 30
    ps -eaf | grep postgres
    crash_pg $REPLICA_DATA $REPLICA_PORT
    sleep 30
    echo "Restarting Replica Server"
    restart_pg $REPLICA_DATA $REPLICA_PORT
    sleep 15
    crash_pg $PRIMARY_DATA $PRIMARY_PORT
    sleep 30
    echo "Restarting Primary Server"
    restart_pg $PRIMARY_DATA $PRIMARY_PORT
done

echo "Verify table and data between primary and replica node..."
sleep 30
error_flag=0
for i in $(seq 1 $SYSBENCH_TABLES); do
    PRIMARY_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p $PRIMARY_PORT -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    REPLICA_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p $REPLICA_PORT -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    if [ "$PRIMARY_COUNT" -ne "$REPLICA_COUNT" ]; then
        echo "Mismatch in table sbtest$i: Primary($PRIMARY_COUNT) != Replica($REPLICA_COUNT)"
        exit 1
    else
        echo "Rows match in table sbtest$i: Primary($PRIMARY_COUNT) = Replica($REPLICA_COUNT)"
    fi
done
