#!/bin/bash

# Set variable
PRIMARY_DB=pub_db
REPLICA_DB=sub_db
SYSBENCH="$(command -v sysbench)"
SYSBENCH_TABLES=5

encrypt_decrypt_wal(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
       value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
       echo "Altering WAL encryption to use $value..."
       $INSTALL_DIR/bin/psql  -d $PRIMARY_DB -p $PRIMARY_PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
       sleep 1
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
       RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
       echo "Rotating master key: principal_key_test$RAND_KEY"
       $INSTALL_DIR/bin/psql  -d $PRIMARY_DB -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."
       $INSTALL_DIR/bin/psql  -d $PRIMARY_DB -p $PRIMARY_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring');" || echo "SQL command failed, continuing..."

    done
}

old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA
initialize_server $PRIMARY_DATA $PRIMARY_PORT
enable_pg_tde $PRIMARY_DATA

cat >> "$PRIMARY_DATA/postgresql.conf" <<SQL
wal_level=logical
wal_compression=on
SQL

initialize_server $REPLICA_DATA $REPLICA_PORT
enable_pg_tde $REPLICA_DATA

start_pg $PRIMARY_DATA $PRIMARY_PORT
$INSTALL_DIR/bin/createdb "-p $PRIMARY_PORT" $PRIMARY_DB
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_global_key_provider('principal_key_sbtest2','global_keyring');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_sbtest2','global_keyring');"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';"

start_pg $REPLICA_DATA $REPLICA_PORT
$INSTALL_DIR/bin/createdb -p $REPLICA_PORT $REPLICA_DB
$INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
$INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$REPLICA_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -c"SELECT pg_tde_create_key_using_database_key_provider('principal_key_sbtest','local_keyring');"
$INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_sbtest','local_keyring');"

echo "Create tables on Primary"
$SYSBENCH /usr/share/sysbench/oltp_insert.lua --pgsql-db=$PRIMARY_DB --pgsql-user=`whoami` --pgsql-port=$PRIMARY_PORT --db-driver=pgsql --threads=5 --tables=$SYSBENCH_TABLES --table-size=100 prepare

echo "Dump Schema on Replica"
$INSTALL_DIR/bin/pg_dump  -s $PRIMARY_DB -p $PRIMARY_PORT | $INSTALL_DIR/bin/psql -p $REPLICA_PORT $REPLICA_DB

echo "Run Read/Write Load"
$SYSBENCH /usr/share/sysbench/oltp_read_write.lua --pgsql-db=$PRIMARY_DB --pgsql-user=`whoami` --pgsql-port=$PRIMARY_PORT --db-driver=pgsql --threads=5 --tables=$SYSBENCH_TABLES --time=60 --report-interval=10 run

encrypt_decrypt_wal 60 > /dev/null 2>&1 &
pid1=$!
rotate_wal_key 60 > /dev/null 2>&1 &
pid2=$!

wait $pid1
wait $pid2

echo "Read table data on subscriber db. It must have empty rows"
for i in $(seq 1 $SYSBENCH_TABLES); do
    cnt=$($INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -t -A \
        -c "SELECT count(*) FROM sbtest$i")

    if [ "$cnt" -ne 0 ]; then
        echo "❌ FAILURE: sbtest$i has $cnt rows (expected 0)"
        exit 1
    fi
done

echo "Create a Publication on the primary server"
$INSTALL_DIR/bin/psql -d $PRIMARY_DB -p $PRIMARY_PORT -c"CREATE PUBLICATION mypub for all tables;"

echo "Create a Subscription on the secondary server"
$INSTALL_DIR/bin/psql -d $REPLICA_DB -p $REPLICA_PORT -c"CREATE SUBSCRIPTION mysub connection 'dbname=$PRIMARY_DB host=localhost user=$(whoami) port=$PRIMARY_PORT' publication mypub;"

echo "Wait for sometime to sync data"
sleep 10
echo "Read table data on subscriber db. It must have rows"
for i in $(seq 1 $SYSBENCH_TABLES); do
    $INSTALL_DIR/bin/psql  -d $REPLICA_DB --port=$REPLICA_PORT -c"SELECT count(*) FROM sbtest$i"
done
