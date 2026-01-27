#!/bin/bash

# Config
PSQL=$INSTALL_DIR/bin/psql
PG_TDE_RESETWAL=$INSTALL_DIR/bin/pg_tde_resetwal
SYSBENCH=$(command -v sysbench)
SYSBENCH_TABLES=10
SYSBENCH_THREADS=5
DURATION=20
LUA_SCRIPT=/usr/share/sysbench/oltp_write_only.lua   # Adjust if different
KEYFILE="/tmp/keyring.per"

rotate_wal_key(){
    local duration=$1
    local end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
       RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
       echo "Rotating master key: principal_key_test$RAND_KEY"
       $PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','global_provider');"
       $PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','global_provider');"
    done
}


for iter in {1..3}; do
    echo -e "\n================= Iteration $iter =================\n"

    DATA_DIR=$RUN_DIR/pg_tde_resetwal_datadir_$iter

    # Cleanup
    old_server_cleanup $DATA_DIR
    rm -rf $KEYFILE

    echo "=> Initialise Data directory"
    initialize_server $DATA_DIR $PORT
    enable_pg_tde $DATA_DIR

    start_pg $DATA_DIR $PORT

    echo "=> Creating TDE keys"
    $PSQL -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '$KEYFILE');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

    restart_pg $DATA_DIR $PORT

    echo "=> Rotate WAL key"
    rotate_wal_key 10 > $RUN_DIR/sysbench.log 2>&1 &

    echo "=> Preparing 50 tables using sysbench"
    $SYSBENCH $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --table-size=1000 \
        prepare

    $PSQL -d postgres -p $PORT -c "CHECKPOINT;"
    echo "=> Rotate WAL key"
    rotate_wal_key 10 >> $RUN_DIR/sysbench.log 2>&1 &

    echo "=> Starting heavy sysbench write load for $DURATION seconds"
    $SYSBENCH $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --threads=$SYSBENCH_THREADS \
        --time=100 \
        run >> $RUN_DIR/sysbench.log &

    SYSBENCH_PID=$!
    sleep $DURATION


    echo "=> Killing PostgreSQL server after $DURATION seconds"
    PID=$(lsof -ti :$PORT)
    kill -9 $PID
    sleep 5

    rm -f $DATA_DIR/postmaster.pid

    echo "=> Running pg_tde_resetwal"
    $PG_TDE_RESETWAL -D "$DATA_DIR" -f

    echo "=> Starting PostgreSQL after pg_tde_resetwal"
    start_pg $DATA_DIR $PORT

    echo "=> Rotate WAL key"
    rotate_wal_key 10 >>$RUN_DIR/sysbench.log 2>&1 &

    echo "=> Performing additional writes"
        $SYSBENCH $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --threads=$SYSBENCH_THREADS \
        --time=30 \
        run >> $RUN_DIR/sysbench.log 2>&1

    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest1"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest2"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest3"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest4"

    echo "=> Stopping PostgreSQL"
    stop_pg $DATA_DIR
done
