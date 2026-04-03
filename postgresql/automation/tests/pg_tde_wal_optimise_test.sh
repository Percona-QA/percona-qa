#!/bin/bash

# WAL optimize test (bash port of recovery/018_wal_optimize.pl).
# Tests WAL replay when some operations have skipped WAL: commit transactions,
# immediate shutdown, then confirm data survives recovery. Run with pg_tde for PG-1806.

PSQL="$INSTALL_DIR/bin/psql"
WAL_OPT_DATA="${WAL_OPT_DATA:-$RUN_DIR/wal_opt_data}"
WAL_OPT_PORT="${WAL_OPT_PORT:-5437}"
KEYFILE="$RUN_DIR/wal_opt_keyfile"
TABLESPACE_DIR="$RUN_DIR/tablespace_other"
COPY_FILE="$RUN_DIR/copy_data.txt"

# Create COPY input file used by several tests
cat > "$COPY_FILE" <<'COPYEOF'
20000,30000
20001,30001
20002,30002
COPYEOF

check_orphan_relfilenodes() {
    local db_oid
    db_oid=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT oid FROM pg_database WHERE datname = 'postgres';" | tr -d '\r\n')
    local prefix="base/$db_oid/"
    local dir="$WAL_OPT_DATA/$prefix"
    local files_on_disk
    local files_referenced
    files_on_disk=$(ls -1 "$dir" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | awk -v p="$prefix" '{print p $0}' | sort | tr '\n' ' ')
    files_referenced=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "
        SELECT pg_relation_filepath(oid) FROM pg_class
        WHERE reltablespace = 0 AND relpersistence <> 't' AND pg_relation_filepath(oid) IS NOT NULL;
    " | tr -d '\r' | sort | tr '\n' ' ')
    if [ "$files_on_disk" != "$files_referenced" ]; then
        echo "[FAIL] Orphan relfilenodes: on_disk and referenced differ"
        echo "On disk: $files_on_disk"
        echo "Referenced: $files_referenced"
        exit 1
    fi
    echo "   [PASS] No orphan relfilenodes."
}

