#!/usr/bin/env bash

TEST_ID="PGSM-QID-001"
TEST_NAME="Verify PGSM query ID is generated"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_enable_pgsm_query_id" \
        "on" || true
}

test_body()
{
    local query_id

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_enable_pgsm_query_id" \
        "on" || return 1

    execute_sql \
        "SELECT 33333 AS pgsm_query_id_test" >/dev/null || return 1

    query_id="$(
        pgsm_query \
            "SELECT pgsm_query_id
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_query_id_test%'
              LIMIT 1"
    )" || return 1

    assert_not_empty \
        "PGSM query ID is generated" \
        "${query_id}" || return 1

    return 0
}
