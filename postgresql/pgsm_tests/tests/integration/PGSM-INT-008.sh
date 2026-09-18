#!/usr/bin/env bash

TEST_ID="PGSM-INT-008"
TEST_NAME="Verify query information is attributed to the correct database"
TEST_SUITE="integration"

DB_NAME="pgsm_int_008_db"

test_setup()
{
    postgres_create_database "${DB_NAME}" || {
        log_error "Unable to create database ${DB_NAME}"
        return 1
    }

    return 0
}

test_body()
{
    local result
    local db_name

    pgsm_reset || return 1

    execute_sql \
        "SELECT 18001 AS pgsm_int_008_default_db;" \
        "${PGSM_TEST_DB}" >/dev/null || {
        log_error "Unable to execute workload in default database"
        return 1
    }

    execute_sql \
        "SELECT 18002 AS pgsm_int_008_second_db;" \
        "${DB_NAME}" >/dev/null || {
        log_error "Unable to execute workload in second database"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT datname
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_008_second_db%'
              LIMIT 1"
    )" || {
        log_error "Unable to query second database statistics"
        return 1
    }

    assert_equal \
        "Query is attributed to second database" \
        "${DB_NAME}" \
        "${result}" || return 1

    db_name="$(
        pgsm_query \
            "SELECT datname
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_008_default_db%'
              LIMIT 1"
    )" || {
        log_error "Unable to query default database statistics"
        return 1
    }

    assert_equal \
        "Query is attributed to default database" \
        "${PGSM_TEST_DB}" \
        "${db_name}" || return 1

    return 0
}

test_cleanup()
{
    postgres_drop_database "${DB_NAME}" || true
}
