#!/bin/bash

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde_17.4/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
export DB_NAME="sbtest"
export PARTITION_PARENT="partitioned_table"
export TOTAL_PARTITIONS=5
export TABLESPACE_NAME="custom_tablespace"
rm -rf /tmp/$TABLESPACE_NAME || true
mkdir -p /tmp/$TABLESPACE_NAME

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

    for i in $(seq 1 1000); do
    # Random date generation to fit within the partition ranges
    PARTITION_DATE="2025-$(printf "%02d" $((RANDOM % TOTAL_PARTITIONS + 1)))-$(printf "%02d" $((RANDOM % 28 + 1)))"

    $INSTALL_DIR/bin/psql -d $DB_NAME -c "
        INSERT INTO $PARTITION_PARENT (data, created_at)
        VALUES ('Sample data $i', '$PARTITION_DATE');"
done
}

# Create initial setup
initialize_server
start_server
create_tablespace
create_partitioned_table

echo "Count of rows in the table before moving the table to external tablespace"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"
echo "Moving the table $TABLE to external tablespace $TABLESPACE_NAME"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $PARTITION_PARENT SET TABLESPACE $TABLESPACE_NAME;"
echo "Count of rows after migration"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"

echo "Try to move the table back to pg_default"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "ALTER TABLE $PARTITION_PARENT SET TABLESPACE pg_default;"

echo "Count of rows after migration"
$INSTALL_DIR/bin/psql  -d $DB_NAME -c "SELECT COUNT(*) FROM $PARTITION_PARENT"
