#!/bin/bash

TEST_ID="PGSM-BASIC-001"
TEST_NAME="Verify executed query is tracked by pgsm"
TEST_SUITE="basic"

test_body()
{
    local query_text="SELECT 100 + 200 AS pgsm_basic_test"

    log_info "Resetting pg_stat_monitor statistics"

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor statistics"
        return 1
    }

    log_info "Executing test query"

    execute_sql "${query_text}" >/dev/null || {
        log_error "Test query execution failed"
        return 1
    }

    log_info "Verifying query is present in pg_stat_monitor"

    local result

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%100 + 200%'
              LIMIT 1"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Executed query is present in pg_stat_monitor" \
        "${result}" || return 1

    return 0
}
