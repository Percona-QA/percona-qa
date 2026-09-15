#!/usr/bin/env bash

TEST_ID="PGSM-TRACK-001"
TEST_NAME="Verify top-level query tracking"
TEST_SUITE="query_tracking"

test_body()
{
    local query_text="SELECT 11111 AS pgsm_tracking_test"
    local count

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_track" \
        "top" || return 1

    execute_sql "${query_text}" >/dev/null || return 1

    count="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%11111%'"
    )" || return 1

    assert_equal \
        "Top-level query is tracked" \
        "1" \
        "${count}" || return 1

    return 0
}
