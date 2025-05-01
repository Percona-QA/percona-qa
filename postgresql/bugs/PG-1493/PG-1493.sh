#!/bin/bash

###########################################################################################################
# PG-1503 - Deleting a Global key provider must not be allowed when we have active keys on the database   #
###########################################################################################################

TABLES=10
INSTALL_DIR=$HOME/postgresql/pg_tde/bld_tde/install
DATA_DIR=$INSTALL_DIR/data

initialize_server() {
    PG_PIDS=$(lsof -ti :5432 2>/dev/null) || true
    if [[ -n "$PG_PIDS" ]]; then
        echo "Killing PostgreSQL processes: $PG_PIDS"
        kill -9 $PG_PIDS
    fi
    rm -rf $DATA_DIR || true
    $INSTALL_DIR/bin/initdb -D $DATA_DIR > /dev/null 2>&1
    cat > "$DATA_DIR/postgresql.conf" <<SQL
port=5432
listen_addresses='*'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
logging_collector = on
log_directory = '$DATA_DIR'
log_filename = 'server.log'
log_statement = 'all'
SQL
}

# Setup
echo "=> Initialize Data Directory"
initialize_server
echo "..Successfully created data directory"

# Actual testing starts here
echo "Start PG server"
$INSTALL_DIR/bin/pg_ctl -D $DATA_DIR start > /dev/null 2>&1

echo "Create pg_tde extension"
$INSTALL_DIR/bin/psql -d postgres -c"CREATE EXTENSION pg_tde"

echo "Create a Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_add_global_key_provider_file('global_keyring','/tmp/keyring.file')"

echo "Create a Principal key using the Global Key Provider"
$INSTALL_DIR/bin/psql -d postgres -c"SELECT pg_tde_set_key_using_global_key_provider('local_key_of_db1_using_global_key_provider','global_keyring')"

echo "Create external tablespace"
rm -rf /tmp/custom_tablespace || true
mkdir /tmp/custom_tablespace
$INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLESPACE custom_tablespace LOCATION '/tmp/custom_tablespace'"

echo "Create $TABLES partitioned table"
for i in $(seq 1 $TABLES); do
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE IF NOT EXISTS partitioned_table${i} (id SERIAL,data TEXT,created_at DATE NOT NULL,PRIMARY KEY (id, created_at)) PARTITION BY RANGE (created_at)"
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE partition${i}_q1_2024 PARTITION OF partitioned_table${i} FOR VALUES FROM ('2024-01-01') TO ('2024-04-01')"
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE partition${i}_q2_2024 PARTITION OF partitioned_table${i} FOR VALUES FROM ('2024-04-01') TO ('2024-07-01')"
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE partition${i}_q3_2024 PARTITION OF partitioned_table${i} FOR VALUES FROM ('2024-07-01') TO ('2024-10-01')"
    $INSTALL_DIR/bin/psql -d postgres -c"CREATE TABLE partition${i}_q4_2024 PARTITION OF partitioned_table${i} FOR VALUES FROM ('2024-10-01') TO ('2025-01-01')"
done

echo "Insert a record"
for i in $(seq 1 $TABLES); do
    for j in $(seq 1 5); do  # Insert 5 rows per table
        data="RandomData_${i}_${j}"
        date=$((RANDOM % 365)) # Generate a random offset for days
        created_at=$(date -d "2024-01-01 +$date days" "+%Y-%m-%d")

        echo "Inserting into partitioned_table${i}: $data - $created_at"
        $INSTALL_DIR/bin/psql -d postgres -c "INSERT INTO partitioned_table${i} (data, created_at) VALUES ('$data', '$created_at')"
    done
done

echo "Alter table to use external tablespace"
for i in $(seq 1 $TABLES); do
    $INSTALL_DIR/bin/psql -d postgres -c"ALTER TABLE partitioned_table${i} SET TABLESPACE custom_tablespace"
    $INSTALL_DIR/bin/psql -d postgres -c"ALTER TABLE partitioned_table${i} SET TABLESPACE pg_default"
    $INSTALL_DIR/bin/psql -d postgres -c"ALTER TABLE partitioned_table${i} SET TABLESPACE custom_tablespace"
done

echo "Query the tables"
for i in $(seq 1 $TABLES); do
    $INSTALL_DIR/bin/psql -d postgres -c"SELECT count(*) FROM partitioned_table${i}"
done

echo "Restart server"
$INSTALL_DIR/bin/pg_ctl -D $DATA_DIR restart > /dev/null 2>&1

for i in $(seq 1 $TABLES); do
    for j in $(seq 1 4); do
        ENCRYPTED_STATUS=$($INSTALL_DIR/bin/psql -d postgres -t -A -c "SELECT pg_tde_is_encrypted('partition${i}_q${j}_2024')")
        if [ $ENCRYPTED_STATUS == "f" ]; then
            echo "Table name : partitioned_table${i}_q${j}_2024 is not encrypted"
            exit 1
        fi
    done
    echo "Table partitioned_table${i} verified successfully"
done
