#!/usr/bin/env bash

TEST_ID="PGSM-QID-003"
TEST_NAME="Verify normalized queries have the same PGSM query ID"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "off" || true

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_enable_pgsm_query_id" \
        "on" || true
}

test_body()
{
    local query_id_count

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_normalized_query" \
        "on" || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_enable_pgsm_query_id" \
        "on" || return 1

    execute_sql \
        "SELECT 555 AS pgsm_query_id_stable_test" >/dev/null || return 1

    execute_sql \
        "SELECT 666 AS pgsm_query_id_stable_test" >/dev/null || return 1

    query_id_count="$(
        pgsm_query \
            "SELECT COUNT(DISTINCT pgsm_query_id)
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_query_id_stable_test%'"
    )" || return 1

    assert_equal \
        "Normalized queries have one PGSM query ID" \
        "1" \
        "${query_id_count}" || return 1

    return 0
}
