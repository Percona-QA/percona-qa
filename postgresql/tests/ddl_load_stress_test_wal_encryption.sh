#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export INSTALL_DIR=/home/mohit.joshi/postgresql/pg_tde/bld_tde_17.4/install
export PGDATA=$INSTALL_DIR/data
export LOG_FILE=$PGDATA/server.log
export DB_NAME="sbtest"
export TABLE_PREFIX="ddl_test"
export TOTAL_TABLES=20

# initate the database
initialize_server() {
    PG_PID=$(sudo -u postgres lsof -ti :5432) || true
    if [[ -n "$PG_PID" ]]; then
        sudo -u postgres kill -9 $PG_PID
    fi
    sudo rm -rf $PGDATA
    sudo mkdir $PGDATA
    sudo chown postgres:postgres $PGDATA
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/initdb -D $PGDATA
    cat > "$PGDATA/postgresql.conf" <<SQL
shared_preload_libraries = 'pg_tde'
SQL
EOF
}

start_server() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
    $INSTALL_DIR/bin/createdb $DB_NAME
EOF
    $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c"CREATE EXTENSION pg_tde;"
    $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c"SELECT pg_tde_add_global_key_provider_file('local_keyring','$PGDATA/keyring.file');"
    $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c"SELECT pg_tde_set_server_principal_key('wal_key','local_keyring');"
    $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c"SELECT pg_tde_set_global_principal_key('table_key','local_keyring');"
    #$INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c"ALTER SYSTEM SET pg_tde.wal_encrypt='on';"
    PG_PID=$(sudo -u postgres lsof -ti :5432)
}


# Create multiple tables
create_tables() {
    for i in $(seq 1 $TOTAL_TABLES); do
        TABLE_NAME="${TABLE_PREFIX}_${i}"
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "
            CREATE TABLE IF NOT EXISTS $TABLE_NAME (
                id SERIAL PRIMARY KEY,
                data TEXT
            ) USING tde_heap;"
        echo "Created table: $TABLE_NAME"
    done
}

# Function to pick a random table
random_table() {
    echo "${TABLE_PREFIX}_$((RANDOM % TOTAL_TABLES + 1))"
}

# Function to generate random column names
generate_column_name() {
    echo "col_$(date +%s)_$RANDOM"
}

# Function to add a random column
add_column() {
    while true; do
        sleep 3
        TABLE=$(random_table)
        NEW_COLUMN=$(generate_column_name)
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "
            ALTER TABLE $TABLE ADD COLUMN $NEW_COLUMN TEXT DEFAULT 'default_value';"
        echo "ADD COLUMN: $NEW_COLUMN in table: $TABLE"
    done
}

# Function to drop a random column
drop_column() {
    while true; do
        sleep 3
        TABLE=$(random_table)
        COL_TO_DROP=$($INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -Atc "
            SELECT column_name
            FROM information_schema.columns
            WHERE table_name='$TABLE' AND column_name LIKE 'col_%'
            ORDER BY random()
            LIMIT 1;")
    
        if [ -n "$COL_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "
                ALTER TABLE $TABLE DROP COLUMN $COL_TO_DROP;"
            echo " DROPPED COLUMN: $COL_TO_DROP from table: $TABLE"
        fi
    done
}

# Function to create a random index
create_index() {
    while true; do
        sleep 5
        TABLE=$(random_table)
        INDEX_NAME="idx_$(date +%s)_$RANDOM"
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "
            CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
            ON $TABLE ((length(data)));"
        echo " Created index: $INDEX_NAME on table: $TABLE"
    done
}

# Function to drop a random index
drop_index() {
    while true; do
        sleep 10
        TABLE=$(random_table)
        INDEX_TO_DROP=$($INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -Atc "
            SELECT indexname
            FROM pg_indexes
            WHERE tablename='$TABLE' AND indexname LIKE 'idx_%'
            ORDER BY random()
            LIMIT 1;")

        if [ -n "$INDEX_TO_DROP" ]; then
            $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "DROP INDEX IF EXISTS $INDEX_TO_DROP;"
            echo "Dropped index: $INDEX_TO_DROP from table: $TABLE"
        fi
    done
}

# Function to run INSERT/UPDATE/DELETE load
run_load() {
    while true; do
        TABLE=$(random_table)
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "
            INSERT INTO $TABLE (data) VALUES ('Insert ' || now());
            UPDATE $TABLE SET data = 'Updated ' || now() WHERE id % 5 = 0;
            DELETE FROM $TABLE WHERE random() < 0.01;
        "
        sleep 2
    done
}

# Function to run VACUUM FULL and CHECKPOINT
run_maintenance() {
    while true; do
        sleep 15
        echo "Running VACUUM FULL and CHECKPOINT"
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "VACUUM FULL;"
        $INSTALL_DIR/bin/psql -U postgres -d $DB_NAME -c "CHECKPOINT;"
    done
}

crash_start() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA -l $LOG_FILE start
EOF
PG_PID=$(sudo -u postgres lsof -ti :5432)
}


crash_server() {
    value=$([ $(( RANDOM % 2 )) -eq 0 ] && echo "on" || echo "off")
    #echo "Altering WAL encryption to use $value..."
    #$INSTALL_DIR/bin/psql -U postgres -d sbtest -c "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
    echo "Killing the Server with PID=$PG_PID..."
    sudo -u postgres kill -9 $PG_PID
}

# Main load and DDL loop
initialize_server
start_server
create_tables         # Create initial tables

for i in {1..10}; do
    run_load &
    LOAD_PID=$!
    run_maintenance &
    MAINT_PID=$!
    add_column &
    ADD_PID=$!
    drop_column &
    DROP_PID=$!
    create_index &
    CREATE_PID=$!
    drop_index &
    DROP_PID=$!
    sleep 30
    crash_server
    sleep 2
    crash_start
done

# Cleanup
kill $LOAD_PID $MAINT_PID $ADD_PID $DROP_PID $CREATE_PID $DROP_PID
wait $LOAD_PID $MAINT_PID $ADD_PID $DROP_PID $CREATE_PID $DROP_PID 2>/dev/null
echo "Multi-table DDL stress test completed."

