#!/usr/bin/env bash

TEST_ID="PGSM-NORM-003"
TEST_NAME="Verify different literals produced"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "off" || true
}

test_body()
{
    local query_count

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "on" || return 1

    execute_sql \
        "SELECT 111 AS pgsm_same_query_test" >/dev/null || return 1

    execute_sql \
        "SELECT 222 AS pgsm_same_query_test" >/dev/null || return 1

    query_count="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_same_query_test%'"
    )" || return 1

    assert_equal \
        "Different literals are aggregated into one normalized query" \
        "1" \
        "${query_count}" || return 1

    return 0
}
