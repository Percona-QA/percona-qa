#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde_17.4/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
export DB_NAME="sbtest"
export PARTITION_PARENT="partitioned_table"
export TOTAL_PARTITIONS=5
export TABLESPACE_NAME="abc"
rm -rf /tmp/abc || true
mkdir -p /tmp/abc
chmod 700 /tmp/abc

# initate the database
initialize_server() {
    PG_PID=$(lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
       kill -9 $PG_PID
    fi
    rm -rf $PGDATA || true
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
log_statement = 'all'
log_directory = '$PGDATA'
SQL
}

start_server() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    sleep 5
    $INSTALL_DIR/bin/createdb $DB_NAME
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_add_global_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_set_server_principal_key('wal_key','local_keyring');"
    $INSTALL_DIR/bin/psql  -d $DB_NAME -c"SELECT pg_tde_set_global_principal_key('table_key','local_keyring');"
    PG_PID=$(lsof -ti :5432)

}

# Create a tablespace (if it doesn't exist)
create_tablespace() {
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "CREATE TABLESPACE $TABLESPACE_NAME LOCATION '/tmp/$TABLESPACE_NAME';"
    echo "Created tablespace: $TABLESPACE_NAME"
}

# Create a partitioned table and partitions
create_partitioned_table() {
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        CREATE TABLE IF NOT EXISTS $PARTITION_PARENT (
            id SERIAL,
            data TEXT,
            created_at DATE NOT NULL,
            PRIMARY KEY (id, created_at)
        ) PARTITION BY RANGE (created_at) USING tde_heap;"

    for i in $(seq 1 $TOTAL_PARTITIONS); do
        $INSTALL_DIR/bin/psql -d $DB_NAME -c "
            CREATE TABLE IF NOT EXISTS ${PARTITION_PARENT}_p$i
            PARTITION OF $PARTITION_PARENT
            FOR VALUES FROM ('2025-0$i-01') TO ('2025-0$((i + 1))-01') USING tde_heap;"
        echo "Created partition: ${PARTITION_PARENT}_p$i"
    done

    for i in $(seq 1 5000); do
    # Random date generation to fit within the partition ranges
    PARTITION_DATE="2025-$(printf "%02d" $((RANDOM % TOTAL_PARTITIONS + 1)))-$(printf "%02d" $((RANDOM % 28 + 1)))"

    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        INSERT INTO $PARTITION_PARENT (data, created_at)
        VALUES ('Sample data $i', '$PARTITION_DATE');" > /dev/null

done
}

# Function to rename random objects
rename_objects() {
    while true; do
        sleep 2
        TABLE=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            NEW_NAME="${TABLE}_renamed"
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $TABLE RENAME TO $NEW_NAME;"
            echo "Renamed table: $TABLE ➔ $NEW_NAME"
        fi
    done
}

# Function to move tables to a different tablespace
move_to_tablespace() {
    while true; do
        sleep 3
        TABLE=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $TABLE SET TABLESPACE $TABLESPACE_NAME;"
            echo " Moved $PARTITION_PARENT to tablespace: $TABLESPACE_NAME"
        fi
        TABLE=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $TABLE SET TABLESPACE pg_default;"
            echo " Moved $PARTITION_PARENT to tablespace: default"
        fi
    done
}

# Function to TRUNCATE a random table
truncate_table() {
    while true; do
        sleep 20
        TABLE=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "TRUNCATE TABLE $TABLE;"
            echo "Truncated table: $TABLE"
        fi
    done
}

run_dml() {
while true; do
    sleep 3
    RANDOM_UID=$((RANDOM % 1000 + 1))
    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        UPDATE $PARTITION_PARENT
        SET data = 'Updated data $RANDOM_UID'
        WHERE id = $RANDOM_UID;"

echo "updated successfully."

    #RANDOM_DID=$((RANDOM % 1000 + 1))
    #$INSTALL_DIR/bin/psql -d $DB_NAME -c "
    #    DELETE FROM $PARTITION_PARENT
    #    WHERE id = $RANDOM_DID;"
#echo "deleted successfully"
done

}

# Function to REINDEX a random table
reindex_table() {
    while true; do
        sleep 2
        TABLE=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "REINDEX TABLE $TABLE;"
            echo "Reindexed table: $TABLE"
        fi
    done
}

# Function to run maintenance tasks
run_maintenance() {
    while true; do
        sleep 10
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_start() {
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    PG_PID=$(lsof -ti :5432)
}


crash_server() {
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    echo "Altering WAL encryption to use $value..."
    $INSTALL_DIR/bin/psql  -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
}

# Create initial setup
initialize_server
start_server
create_tablespace
create_partitioned_table

#$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"
#$INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $PARTITION_PARENT SET TABLESPACE $TABLESPACE_NAME;"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"

exit 1

for i in {1..2}; do
    #rename_objects > /dev/null 2>&1 &
    #RENAME_PID=$!
    run_maintenance  &
    MAINT_PID=$!
    move_to_tablespace  2>&1 &
    MOVE_PID=$!
    #truncate_table > /dev/null 2>&1 &
    #TRUNC_PID=$!
    reindex_table  2>&1 &
    REINDEX_PID=$!
    run_dml &
    DML_PID=$!
    sleep 30
    crash_server
    sleep 2
    crash_start
done

$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"
echo "DDL stress test completed."
