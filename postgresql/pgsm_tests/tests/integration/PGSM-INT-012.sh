#!/usr/bin/env bash

TEST_ID="PGSM-INT-012"
TEST_NAME="Verify pg_stat_monitor continues tracking after PostgreSQL restart"
TEST_SUITE="integration"

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql \
        "SELECT 22001 AS pgsm_int_012_before_restart;" >/dev/null || {
        log_error "Unable to execute pre-restart workload"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_012_before_restart%'
              LIMIT 1"
    )" || {
        log_error "Unable to query pre-restart statistics"
        return 1
    }

    assert_not_empty \
        "Query is tracked before PostgreSQL restart" \
        "${result}" || return 1

    postgres_restart || {
        log_error "PostgreSQL restart failed"
        return 1
    }

    if ! pgsm_is_loaded; then
        log_error "pg_stat_monitor is not loaded after restart"
        return 1
    fi

    execute_sql \
        "SELECT 22002 AS pgsm_int_012_after_restart;" >/dev/null || {
        log_error "Unable to execute post-restart workload"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_012_after_restart%'
              LIMIT 1"
    )" || {
        log_error "Unable to query post-restart statistics"
        return 1
    }

    assert_not_empty \
        "Query is tracked after PostgreSQL restart" \
        "${result}" || return 1

    return 0
}
