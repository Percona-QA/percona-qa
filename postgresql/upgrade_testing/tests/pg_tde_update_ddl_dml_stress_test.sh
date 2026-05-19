#!/bin/bash

#############################################
# CONFIG
#############################################

KEYFILE="$RUN_DIR/pg_tde_upgrade.key"
KEYFILE2="$RUN_DIR/pg_tde_upgrade2.key"

OLD_MAJOR=$(get_pg_major_version "$OLD_INSTALL_DIR")
NEW_MAJOR=$(get_pg_major_version "$NEW_INSTALL_DIR")

DB_NAME="postgres"

TOTAL_TABLES=20
TABLE_PREFIX="ddl_test"

DDL_RUNTIME=120

echo "=== pg_tde pg_upgrade stress test ==="
echo "    Old cluster: PG-${OLD_MAJOR} at $OLD_INSTALL_DIR"
echo "    New cluster: PG-${NEW_MAJOR} at $NEW_INSTALL_DIR"

#############################################
# CLEANUP
#############################################

cleanup_background_jobs() {
    jobs -p | xargs -r kill || true
    wait || true
}

trap cleanup_background_jobs EXIT

rm -f "$KEYFILE" || true
rm -f "$KEYFILE2" || true

old_server_cleanup "$OLD_PGDATA" "$OLD_PORT"
old_server_cleanup "$NEW_PGDATA" "$NEW_PORT"

#############################################
# INIT OLD CLUSTER
#############################################

echo "1. Initializing old cluster (PG-${OLD_MAJOR})..."

initialize_server "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"
enable_pg_tde "$OLD_PGDATA"
start_pg "$OLD_PGDATA" "$OLD_PORT" "$OLD_INSTALL_DIR"

#############################################
# SETUP pg_tde
#############################################

echo "2. Setting up pg_tde and encryption..."

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "CREATE EXTENSION pg_tde;"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_add_database_key_provider_file('local_keyring', '$KEYFILE');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_create_key_using_database_key_provider('principal_key_1', 'local_keyring');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_set_key_using_database_key_provider('principal_key_1', 'local_keyring');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_add_global_key_provider_file('global_keyring', '$KEYFILE2');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_create_key_using_global_key_provider('server_key_1', 'global_keyring');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "SELECT pg_tde_set_key_using_global_key_provider('server_key_1', 'global_keyring');"

$OLD_INSTALL_DIR/bin/psql -p "$OLD_PORT" -d postgres -h "$PGHOST" \
-c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

#############################################
# CREATE TABLES
#############################################

create_tables() {

  for t in $(seq 1 $TOTAL_TABLES); do

    TABLE_NAME="${TABLE_PREFIX}_${t}"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
       CREATE TABLE IF NOT EXISTS $TABLE_NAME (
          id SERIAL PRIMARY KEY,
          data TEXT
       ) USING tde_heap;"

    echo "Created table: $TABLE_NAME"

    for r in $(seq 1 100); do

      $OLD_INSTALL_DIR/bin/psql \
        -p $OLD_PORT \
        -d $DB_NAME \
        -h "$PGHOST" \
        -c "
        INSERT INTO $TABLE_NAME (data)
        VALUES ('Test record $r');"

    done

  done
}

#############################################
# RANDOM TABLE
#############################################

random_table() {
    echo "${TABLE_PREFIX}_$((RANDOM % TOTAL_TABLES + 1))"
}

#############################################
# RANDOM COLUMN NAME
#############################################

generate_column_name() {
    echo "col_$(date +%s)_$RANDOM"
}

#############################################
# ADD COLUMN
#############################################

add_column() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 3

    TABLE=$(random_table)
    NEW_COLUMN=$(generate_column_name)

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      ALTER TABLE $TABLE
      ADD COLUMN $NEW_COLUMN TEXT DEFAULT 'default_value';" || true

    echo "ADD COLUMN: $NEW_COLUMN in table: $TABLE"

  done
}

#############################################
# DROP COLUMN
#############################################

drop_column() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 3

    TABLE=$(random_table)

    COL_TO_DROP=$(
      $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -Atc "
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name='$TABLE'
          AND column_name LIKE 'col_%'
        ORDER BY random()
        LIMIT 1;"
    )

    if [ -n "$COL_TO_DROP" ]; then

       $OLD_INSTALL_DIR/bin/psql \
         -d $DB_NAME \
         -p $OLD_PORT \
         -h "$PGHOST" \
         -c "
         ALTER TABLE $TABLE
         DROP COLUMN $COL_TO_DROP;" || true

       echo "DROPPED COLUMN: $COL_TO_DROP from table: $TABLE"

    fi

  done
}

