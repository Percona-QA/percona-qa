#!/bin/bash

# Config
INSTALL_DIR=$HOME/postgresql/bld_tde/install
PG_CTL=$INSTALL_DIR/bin/pg_ctl
INITDB=$INSTALL_DIR/bin/initdb
PSQL=$INSTALL_DIR/bin/psql
PG_RESETWAL=$INSTALL_DIR/bin/pg_resetwal
PORT=5432
SYSBENCH_TABLES=10
SYSBENCH_THREADS=5
DURATION=20
LUA_SCRIPT=/usr/share/sysbench/oltp_write_only.lua   # Adjust if different

rotate_wal_key(){
    duration=$1
    end_time=$((SECONDS + duration))

    while [ $SECONDS -lt $end_time ]; do
       RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))
       echo "Rotating master key: principal_key_test$RAND_KEY"
       $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('principal_key_test$RAND_KEY','global_provider');"
       $INSTALL_DIR/bin/psql -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('principal_key_test$RAND_KEY','global_provider');"
    done
}


for iter in {1..10}; do
    echo -e "\n================= Iteration $iter =================\n"

    DATA_DIR=$INSTALL_DIR/pg_resetwal_test_data_$iter
    LOGFILE=$DATA_DIR/server.log

    # Cleanup
    PID=$(lsof -ti :$PORT)
    if [ -n "$PID" ]; then
        echo "Killing existing PostgreSQL on port $PORT"
        kill -9 $PID || true
    fi
    rm -rf "$DATA_DIR" /tmp/keyring.per

    echo "=> Initialise Data directory"
    "$INITDB" -D "$DATA_DIR" > /dev/null

    # PostgreSQL configuration
    echo "shared_preload_libraries = 'pg_tde'" >> $DATA_DIR/postgresql.conf
    echo "default_table_access_method = 'tde_heap'" >> $DATA_DIR/postgresql.conf
    echo "port = $PORT" >> $DATA_DIR/postgresql.conf

    echo "=> Starting PostgreSQL"
    $PG_CTL -D "$DATA_DIR" -l "$LOGFILE" start
    sleep 2

    echo "=> Creating TDE keys"
    $PSQL -d postgres -p $PORT -c "CREATE EXTENSION pg_tde;"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_provider', '/tmp/keyring.per');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('database_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('database_key', 'global_provider');"
    $PSQL -d postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;"

    echo "=> Restarting PostgreSQL with WAL encryption"
    $PG_CTL -D "$DATA_DIR" -l "$LOGFILE" restart
    sleep 2

    rotate_wal_key 10 &

    echo "=> Preparing 50 tables using sysbench"
    sysbench $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --table-size=1000 \
        prepare

    $PSQL -d postgres -p $PORT -c "CHECKPOINT;"

    rotate_wal_key $DURATION &

    echo "=> Starting heavy sysbench write load for $DURATION seconds"
    sysbench $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --threads=$SYSBENCH_THREADS \
        --time=100 \
        run &

    SYSBENCH_PID=$!
    sleep $DURATION


    echo "=> Killing PostgreSQL server after $DURATION seconds"
    PID=$(lsof -ti :$PORT)
    kill -9 $PID
    sleep 2

    rm -f $DATA_DIR/postmaster.pid

    echo "=> Running pg_resetwal"
    $PG_RESETWAL -D "$DATA_DIR" -f

    echo "=> Restarting PostgreSQL after pg_resetwal"
    $PG_CTL -D "$DATA_DIR" -l "$LOGFILE" start
    sleep 2

    rotate_wal_key $DURATION &

    echo "=> Performing additional writes"
        sysbench $LUA_SCRIPT \
        --db-driver=pgsql \
        --pgsql-host=127.0.0.1 \
        --pgsql-port=$PORT \
        --pgsql-user=$USER \
        --pgsql-db=postgres \
        --tables=$SYSBENCH_TABLES \
        --threads=$SYSBENCH_THREADS \
        --time=30 \
        run

    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest1"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest2"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest3"
    $PSQL -d postgres -p $PORT -c "SELECT COUNT(*) FROM sbtest4"

    echo "=> Stopping PostgreSQL"
    $PG_CTL -D "$DATA_DIR" stop
    sleep 2
done

echo -e "\n✅ All iterations complete. Check logs and data folders under: $INSTALL_DIR"

