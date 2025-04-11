#!/bin/bash

# Set variable
export INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
export wal_encrypt_flag=off

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
        kill -9 $PG_PID
    fi
    rm -rf $LOG_FILE || true
    rm -rf $PGDATA || true
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
SQL
}

start_server() {
    echo "Going to start the server"
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo "Check Server Logs for the error: $PGDATA/server.log"
        grep "invalid magic number" "$PGDATA/server.log"
        exit 1
    else
        PG_PID=$(lsof -ti :5432)
    fi
}

run_sysbench_load(){
    duration=$1
    sysbench /usr/share/sysbench/oltp_read_write.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=10 --tables=100 --time=$duration --report-interval=1 --events=1870000000 run
}

crash_server() {
    if [ $wal_encrypt_flag == "on" ]; then
        wal_encrypt_flag="off"
    else
        wal_encrypt_flag="on"
    fi

    echo "Altering WAL encryption to use $wal_encrypt_flag..."
    $INSTALL_DIR/bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$wal_encrypt_flag';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

initialize_server
start_server

echo "Enabling TDE and setting Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file')"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_server_key_using_global_key_provider('wal_encryption_key','global_keyring')"
echo "Creating Sysbench tables"
sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-db=postgres --pgsql-user=`whoami` --db-driver=pgsql --threads=5 --tables=10 --table-size=100 prepare

for X in $(seq 1 10); do
    # Run Tests
    run_sysbench_load 300 > $INSTALL_DIR/sysbench.log 2>&1 &
    sleep 10
    # Change WAL encryption and crash the server
    crash_server
    sleep 5
    start_server
done

if grep -q "invalid" "$LOG_FILE"; then
    echo "ERROR Found: Invalid magic number in Logs: $LOG_FILE"
    exit 1
else
    echo "Test passed successfully ✅"
fi
