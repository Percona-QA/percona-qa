#!/bin/bash

TEST_ID="PGSM-BASIC-003"
TEST_NAME="Verify pg_stat_monitor reset"
TEST_SUITE="basic"

test_body()
{
    local query_text="SELECT 54321 AS pgsm_reset_test"
    local before_reset
    local after_reset

    pgsm_reset || return 1

    execute_sql "${query_text}" >/dev/null || return 1

    before_reset="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%54321%'"
    )" || return 1

    assert_equal \
        "Query exists before reset" \
        "1" \
        "${before_reset}" || return 1

    log_info "Resetting pg_stat_monitor"

    pgsm_reset || return 1

    after_reset="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%54321%'"
    )" || return 1

    assert_equal \
        "Query is removed after reset" \
        "0" \
        "${after_reset}" || return 1

    return 0
}