#############################################
# CREATE INDEX
#############################################

create_index() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    TABLE=$(random_table)
    INDEX_NAME="idx_$(date +%s)_$RANDOM"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
      ON $TABLE ((length(data)));" || true

    echo "Created index: $INDEX_NAME on table: $TABLE"

  done
}

#############################################
# DROP INDEX
#############################################

drop_index() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    TABLE=$(random_table)

    INDEX_TO_DROP=$(
      $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -Atc "
        SELECT indexname
        FROM pg_indexes
        WHERE tablename='$TABLE'
          AND indexname LIKE 'idx_%'
        ORDER BY random()
        LIMIT 1;"
    )

    if [ -n "$INDEX_TO_DROP" ]; then

      $OLD_INSTALL_DIR/bin/psql \
        -d $DB_NAME \
        -p $OLD_PORT \
        -h "$PGHOST" \
        -c "
        DROP INDEX IF EXISTS $INDEX_TO_DROP;" || true

      echo "Dropped index: $INDEX_TO_DROP"

    fi

  done
}

#############################################
# DROP TABLE / RECREATE
#############################################

drop_recreate_table() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    TABLE=$(random_table)

    echo "Dropping table: $TABLE"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "DROP TABLE IF EXISTS $TABLE;" || true

    echo "Recreating table: $TABLE"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      CREATE TABLE $TABLE (
          id SERIAL PRIMARY KEY,
          data TEXT
      ) USING tde_heap;" || true

    for r in $(seq 1 20); do

      $OLD_INSTALL_DIR/bin/psql \
        -d $DB_NAME \
        -p $OLD_PORT \
        -h "$PGHOST" \
        -c "
        INSERT INTO $TABLE(data)
        VALUES ('recreated row $r');" || true

    done

  done
}

#############################################
# VACUUM FULL / CHECKPOINT
#############################################

run_maintenance() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    echo "Running VACUUM FULL"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "VACUUM FULL;" || true

    echo "Running CHECKPOINT"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "CHECKPOINT;" || true

  done
}

#############################################
# ALTER ACCESS METHOD
#############################################

alter_encrypt_unencrypt_tables() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    RAND_TABLE=$(( ( RANDOM % TOTAL_TABLES ) + 1 ))

    HEAP_TYPE=$(
      [ $(( RANDOM % 2 )) -eq 0 ] \
      && echo "heap" \
      || echo "tde_heap"
    )

    echo "Altering table ddl_test_$RAND_TABLE to use $HEAP_TYPE"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      ALTER TABLE ddl_test_$RAND_TABLE
      SET ACCESS METHOD $HEAP_TYPE;" || true

  done
}

#############################################
# MASTER KEY ROTATION
#############################################

rotate_master_key() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    RAND_KEY=$(( ( RANDOM % 1000000 ) + 1 ))

    echo "Rotating master key: principal_key_test$RAND_KEY"

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      SELECT pg_tde_create_key_using_database_key_provider(
      'principal_key_test$RAND_KEY',
      'local_keyring');" || true

    $OLD_INSTALL_DIR/bin/psql \
      -d $DB_NAME \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      SELECT pg_tde_set_key_using_database_key_provider(
      'principal_key_test$RAND_KEY',
      'local_keyring');" || true

     $OLD_INSTALL_DIR/bin/psql \
       -d $DB_NAME \
       -p $OLD_PORT \
       -c "
       SELECT pg_tde_create_key_using_global_key_provider(
       'server_key_test$RAND_KEY',
       'global_keyring');" || true

      $OLD_INSTALL_DIR/bin/psql \
        -d $DB_NAME \
        -p $OLD_PORT \
	-c "
	SELECT pg_tde_set_server_key_using_global_key_provider(
	'server_key_test$RAND_KEY',
	'global_keyring');" || true

  done
}

#############################################
# WAL COMPRESSION
#############################################

compress_wal() {

  local duration="$1"
  local end=$((SECONDS + duration))

  while [ $SECONDS -lt $end ]; do

    sleep 5

    value=$(
      [ $(( RANDOM % 2 )) -eq 0 ] \
      && echo "on" \
      || echo "off"
    )

    echo "wal_compression=$value"

    $OLD_INSTALL_DIR/bin/psql \
      -d postgres \
      -p $OLD_PORT \
      -h "$PGHOST" \
      -c "
      ALTER SYSTEM SET wal_compression=$value;" || true

  done
}

#############################################
# CREATE INITIAL DATA
#############################################

echo "3. Creating encrypted tables..."

create_tables

#############################################
# RUN DDL + DML STRESS
#############################################

echo "4. Running DDL/DML stress workload for ${DDL_RUNTIME}s..."

