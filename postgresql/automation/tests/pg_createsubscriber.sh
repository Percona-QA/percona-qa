#!/bin/bash

TABLES=200

rotate_server_key() {
    echo "Rotating server keys for 30 seconds..."

    local start_time=$(date +%s)
    local duration=30

    while [[ $(($(date +%s) - start_time)) -lt $duration ]]; do
        RAND=$RANDOM
        $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "SELECT pg_tde_create_key_using_global_key_provider('global_key$RAND','global_key_provider');" >/dev/null
        $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('global_key$RAND','global_key_provider');" >/dev/null
        sleep 2  # optional: adjust to control key rotation rate
    done
}

verify_streaming_replication() {
    echo "Creating verification table on primary..."
    $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "CREATE TABLE verify_replication(id INT PRIMARY KEY, val TEXT);" || exit 1
    $INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c "INSERT INTO verify_replication VALUES (1, 'streaming_test');" || exit 1

    echo "Waiting for replication to apply..."
    sleep 5

    echo "Checking data on replica..."
    result=$($INSTALL_DIR/bin/psql -d postgres -p $REPLICA_PORT -Atc "SELECT val FROM verify_replication WHERE id=1;" 2>/dev/null)

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
            primary_count=$($INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -Atc "SELECT count(*) FROM $table_name;" 2>/dev/null)
            replica_count=$($INSTALL_DIR/bin/psql -d postgres -p $REPLICA_PORT -Atc "SELECT count(*) FROM $table_name;" 2>/dev/null)

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
        --pgsql-port=$PRIMARY_PORT \
        --threads=10 \
        --tables=$TABLES \
        --table-size=3000 \
        --time=60 \
        run > /tmp/workload.log 2>&1 &
    WORKLOAD_PID=$!
}

run_pg_createsubscriber() {
    echo "Running pg_createsubscriber..."

    stop_pg $REPLICA_DATA
    sleep 10

    $INSTALL_DIR/bin/pg_createsubscriber \
        -d postgres \
        -D $REPLICA_DATA \
        --subscriber-port=$REPLICA_PORT \
	--subscriber-username=$(whoami) \
	--publisher-server="host=127.0.0.1 port=5433 dbname=postgres user=$(whoami)" \
        --publication=mypub \
        --subscription=mysub \
        --verbose

    start_pg $REPLICA_DATA $REPLICA_PORT
}

# Actual test starts here...

echo "1=>Cleaning any previous running server"
old_server_cleanup $PRIMARY_DATA
old_server_cleanup $REPLICA_DATA

echo "2=>Create Data Directory"
initialize_server $PRIMARY_DATA $PRIMARY_PORT

cat >> "$PRIMARY_DATA/postgresql.conf" <<SQL
wal_level=logical
logging_collector = on
log_directory = '$PRIMARY_DATA'
log_filename = 'server.log'
log_statement = 'all'
SQL

cat >> "$PRIMARY_DATA/pg_hba.conf" <<SQL
# Allow replication connections
host replication repuser 127.0.0.1/32 trust
SQL

echo "2=>Start Primary Server"
enable_pg_tde $PRIMARY_DATA
start_pg $PRIMARY_DATA $PRIMARY_PORT
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"CREATE USER repuser replication;"

echo "3=>Copy Primary Data Directory using pg_tde_basebackup"
$INSTALL_DIR/bin/pg_tde_basebackup -h localhost -U repuser --checkpoint=fast -D $REPLICA_DATA -R --slot=somename -C --port=$PRIMARY_PORT

sleep 5

cat >> "$REPLICA_DATA/postgresql.conf" <<SQL
port=$REPLICA_PORT
logging_collector = on
log_directory = '$REPLICA_DATA'
log_filename = 'server.log'
log_statement = 'all'
wal_level=logical
SQL

echo "3=>Start Replica Server"
start_pg $REPLICA_DATA $REPLICA_PORT

echo "4=>Install pg_tde extension and create keys on Primary Server"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_add_database_key_provider_file('local_key_provider','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_database_key_provider('local_key','local_key_provider');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_set_key_using_database_key_provider('local_key','local_key_provider');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_add_global_key_provider_file('global_key_provider','$PRIMARY_DATA/keyring.file');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_create_key_using_global_key_provider('global_key','global_key_provider');"
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"SELECT pg_tde_set_server_key_using_global_key_provider('global_key','global_key_provider');"

echo "5=>Create tables on Primary Server"
sysbench /usr/share/sysbench/oltp_insert.lua --pgsql-user=`whoami` --pgsql-db=postgres --db-driver=pgsql --pgsql-port=$PRIMARY_PORT --threads=5 --tables=$TABLES --table-size=3000 prepare

echo "6=>Verifying Streaming Replication"
verify_streaming_replication

echo "7=>Run workload in parallel on Primary Server"
run_workload_during_conversion
# Sleep for sometime to generate some WAL entries
sleep 10

# Enable WAL encryption
$INSTALL_DIR/bin/psql -d postgres -p $PRIMARY_PORT -c"ALTER SYSTEM SET pg_tde.wal_encrypt=ON"
stop_pg $PRIMARY_DATA
start_pg $PRIMARY_DATA $PRIMARY_PORT

run_workload_during_conversion
rotate_server_key &
# Sleep for sometime to generate some encrypted WAL entries with MK rotation
sleep 10

echo "7=>Convert physical replica into logical replica"
run_pg_createsubscriber

echo "8=>Verifying Logical Replication"
verify_logical_replication
