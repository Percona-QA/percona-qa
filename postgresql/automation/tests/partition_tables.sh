#!/bin/bash

# Set variable
DB_NAME="sbtest"
PARTITION_PARENT="partitioned_table"
TOTAL_PARTITIONS=5
TABLESPACE_NAME="extern_tbsp"

# Cleanup
rm -rf /tmp/$TABLESPACE_NAME
mkdir -p /tmp/$TABLESPACE_NAME
chmod 700 /tmp/$TABLESPACE_NAME

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

    for i in $(seq 1 50); do
    # Random date generation to fit within the partition ranges
    PARTITION_DATE="2025-$(printf "%02d" $((RANDOM % TOTAL_PARTITIONS + 1)))-$(printf "%02d" $((RANDOM % 28 + 1)))"

    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        INSERT INTO $PARTITION_PARENT (data, created_at)
        VALUES ('Sample data $i', '$PARTITION_DATE');" > /dev/null
    done
}

# Function to rename random objects
rename_objects() {
    local duration=$1
    local end=$((SECONDS + duration))
    while [ $SECONDS -lt $end ]; do
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
    local duration=$1
    local end=$((SECONDS + duration))
    while [ $SECONDS -lt $end ]; do
        sleep 3
        TABLE=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql -d $DB_NAME -c "ALTER TABLE $TABLE SET TABLESPACE $TABLESPACE_NAME;"
            echo " Moved $PARTITION_PARENT to tablespace: $TABLESPACE_NAME"
        fi
        TABLE=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql -d $DB_NAME -c "ALTER TABLE $TABLE SET TABLESPACE pg_default;"
            echo " Moved $PARTITION_PARENT to tablespace: default"
        fi
    done
}

# Function to TRUNCATE a random table
truncate_table() {
    local duration=$1
    local end=$((SECONDS + duration))
    while [ $SECONDS -lt $end ]; do
        sleep 20
        TABLE=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql  -d $DB_NAME -c "TRUNCATE TABLE $TABLE;"
            echo "Truncated table: $TABLE"
        fi
    done
}

run_dml() {
    local duration=$1
    local end=$((SECONDS + duration))
    while [ $SECONDS -lt $end ]; do
        sleep 3
        RANDOM_UID=$((RANDOM % 1000 + 1))
        TABLE=$($INSTALL_DIR/bin/psql -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
        if [ -n "$TABLE" ]; then
            $INSTALL_DIR/bin/psql -d $DB_NAME -c "UPDATE $TABLE SET data = 'Updated data $RANDOM_UID' WHERE id = $RANDOM_UID;"
            echo "Row Updated successfully."
        fi
    done
}

# Function to REINDEX a random table
reindex_table() {
   local duration=$1
   local end=$((SECONDS + duration))
   while [ $SECONDS -lt $end ]; do
       sleep 2
       TABLE=$($INSTALL_DIR/bin/psql  -d $DB_NAME -Atc "SELECT table_name FROM information_schema.tables WHERE table_name LIKE '$PARTITION_PARENT%' ORDER BY random() LIMIT 1;")
       if [ -n "$TABLE" ]; then
          $INSTALL_DIR/bin/psql -d $DB_NAME -c "REINDEX TABLE $TABLE;"
          echo "Reindexed table: $TABLE"
       fi
   done
}

# Function to run maintenance tasks
run_maintenance() {
    local duration=$1
    local end=$((SECONDS + duration))
    while [ $SECONDS -lt $end ]; do
        sleep 10
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql  -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_server_with_wal_encrypt_flip() {
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    echo "Altering WAL encryption to use $value..."
    $INSTALL_DIR/bin/psql  -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
    echo "Killing the Server with PID=$PG_PID..."
    kill -9 $PG_PID
    sleep 5
}

# Actual test starts here...

# Old server cleanup
old_server_cleanup $PGDATA

# Create data directory
initialize_server $PGDATA $PORT

# Start PG server and enable TDE
enable_pg_tde $PGDATA
start_pg $PGDATA $PORT
PG_PID=$(lsof -ti :$PORT)

$INSTALL_DIR/bin/createdb $DB_NAME
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "CREATE EXTENSION pg_tde;"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_keyring','$PGDATA/keyring.file');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('table_key','global_keyring');"
$INSTALL_DIR/bin/psql -d $DB_NAME -p $PORT -c "SELECT pg_tde_set_key_using_global_key_provider('table_key','global_keyring');"

create_tablespace
create_partitioned_table

# Run parallel SQLs
rename_objects 60 > /dev/null 2>&1 &
RENAME_PID=$!

run_maintenance 60 > /dev/null 2>&1 &
MAINT_PID=$!

move_to_tablespace 60 > /dev/null 2>&1 &
MOVE_PID=$!

truncate_table 60 > /dev/null 2>&1 &
TRUNC_PID=$!

reindex_table 60 > /dev/null 2>&1 &
REINDEX_PID=$!

run_dml 60 > /dev/null 2>&1 &
DML_PID=$!

$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"

for i in {1..2}; do
    # Let the SQLs run for sometime
    sleep 20
    crash_server_with_wal_encrypt_flip
    sleep 1
    start_pg $PGDATA $PORT
    PG_PID=$(lsof -ti :$PORT)

    wait
done

echo "DDL stress test completed."
