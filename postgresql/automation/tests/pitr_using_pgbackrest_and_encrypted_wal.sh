#!/bin/bash

install_pgbackrest

PGBACKREST=$(command -v pgbackrest)
PSQL="$INSTALL_DIR/bin/psql"
KEYFILE="$RUN_DIR/keyring.per"
REPO="$RUN_DIR/pgbackrest_repo"
LOGS="$RUN_DIR/pgbackrest_logs"

old_server_cleanup "$PRIMARY_DATA"
rm -rf "$REPO" "$LOGS" "$KEYFILE"
mkdir -p "$REPO" "$LOGS"

initialize_server "$PRIMARY_DATA" "$PRIMARY_PORT"
enable_pg_tde "$PRIMARY_DATA"

cat > "$RUN_DIR/pgbackrest.conf" <<EOF
[global]
repo1-path=$REPO
repo1-retention-full=2
start-fast=y
log-path=$LOGS
archive-header-check=n

[demo]
pg1-path=$PRIMARY_DATA
pg1-port=$PRIMARY_PORT
pg1-socket-path=$RUN_DIR
EOF

cat >> "$PRIMARY_DATA/postgresql.conf" <<EOF
archive_mode=on
archive_command='$PGBACKREST --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-push %p'
wal_level=replica
archive_timeout=10s
EOF

start_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "CREATE EXTENSION pg_tde;"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_add_global_key_provider_file('provider','$KEYFILE');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('wal_key','provider');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('table_key','provider');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('wal_key','provider');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('table_key','provider');"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt='ON';"

restart_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

$PGBACKREST --config="$RUN_DIR/pgbackrest.conf" --stanza=demo stanza-create

$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "
CREATE TABLE t1(
    id serial PRIMARY KEY,
    name text
) USING tde_heap;"

$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "
INSERT INTO t1(name)
VALUES ('before backup 1'),
       ('before backup 2');"

$PGBACKREST --config="$RUN_DIR/pgbackrest.conf" --stanza=demo backup

declare -A TARGET_TIME
declare -A EXPECTED_ROWS

for i in {1..5}; do
    $PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres \
      -c "INSERT INTO t1(name) VALUES('after backup point $i');"

    sleep 2

    TARGET_TIME[$i]=$($PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -Atc "SELECT now();")
    EXPECTED_ROWS[$i]=$($PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -Atc "SELECT count(*) FROM t1;")

    echo "Target $i: ${TARGET_TIME[$i]} rows=${EXPECTED_ROWS[$i]}"
done

$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "CHECKPOINT;"
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres -c "SELECT pg_switch_wal();"

# Generate a little more WAL
$PSQL -h $RUN_DIR -p $PRIMARY_PORT -d postgres <<EOF
INSERT INTO t1(name)
SELECT 'extra wal ' || g
FROM generate_series(1,1000) g;
CHECKPOINT;
SELECT pg_switch_wal();
EOF

echo "Waiting for WAL archiving..."
sleep 15

crash_pg "$PRIMARY_DATA" "$PRIMARY_PORT"

for i in {1..5}; do

    RESTORE_DATA="$RUN_DIR/restore_$i"
    RESTORE_PORT=$((6500+i))

    rm -rf "$RESTORE_DATA"
    mkdir -p "$RESTORE_DATA"

    $PGBACKREST \
      --config="$RUN_DIR/pgbackrest.conf" \
      --stanza=demo \
      --pg1-path="$RESTORE_DATA" \
      --type=time \
      --target="${TARGET_TIME[$i]}" \
      restore

    cat > "$RESTORE_DATA/postgresql.conf" <<EOF
port = $RESTORE_PORT
unix_socket_directories='$RUN_DIR'
listen_addresses = '*'
logging_collector = on
log_directory = '$RESTORE_DATA'
log_filename = 'restore.log'
log_statement = 'ddl'
log_min_error_statement = 'error'
max_wal_senders = 5
wal_log_hints = on
io_method = '$IO_METHOD'
shared_preload_libraries = 'pg_tde'
archive_mode=on
archive_command='/usr/bin/pgbackrest --stanza=demo --config=$RUN_DIR/pgbackrest.conf archive-push %p'
wal_level=replica
archive_timeout=10s
EOF

    rm -f "$RESTORE_DATA/postmaster.pid"

    start_pg "$RESTORE_DATA" "$RESTORE_PORT"

    ROWS=$($PSQL -h $RUN_DIR -p $RESTORE_PORT -d postgres -Atc \
        "SELECT count(*) FROM t1;")

    if [ "$ROWS" != "${EXPECTED_ROWS[$i]}" ]; then
        echo "PITR failed for target $i"
        exit 1
    fi

    $PSQL -h $RUN_DIR -p $RESTORE_PORT -d postgres \
      -c "SELECT pg_tde_is_encrypted('t1');"

    $INSTALL_DIR/bin/pg_ctl -D "$RESTORE_DATA" promote
    sleep 5

    $PSQL -h $RUN_DIR -p $RESTORE_PORT -d postgres \
      -c "CREATE TABLE t_recovery_$i(id int) USING tde_heap;"

    stop_pg "$RESTORE_DATA" "$RESTORE_PORT"
done

echo "TEST PASSED"
