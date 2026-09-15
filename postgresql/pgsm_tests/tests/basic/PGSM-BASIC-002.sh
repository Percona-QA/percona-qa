#!/bin/bash

TEST_ID="PGSM-BASIC-002"
TEST_NAME="Verify query call count"
TEST_SUITE="basic"

test_body()
{
    local query_text="SELECT 12345 AS pgsm_call_count_test"
    local calls

    pgsm_reset || return 1

    log_info "Executing test query three times"

    execute_sql "${query_text}" >/dev/null || return 1
    execute_sql "${query_text}" >/dev/null || return 1
    execute_sql "${query_text}" >/dev/null || return 1

    calls="$(
        pgsm_query \
            "SELECT SUM(calls)
               FROM pg_stat_monitor
              WHERE query LIKE '%12345%'"
    )" || {
        log_error "Unable to retrieve query call count"
        return 1
    }

    log_info "Observed call count: ${calls}"

    assert_equal \
        "Query call count is 3" \
        "3" \
        "${calls}" || return 1

    return 0
}
