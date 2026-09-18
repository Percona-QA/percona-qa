#!/usr/bin/env bash

TEST_ID="PGSM-INT-003"
TEST_NAME="Verify DDL statements are tracked"
TEST_SUITE="integration"

TABLE_NAME="pgsm_int_003_table"

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql \
        "CREATE TABLE ${TABLE_NAME} (
            id integer,
            value text
        );" >/dev/null || {
        log_error "CREATE TABLE failed"
        return 1
    }

    execute_sql \
        "ALTER TABLE ${TABLE_NAME}
         ADD COLUMN extra integer;" >/dev/null || {
        log_error "ALTER TABLE failed"
        return 1
    }

    execute_sql \
        "DROP TABLE ${TABLE_NAME};" >/dev/null || {
        log_error "DROP TABLE failed"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_003_table%'
              LIMIT 10"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "DDL statements are tracked by PGSM" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP TABLE IF EXISTS ${TABLE_NAME};" >/dev/null 2>&1 || true
}
