#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_17.6/install
PUB_DATA=$INSTALL_DIR/pub_db
SUB_DATA=$INSTALL_DIR/sub_db
PUB_LOG=$PUB_DATA/pub.log
SUB_LOG=$SUB_DATA/sub.log
TABLES=5

initialize_server() {
    # Find and kill PostgreSQL processes running on ports 5432, 5433, 5434
    PG_PIDS=$( lsof -ti :5432 -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi

    rm -rf $PUB_DATA
    echo "Creating Publication Data Directory..."
    $INSTALL_DIR/bin/initdb -D $PUB_DATA > /dev/null 2>&1
    cat > "$PUB_DATA/postgresql.conf" <<SQL
wal_level=logical
wal_compression=on
port=5433
shared_preload_libraries='pg_tde'
SQL
   rm -rf $SUB_DATA
   mkdir $SUB_DATA
   echo "Creating Subscription Data Directory..."
   $INSTALL_DIR/bin/initdb -D $SUB_DATA > /dev/null 2>&1
   cat > "$SUB_DATA/postgresql.conf" << SQL
port=5434
shared_preload_libraries='pg_tde'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PUB_DATA -l $PUB_LOG start
    $INSTALL_DIR/bin/createdb "-p 5433" pub_db
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PUB_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"

    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_add_global_key_provider_file('local_keyring','$PUB_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c"ALTER SYSTEM SET pg_tde.wal_encrypt = on;"

    $INSTALL_DIR/bin/pg_ctl -D $SUB_DATA -l $SUB_LOG start
    $INSTALL_DIR/bin/createdb -p 5434 sub_db
    $INSTALL_DIR/bin/psql  -d sub_db -p 5434 -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql  -d sub_db -p 5434 -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$SUB_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d sub_db -p 5434 -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
    $INSTALL_DIR/bin/psql  -d sub_db -p 5434 -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $SUB_DATA -p 5433 stop
    $INSTALL_DIR/bin/pg_ctl -D $PUB_DATA -p 5434 stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PUB_DATA -p 5433 restart
    $INSTALL_DIR/bin/pg_ctl -D $SUB_DATA -p 5434 restart
}

create_tables_on_publisher() {
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=pub_db --pgsql-user=`whoami` --pgsql-port=5433 --db-driver=pgsql --threads=5 --tables=$TABLES --table-size=1000 prepare
}

dump_schema_on_subscriber() {
    $INSTALL_DIR/bin/pg_dump  -s pub_db -p 5433 | $INSTALL_DIR/bin/psql -p 5434 sub_db
}

run_read_write_load(){
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=pub_db --pgsql-user=`whoami` --pgsql-port=5433 --db-driver=pgsql --threads=5 --tables=$TABLES --time=60 --report-interval=1 --events=1870000000 run
}

encrypt_decrypt_wal(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
       value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
       echo "Altering WAL encryption to use $value..."
       $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
       sleep 1
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
       RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
       echo "Rotating master key: principal_key_test$RAND_KEY"
       $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."
       $INSTALL_DIR/bin/psql  -d pub_db -p 5433 -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."

    done
}

initialize_server
start_server
create_tables_on_publisher
dump_schema_on_subscriber
run_read_write_load
encrypt_decrypt_wal 60 > /dev/null 2>&1 &
pid1=$!
rotate_wal_key 60 > /dev/null 2>&1 &
pid2=$!

echo "Read table data on subscriber db. It must have empty rows"
for i in $(seq 1 $TABLES); do
    $INSTALL_DIR/bin/psql  -d sub_db -p 5434 -c"SELECT count(*) FROM sbtest$i"
done

echo "Create a Publication on the primary server"
$INSTALL_DIR/bin/psql -d pub_db -p 5433 -c"CREATE PUBLICATION mypub for all tables;"

echo "Create a Subscription on the secondary server"
$INSTALL_DIR/bin/psql -d sub_db -p 5434 -c"CREATE SUBSCRIPTION mysub connection 'dbname=pub_db host=localhost user=mohit.joshi port=5433' publication mypub;"

echo "Wait for sometime to sync data"
sleep 10
echo "Read table data on subscriber db. It must have rows"
for i in $(seq 1 $TABLES); do
    $INSTALL_DIR/bin/psql  -d sub_db --port=5434 -c"SELECT count(*) FROM sbtest$i"
done


kill -9 $pid1 $pid2
wait $pid1
wait $pid2