run_wal_optimize() {
    local wal_level="$1"
    echo "========== Running WAL optimize tests with wal_level=$wal_level =========="

    # Set PGDATA so test_runner.sh can save artifacts on failure
    PGDATA="$WAL_OPT_DATA"

    old_server_cleanup "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    rm -rf "$WAL_OPT_DATA" "$TABLESPACE_DIR" || true
    rm -f "$KEYFILE" || true
    mkdir -p "$TABLESPACE_DIR"
    chmod 700 "$TABLESPACE_DIR" || true

    echo "1. Init cluster with wal_level=$wal_level and pg_tde..."
    $INSTALL_DIR/bin/initdb -D "$WAL_OPT_DATA" \
        --set shared_preload_libraries=pg_tde \
        --set io_method=$IO_METHOD \
        --set unix_socket_directories="$RUN_DIR" \
        > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: initdb failed."
        exit 1
    fi
    cat >> "$WAL_OPT_DATA/postgresql.conf" <<EOF
wal_level = $wal_level
max_prepared_transactions = 1
wal_log_hints = on
wal_skip_threshold = 0
default_table_access_method = tde_heap
logging_collector = on
log_directory = '$WAL_OPT_DATA'
log_filename = 'server.log'
log_statement = 'all'
EOF
    # wal_level=minimal requires max_wal_senders=0 (no WAL streaming)
    if [ "$wal_level" = "minimal" ]; then
        echo "max_wal_senders = 0" >> "$WAL_OPT_DATA/postgresql.conf"
    fi
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "CREATE EXTENSION pg_tde;"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_add_global_key_provider_file('file_provider','$KEYFILE');"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_create_key_using_global_key_provider('key1','file_provider');"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "SELECT pg_tde_set_default_key_using_global_key_provider('key1','file_provider');"
    restart_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"

    echo "2. Test redo of CREATE TABLESPACE (moved table)..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLE moved (id int);"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO moved VALUES (1);"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "CREATE TABLESPACE other LOCATION '$TABLESPACE_DIR';"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        ALTER TABLE moved SET TABLESPACE other;
        CREATE TABLE originated (id int);
        INSERT INTO originated VALUES (1);
        CREATE UNIQUE INDEX ON originated(id) TABLESPACE other;
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM moved;")
    [ "$result" = "1" ] || { echo "   [FAIL] Expected count 1 from moved, got $result"; exit 1; }
    echo "   [PASS] moved count = 1 (wal_level=$wal_level, CREATE+SET TABLESPACE)."
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "
        INSERT INTO originated VALUES (1) ON CONFLICT (id) DO UPDATE set id = originated.id + 1 RETURNING id;" | head -1)
    [ "$result" = "2" ] || { echo "   [FAIL] Expected 2 from originated conflict, got $result"; exit 1; }
    echo "   [PASS] originated ON CONFLICT (wal_level=$wal_level)."

    echo "3. Test direct truncation optimization (empty table)..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE trunc (id serial PRIMARY KEY);
        TRUNCATE trunc;
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM trunc;")
    [ "$result" = "0" ] || { echo "   [FAIL] Expected 0 from trunc, got $result"; exit 1; }
    echo "   [PASS] trunc count = 0."

    echo "4. Test TRUNCATE with INSERT in same transaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE trunc_ins (id serial PRIMARY KEY);
        INSERT INTO trunc_ins VALUES (DEFAULT);
        TRUNCATE trunc_ins;
        INSERT INTO trunc_ins VALUES (DEFAULT);
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*), min(id) FROM trunc_ins;")
    [ "$result" = "1|2" ] || { echo "   [FAIL] Expected 1|2 from trunc_ins, got $result"; exit 1; }
    echo "   [PASS] trunc_ins count=1 min(id)=2."

    echo "5. Test TRUNCATE with INSERT and prepared transaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE twophase (id serial PRIMARY KEY);
        INSERT INTO twophase VALUES (DEFAULT);
        TRUNCATE twophase;
        INSERT INTO twophase VALUES (DEFAULT);
        PREPARE TRANSACTION 't';"
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "COMMIT PREPARED 't';"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*), min(id) FROM twophase;")
    [ "$result" = "1|2" ] || { echo "   [FAIL] Expected 1|2 from twophase, got $result"; exit 1; }
    echo "   [PASS] twophase TRUNCATE INSERT PREPARE."

    echo "6. Test end-of-xact WAL (noskip)..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        SET wal_skip_threshold = '1GB';
        BEGIN;
        CREATE TABLE noskip (id serial PRIMARY KEY);
        INSERT INTO noskip SELECT generate_series(1, 20000);
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM noskip;")
    [ "$result" = "20000" ] || { echo "   [FAIL] Expected 20000 from noskip, got $result"; exit 1; }
    echo "   [PASS] noskip count = 20000."

    echo "7. Test TRUNCATE with INSERT and COPY..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE ins_trunc (id serial PRIMARY KEY, id2 int);
        INSERT INTO ins_trunc VALUES (DEFAULT, generate_series(1,10000));
        TRUNCATE ins_trunc;
        INSERT INTO ins_trunc (id, id2) VALUES (DEFAULT, 10000);
        COPY ins_trunc FROM '$COPY_FILE' DELIMITER ',';
        INSERT INTO ins_trunc (id, id2) VALUES (DEFAULT, 10000);
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM ins_trunc;")
    [ "$result" = "5" ] || { echo "   [FAIL] Expected 5 from ins_trunc, got $result"; exit 1; }
    echo "   [PASS] ins_trunc count = 5."

    echo "8. Test TRUNCATE then COPY..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE trunc_copy (id serial PRIMARY KEY, id2 int);
        INSERT INTO trunc_copy VALUES (DEFAULT, generate_series(1,3000));
        TRUNCATE trunc_copy;
        COPY trunc_copy FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM trunc_copy;")
    [ "$result" = "3" ] || { echo "   [FAIL] Expected 3 from trunc_copy, got $result"; exit 1; }
    echo "   [PASS] trunc_copy count = 3."

    echo "9. Test SET TABLESPACE abort in subtransaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE spc_abort (id serial PRIMARY KEY, id2 int);
        INSERT INTO spc_abort VALUES (DEFAULT, generate_series(1,3000));
        TRUNCATE spc_abort;
        SAVEPOINT s;
        ALTER TABLE spc_abort SET TABLESPACE other; ROLLBACK TO s;
        COPY spc_abort FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM spc_abort;")
    [ "$result" = "3" ] || { echo "   [FAIL] Expected 3 from spc_abort, got $result"; exit 1; }
    echo "   [PASS] spc_abort SET TABLESPACE rollback."

    echo "10. Test SET TABLESPACE commit in subtransaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE spc_commit (id serial PRIMARY KEY, id2 int);
        INSERT INTO spc_commit VALUES (DEFAULT, generate_series(1,3000));
        TRUNCATE spc_commit;
        SAVEPOINT s; ALTER TABLE spc_commit SET TABLESPACE other; RELEASE s;
        COPY spc_commit FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM spc_commit;")
    [ "$result" = "3" ] || { echo "   [FAIL] Expected 3 from spc_commit, got $result"; exit 1; }
    echo "   [PASS] spc_commit SET TABLESPACE commit."

    echo "11. Test SET TABLESPACE nested subtransaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE spc_nest (id serial PRIMARY KEY, id2 int);
        INSERT INTO spc_nest VALUES (DEFAULT, generate_series(1,3000));
        TRUNCATE spc_nest;
        SAVEPOINT s;
            ALTER TABLE spc_nest SET TABLESPACE other;
            SAVEPOINT s2;
                ALTER TABLE spc_nest SET TABLESPACE pg_default;
            ROLLBACK TO s2;
            SAVEPOINT s2;
                ALTER TABLE spc_nest SET TABLESPACE pg_default;
            RELEASE s2;
        ROLLBACK TO s;
        COPY spc_nest FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM spc_nest;")
    [ "$result" = "3" ] || { echo "   [FAIL] Expected 3 from spc_nest, got $result"; exit 1; }
    echo "   [PASS] spc_nest nested SET TABLESPACE."

    echo "12. Test SET TABLESPACE with hint bit..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        CREATE TABLE spc_hint (id int);
        INSERT INTO spc_hint VALUES (1);
        BEGIN;
        ALTER TABLE spc_hint SET TABLESPACE other;
        CHECKPOINT;
        SELECT * FROM spc_hint;
        INSERT INTO spc_hint VALUES (2);
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM spc_hint;")
    [ "$result" = "2" ] || { echo "   [FAIL] Expected 2 from spc_hint, got $result"; exit 1; }
    echo "   [PASS] spc_hint SET TABLESPACE hint bit."

    echo "13. Test unique index LP_DEAD..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE idx_hint (c int PRIMARY KEY);
        SAVEPOINT q; INSERT INTO idx_hint VALUES (1); ROLLBACK TO q;
        CHECKPOINT;
        INSERT INTO idx_hint VALUES (1);
        INSERT INTO idx_hint VALUES (2);
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    ret=0
    stderr=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "INSERT INTO idx_hint VALUES (2);" 2>&1) || ret=$?
    echo "$stderr" | grep -q "violates unique" || { echo "   [FAIL] Expected 'violates unique' in stderr"; exit 1; }
    echo "   [PASS] idx_hint unique violation after recovery."

    echo "14. Test UPDATE touches two buffers..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE upd (id serial PRIMARY KEY, id2 int);
        INSERT INTO upd (id, id2) VALUES (DEFAULT, generate_series(1,10000));
        COPY upd FROM '$COPY_FILE' DELIMITER ',';
        UPDATE upd SET id2 = id2 + 1;
        DELETE FROM upd;
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM upd;")
    [ "$result" = "0" ] || { echo "   [FAIL] Expected 0 from upd, got $result"; exit 1; }
    echo "   [PASS] upd count = 0."

    echo "15. Test INSERT and COPY in same transaction..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE ins_copy (id serial PRIMARY KEY, id2 int);
        INSERT INTO ins_copy VALUES (DEFAULT, 1);
        COPY ins_copy FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM ins_copy;")
    [ "$result" = "4" ] || { echo "   [FAIL] Expected 4 from ins_copy, got $result"; exit 1; }
    echo "   [PASS] ins_copy count = 4."

    echo "16. Test COPY with INSERT triggers..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE ins_trig (id serial PRIMARY KEY, id2 text);
        CREATE FUNCTION ins_trig_before_row_trig() RETURNS trigger LANGUAGE plpgsql as \$\$
          BEGIN
            IF new.id2 NOT LIKE 'triggered%' THEN
              INSERT INTO ins_trig VALUES (DEFAULT, 'triggered row before' || NEW.id2);
            END IF;
            RETURN NEW;
          END; \$\$;
        CREATE FUNCTION ins_trig_after_row_trig() RETURNS trigger LANGUAGE plpgsql as \$\$
          BEGIN
            IF new.id2 NOT LIKE 'triggered%' THEN
              INSERT INTO ins_trig VALUES (DEFAULT, 'triggered row after' || NEW.id2);
            END IF;
            RETURN NEW;
          END; \$\$;
        CREATE TRIGGER ins_trig_before_row_insert BEFORE INSERT ON ins_trig FOR EACH ROW EXECUTE PROCEDURE ins_trig_before_row_trig();
        CREATE TRIGGER ins_trig_after_row_insert AFTER INSERT ON ins_trig FOR EACH ROW EXECUTE PROCEDURE ins_trig_after_row_trig();
        COPY ins_trig FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM ins_trig;")
    [ "$result" = "9" ] || { echo "   [FAIL] Expected 9 from ins_trig, got $result"; exit 1; }
    echo "   [PASS] ins_trig count = 9."

    echo "17. Test TRUNCATE with TRUNCATE triggers..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "
        BEGIN;
        CREATE TABLE trunc_trig (id serial PRIMARY KEY, id2 text);
        CREATE FUNCTION trunc_trig_before_stat_trig() RETURNS trigger LANGUAGE plpgsql as \$\$
          BEGIN INSERT INTO trunc_trig VALUES (DEFAULT, 'triggered stat before'); RETURN NULL; END; \$\$;
        CREATE FUNCTION trunc_trig_after_stat_trig() RETURNS trigger LANGUAGE plpgsql as \$\$
          BEGIN INSERT INTO trunc_trig VALUES (DEFAULT, 'triggered stat before'); RETURN NULL; END; \$\$;
        CREATE TRIGGER trunc_trig_before_stat_truncate BEFORE TRUNCATE ON trunc_trig FOR EACH STATEMENT EXECUTE PROCEDURE trunc_trig_before_stat_trig();
        CREATE TRIGGER trunc_trig_after_stat_truncate AFTER TRUNCATE ON trunc_trig FOR EACH STATEMENT EXECUTE PROCEDURE trunc_trig_after_stat_trig();
        INSERT INTO trunc_trig VALUES (DEFAULT, 1);
        TRUNCATE trunc_trig;
        COPY trunc_trig FROM '$COPY_FILE' DELIMITER ',';
        COMMIT;"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    result=$($PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -t -A -c "SELECT count(*) FROM trunc_trig;")
    [ "$result" = "4" ] || { echo "   [FAIL] Expected 4 from trunc_trig, got $result"; exit 1; }
    echo "   [PASS] trunc_trig count = 4."

    echo "18. Test temp table (no orphan relfilenodes after restart)..."
    $PSQL -p "$WAL_OPT_PORT" -d postgres -h "$PGHOST" -c "CREATE TEMP TABLE temp (id serial PRIMARY KEY, id2 text);"
    $INSTALL_DIR/bin/pg_ctl -D "$WAL_OPT_DATA" -m immediate stop
    sleep 2
    start_pg "$WAL_OPT_DATA" "$WAL_OPT_PORT"
    check_orphan_relfilenodes

    stop_pg "$WAL_OPT_DATA"
    echo "========== WAL optimize tests passed for wal_level=$wal_level =========="
}

# Run for both wal_level values (same as Perl)
run_wal_optimize "minimal"
run_wal_optimize "replica"

echo "=== DONE: pg_tde WAL optimize test completed ==="
