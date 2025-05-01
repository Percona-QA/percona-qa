#!/bin/bash

# Set variable
INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
DB_NAME=mohit
TABLES=10
WAL_ENCRYPT=OFF

# initate the database
initialize_server() {
    PG_PIDS=$(lsof -ti :5433 -ti :5434 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $PRIMARY_DATA $REPLICA_DATA
    $INSTALL_DIR/bin/initdb -D $PRIMARY_DATA > /dev/null 2>&1
    cat > "$PRIMARY_DATA/postgresql.conf" <<SQL
port=5433
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
logging_collector = on
log_directory = '$PRIMARY_DATA'
log_filename = 'server.log'
log_statement = 'all'
default_table_access_method = 'tde_heap'
SQL

    cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL
}

start_primary() {
    $INSTALL_DIR/bin/pg_ctl -D $PRIMARY_DATA start -l $PRIMARY_LOGFILE > $PRIMARY_LOGFILE 2>&1
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE USER repuser replication;"
}

restart_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir restart
}

start_replica() {
    $INSTALL_DIR/bin/pg_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=5433
    sleep 5
    cat >> "$REPLICA_DATA/postgresql.conf" <<SQL
port=5434
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
SQL
    $INSTALL_DIR/bin/pg_ctl -D $REPLICA_DATA -l $REPLICA_LOGFILE start
    
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))
    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql -d $DB_NAME -p 5433 -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;"
        sleep 1
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating Global master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','global_key_provider','true');" || echo "SQL command failed, continuing..."
        sleep 5
    done
}

run_sysbench_load(){
    time=$1
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=10 --tables=$TABLES --time=$time --report-interval=1 --events=1870000000 run &
    sysbench /usr/share/sysbench/oltp_delete.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=10 --tables=$TABLES --time=$time --table-size=1000 &
    sysbench /usr/share/sysbench/oltp_update_index.lua --pgsql-user=mohit.joshi --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=10 --tables=$TABLES --time=$time --table-size=1000 &

}

rotate_master_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key_test$RAND_KEY','local_key_provider','true');" || echo "SQL command failed, continue..."
        sleep 5
    done
}

crash_replica_server() {
    REPLICA_PID=$( lsof -ti :5434)
    echo "Killing the Replica Server with PID=$REPLICA_PID..."
    kill -9 $REPLICA_PID
}

crash_primary_server() {
    PRIMARY_PID=$( lsof -ti :5433)
    if [ $WAL_ENCRYPT == "ON" ]; then
        WAL_ENCRYPT=OFF
    elif [ $WAL_ENCRYPT == "OFF" ]; then
        WAL_ENCRYPT=ON
    fi
    echo "Altering WAL encryption to use $WAL_ENCRYPT..."
    $INSTALL_DIR/bin/psql -d $DB_NAME  -p 5433 -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$WAL_ENCRYPT';"
    echo "Killing the Primary Server with PID=$PRIMARY_PID"
    kill -9 $PRIMARY_PID
}

enable_tde_and_create_load() {
    $INSTALL_DIR/bin/psql  -d postgres -p 5433 -c"CREATE DATABASE $DB_NAME;"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"CREATE EXTENSION IF NOT EXISTS pg_tde;"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_add_database_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_key_provider');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -p 5433 -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_key','global_key_provider');"

    echo "Create some tables on Primary Node"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=1000 prepare
    sysbench /usr/share/sysbench/bulk_insert.lua --pgsql-user=`whoami` --pgsql-db=$DB_NAME --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=1000
}

# Actual test starts here...

echo "1=>Create Data Directory"
initialize_server

echo "2=>Start Primary Server"
start_primary

echo "3=>Start Replica Server"
start_replica

echo "4=>Enable pg_tde on Primary Server"
enable_tde_and_create_load

echo "Running Sysbench Load"
run_sysbench_load 300 > /dev/null 2>&1 &
rotate_wal_key 300 >/dev/null 2>&1 &
rotate_master_key 300 >/dev/null 2>&1  &
alter_encrypt_unencrypt_tables 300   > /dev/null 2>&1 &

for i in $(seq 1 5); do
    sleep 20
    crash_replica_server
    sleep 30
    echo "Restarting Replica Server"
    restart_server $REPLICA_DATA
    sleep 30
    crash_primary_server
    sleep 30
    echo "Restarting Primary Server"
    restart_server $PRIMARY_DATA
done

echo "Verify table and data between primary and replica node..."
sleep 30
error_flag=0
for i in $(seq 1 $TABLES); do
    PRIMARY_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p 5433 -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    REPLICA_COUNT=$($INSTALL_DIR/bin/psql -d $DB_NAME -p 5434 -t -A -c"SELECT COUNT(*) FROM sbtest$i;")
    if [ "$PRIMARY_COUNT" -ne "$REPLICA_COUNT" ]; then
        echo "Mismatch in table sbtest$i: Primary($PRIMARY_COUNT) != Replica($REPLICA_COUNT)"
        exit 1
    else
        echo "Rows match in table sbtest$i: Primary($PRIMARY_COUNT) = Replica($REPLICA_COUNT)"
    fi
done
