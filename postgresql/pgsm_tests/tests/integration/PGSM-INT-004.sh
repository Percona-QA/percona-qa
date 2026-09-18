#!/usr/bin/env bash

TEST_ID="PGSM-INT-004"
TEST_NAME="Verify utility commands are tracked"
TEST_SUITE="integration"

TABLE_NAME="pgsm_int_004_table"

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql \
        "CREATE TABLE ${TABLE_NAME} (
            id integer,
            value text
        );" >/dev/null || {
        log_error "Unable to create utility test table"
        return 1
    }

    execute_sql \
        "INSERT INTO ${TABLE_NAME}
         VALUES (1, 'pgsm_int_004');" >/dev/null || {
        log_error "Unable to insert utility test data"
        return 1
    }

    execute_sql \
        "ANALYZE ${TABLE_NAME};" >/dev/null || {
        log_error "ANALYZE failed"
        return 1
    }

    execute_sql \
        "VACUUM ${TABLE_NAME};" >/dev/null || {
        log_error "VACUUM failed"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_004%'
                 OR query LIKE 'ANALYZE%'
                 OR query LIKE 'VACUUM%'
              LIMIT 20"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Utility workload is represented in pg_stat_monitor" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP TABLE IF EXISTS ${TABLE_NAME};" >/dev/null 2>&1 || true
}
