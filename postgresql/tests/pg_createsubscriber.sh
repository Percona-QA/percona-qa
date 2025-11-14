#!/bin/bash

# Set variable
INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
PRIMARY_DATA=$INSTALL_DIR/primary_data
REPLICA_DATA=$INSTALL_DIR/replica_data
PRIMARY_LOGFILE=$PRIMARY_DATA/server.log
REPLICA_LOGFILE=$REPLICA_DATA/server.log
TABLES=200

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
io_method = 'sync'
logging_collector = on
log_directory = '$PRIMARY_DATA'
log_filename = 'server.log'
log_statement = 'all'
wal_level = 'logical'
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

stop_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir stop
}

start_server() {
    datadir=$1
    $INSTALL_DIR/bin/pg_ctl -D $datadir start
}

start_replica() {
    $INSTALL_DIR/bin/pg_tde_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=5433
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

disable_wal_encryption() {
	$INSTALL_DIR/bin/psql -d postgres -p 5433 -c"ALTER SYSTEM SET pg_tde.wal_encrypt=OFF"
	stop_server $PRIMARY_DATA
	start_server $PRIMARY_DATA
}

enable_wal_encryption() {
	$INSTALL_DIR/bin/psql -d postgres -p 5433 -c"ALTER SYSTEM SET pg_tde.wal_encrypt=ON"
	stop_server $PRIMARY_DATA
	start_server $PRIMARY_DATA
}

enable_tde_and_create_load() {
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_add_database_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_key_provider');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_key_provider');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_create_key_using_global_key_provider('global_key','global_key_provider');"
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_key','global_key_provider');"

    echo "Create some tables on Primary Node"
    sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=postgres --db-driver=pgsql --pgsql-port=5433 --threads=5 --tables=$TABLES --table-size=3000 prepare
}

rotate_server_key() {
    echo "Rotating server keys for 30 seconds..."

    local start_time=$(date +%s)
    local duration=30

    while [[ $(($(date +%s) - start_time)) -lt $duration ]]; do
        RAND=$RANDOM
        $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "SELECT pg_tde_create_key_using_global_key_provider('global_key$RAND','global_key_provider');" >/dev/null
        $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "SELECT pg_tde_set_server_key_using_global_key_provider('global_key$RAND','global_key_provider');" >/dev/null
        sleep 2  # optional: adjust to control key rotation rate
    done
}

verify_streaming_replication() {
    echo "Creating verification table on primary..."
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "CREATE TABLE verify_replication(id INT PRIMARY KEY, val TEXT);" || exit 1
    $INSTALL_DIR/bin/psql -d postgres -p 5433 -c "INSERT INTO verify_replication VALUES (1, 'streaming_test');" || exit 1

    echo "Waiting for replication to apply..."
    sleep 5

    echo "Checking data on replica..."
    result=$($INSTALL_DIR/bin/psql -d postgres -p 5434 -Atc "SELECT val FROM verify_replication WHERE id=1;" 2>/dev/null)

    if [[ "$result" == "streaming_test" ]]; then
        echo "Streaming replication is working correctly"
    else
        echo "Streaming replication failed or is delayed"
        exit 1
    fi
}

verify_logical_replication() {
    echo "Verifying logical replication of sysbench tables..."

    local retries=5
    local delay=5
    local all_tables_replicated=true

    for ((i=1; i<=TABLES; i++)); do
        table_name="sbtest$i"
        echo "Checking table: $table_name"

        attempt=1
        while (( attempt <= retries )); do
            primary_count=$($INSTALL_DIR/bin/psql -d postgres -p 5433 -Atc "SELECT count(*) FROM $table_name;" 2>/dev/null)
            replica_count=$($INSTALL_DIR/bin/psql -d postgres -p 5434 -Atc "SELECT count(*) FROM $table_name;" 2>/dev/null)

            if [[ "$primary_count" == "$replica_count" ]]; then
                echo "Table $table_name replicated successfully with $replica_count rows"
                break
            else
                echo "Mismatch (Attempt $attempt): Primary=$primary_count, Replica=$replica_count"
                ((attempt++))
                sleep $delay
            fi
        done

        if (( attempt > retries )); then
            echo "Table $table_name replication failed after $retries attempts"
            all_tables_replicated=false
        fi
    done

    if $all_tables_replicated; then
        echo "All sysbench tables successfully replicated via logical replication"
    else
        echo "One or more sysbench tables failed to replicate correctly"
        exit 1
    fi
}

run_workload_during_conversion() {
    echo "Running workload on primary during pg_createsubscriber execution..."

    sysbench /usr/share/sysbench/oltp_write_only.lua \
        --pgsql-user=$(whoami) \
        --pgsql-db=postgres \
        --db-driver=pgsql \
        --pgsql-port=5433 \
        --threads=10 \
        --tables=$TABLES \
        --table-size=3000 \
        --time=60 \
        run > /tmp/workload.log 2>&1 &
    WORKLOAD_PID=$!
}

run_pg_createsubscriber() {
    echo "Running pg_createsubscriber..."

    stop_server $REPLICA_DATA
    sleep 20

    $INSTALL_DIR/bin/pg_createsubscriber \
        -d postgres \
        -D $REPLICA_DATA \
        --subscriber-port=5434 \
	--subscriber-username=$(whoami) \
	--publisher-server="host=127.0.0.1 port=5433 dbname=postgres user=$(whoami)" \
        --publication=mypub \
        --subscription=mysub \
        --verbose

    start_server $REPLICA_DATA
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

echo "5=>Verifying Streaming Replication"
verify_streaming_replication

echo "6=>Run workload in parallel on Primary Server"
run_workload_during_conversion
sleep 15
enable_wal_encryption
run_workload_during_conversion
rotate_server_key &

echo "7=>Convert physical replica into logical replica"
run_pg_createsubscriber

echo "8=>Verifying Logical Replication"
verify_logical_replication