add_column "$DDL_RUNTIME" &
drop_column "$DDL_RUNTIME" &
create_index "$DDL_RUNTIME" &
drop_index "$DDL_RUNTIME" &
run_maintenance "$DDL_RUNTIME" &
alter_encrypt_unencrypt_tables "$DDL_RUNTIME" &
rotate_master_key "$DDL_RUNTIME" &
compress_wal "$DDL_RUNTIME" &
drop_recreate_table "$DDL_RUNTIME" &

wait

echo "DDL/DML stress completed"

#############################################
# CAPTURE ROW COUNTS
#############################################

echo "5. Capturing row counts before upgrade..."

declare -A ROW_COUNTS_BEFORE

for t in $(seq 1 $TOTAL_TABLES); do

    TABLE_NAME="${TABLE_PREFIX}_${t}"

    EXISTS=$(
      $OLD_INSTALL_DIR/bin/psql \
      -p "$OLD_PORT" \
      -d postgres \
      -h "$PGHOST" \
      -Atc "
      SELECT count(*)
      FROM pg_class
      WHERE relname='$TABLE_NAME';"
    )

    if [ "$EXISTS" -eq 1 ]; then

        COUNT=$(
          $OLD_INSTALL_DIR/bin/psql \
          -p "$OLD_PORT" \
          -d postgres \
          -h "$PGHOST" \
          -Atc "
          SELECT count(*) FROM $TABLE_NAME;" \
          || echo "0"
        )

        ROW_COUNTS_BEFORE[$TABLE_NAME]=$COUNT

        echo "$TABLE_NAME => $COUNT"

    fi

done

#############################################
# STOP OLD CLUSTER
#############################################

echo "6. Stopping old cluster..."

stop_pg "$OLD_PGDATA" "$OLD_INSTALL_DIR"

#############################################
# INIT NEW CLUSTER
#############################################

echo "7. Initializing new cluster..."

if [[ "$OLD_MAJOR" == "17" && "$NEW_MAJOR" != "17" ]]; then

  initialize_server \
    "$NEW_PGDATA" \
    "$NEW_PORT" \
    "$NEW_INSTALL_DIR" \
    "--no-data-checksums"

else

  initialize_server \
    "$NEW_PGDATA" \
    "$NEW_PORT" \
    "$NEW_INSTALL_DIR"

fi

enable_pg_tde "$NEW_PGDATA"

#############################################
# RUN pg_tde_upgrade
#############################################

echo "8. Running pg_tde_upgrade..."

$NEW_INSTALL_DIR/bin/pg_tde_upgrade \
  --no-sync \
  --old-datadir "$OLD_PGDATA" \
  --new-datadir "$NEW_PGDATA" \
  --old-bindir "$OLD_INSTALL_DIR/bin" \
  --new-bindir "$NEW_INSTALL_DIR/bin" \
  --socketdir "$RUN_DIR" \
  --old-port "$OLD_PORT" \
  --new-port "$NEW_PORT"

echo "[PASS] pg_tde_upgrade completed"

#############################################
# CONFIGURE NEW CLUSTER
#############################################

cat >> "$NEW_PGDATA/postgresql.conf" <<EOF
port = $NEW_PORT
wal_level = replica
EOF

#############################################
# START NEW CLUSTER
#############################################

echo "9. Starting upgraded cluster..."

start_pg "$NEW_PGDATA" "$NEW_PORT" "$NEW_INSTALL_DIR"

#############################################
# VERIFY DATA
#############################################

echo "10. Verifying upgraded tables..."

for t in "${!ROW_COUNTS_BEFORE[@]}"; do

    AFTER_COUNT=$(
      $NEW_INSTALL_DIR/bin/psql \
      -p "$NEW_PORT" \
      -d postgres \
      -h "$PGHOST" \
      -Atc "
      SELECT count(*) FROM $t;" \
      || echo "FAILED"
    )

    BEFORE_COUNT=${ROW_COUNTS_BEFORE[$t]}

    if [ "$AFTER_COUNT" = "$BEFORE_COUNT" ]; then

        echo "[PASS] $t row count verified: $AFTER_COUNT"

    else

        echo "[FAIL] $t mismatch before=$BEFORE_COUNT after=$AFTER_COUNT"
        exit 1

    fi

done

#############################################
# FINAL CLEANUP
#############################################

rm -f "$WRAPPER_DIR/update_extensions.sql" || true
rm -f "$WRAPPER_DIR/delete_old_cluster.sh" || true

echo "=========================================="
echo "✅ pg_tde_upgrade DDL/DML stress test PASSED"
echo "=========================================="
