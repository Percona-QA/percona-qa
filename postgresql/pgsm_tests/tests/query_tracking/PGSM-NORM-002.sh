#!/usr/bin/env bash

TEST_ID="PGSM-NORM-002"
TEST_NAME="Verify query normalization when disabled"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "off" || true
}

test_body()
{
    local result

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "off" || return 1

    execute_sql \
        "SELECT 67890 AS pgsm_non_normalized_test" >/dev/null || return 1

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_non_normalized_test%'
              LIMIT 1"
    )" || return 1

    assert_not_empty \
        "Query is present" \
        "${result}" || return 1

    assert_contains \
        "Literal value is present when normalization is disabled" \
        "${result}" \
        "67890" || return 1

    return 0
}
