#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
       kill -9 $PG_PID
    fi
    sudo rm -rf $PGDATA
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    $INSTALL_DIR/bin/psql  -d postgres -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_global_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_add_database_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('principal_key','local_keyring');"
    $INSTALL_DIR/bin/psql  -d postgres -c"SELECT pg_tde_set_key_using_database_key_provider('principal_key','local_keyring');"
}

stop_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
}

restart_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
    $INSTALL_DIR/bin/pg_isready -p 5432 -t 60 >> $LOG_FILE 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Primary Server is Running..."
    else
        echo "❌ Primary Server is NOT Running..."
        exit 1
    fi
}

alter_encrypt_unencrypt_tables(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_TABLE=$(( ( RANDOM % 10 ) + 1 ))
        HEAP_TYPE=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "heap" || echo "tde_heap")
        echo "Altering table sbtest$RAND_TABLE to use $HEAP_TYPE..."
        $INSTALL_DIR/bin/psql  -d postgres -c "ALTER TABLE sbtest$RAND_TABLE SET ACCESS METHOD $HEAP_TYPE;" || true
        $INSTALL_DIR/bin/psql  -d postgres -c "ALTER TABLE sbtest${RAND_TABLE}_r SET ACCESS METHOD $HEAP_TYPE;" || true
    done
}

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
        RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
        echo "Rotating master key: principal_key_test$RAND_KEY"
        $INSTALL_DIR/bin/psql -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','local_keyring','true');" || echo "SQL command failed, continuing..."

    done
}

create_tables(){
    count=$1
    echo "Creating $count encrypted tables with 1000 records..."
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=$count --table-size=1000 prepare
}

run_read_write_load(){
    total_duration=$1
    count=$2
    end_time=$((SECONDS + total_duration))

    while [ $SECONDS -lt $end_time ]; do
        sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=$count --time=60 --report-interval=1 --events=1870000000 run
        sleep 1
    done
}


enable_disable_wal_encryption(){
    start_time=$1
    end_time=$((SECONDS + start_time))

    while [ $SECONDS -lt $end_time ]; do
        value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
        echo "Altering WAL encryption to use $value..."
        $INSTALL_DIR/bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
        sleep 1
    done
}

rename_tables() {
    start_time=$1
    end_time=$((SECONDS + start_time))
    suffix="_r"

    while [ $SECONDS -lt $end_time ]; do
        pick_random_table="sbtest$(( RANDOM % 10 + 1 ))"
        original=$pick_random_table
        renamed="${pick_random_table}${suffix}"

        # Check the current name and rename accordingly
        exists=$($INSTALL_DIR/bin/psql -d postgres -t -A -c "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN ('$original', '$renamed');" | tr -d ' ')

        if [[ "$exists" == "$original" ]]; then
            new_name=$renamed
        else
            new_name=$original
        fi

        echo "Renaming $exists to $new_name..."
        $INSTALL_DIR/bin/psql -d postgres -c "ALTER TABLE $exists RENAME TO $new_name;"
    done
}


crash_server() {
    PG_PID=$1
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

run_parallel_tests() {
    run_read_write_load 60 10 &
    rename_tables 60 &
    alter_encrypt_unencrypt_tables 60 > $INSTALL_DIR/alter_e_d.log 2>&1 &
}

read_tables(){
    echo "Reading original and renamed tables"
    for i in $(seq 1 10);do
        $INSTALL_DIR/bin/psql -d postgres -c "SELECT COUNT(*) FROM sbtest$i" || echo "Table does not exists yet"
    done
}


main() {
    initialize_server
    start_server
    create_tables 10
    for X in $(seq 1 1); do
        # Run Tests
        PG_PID=$( lsof -ti :5432)
        run_parallel_tests &
        sleep 20
        #crash_server $PG_PID
        #stop_server
    done

    # bash -c "sed -i 's/^shared_preload_libraries/#&/' $PGDATA/postgresql.conf"
    restart_server
    read_tables
}

main
