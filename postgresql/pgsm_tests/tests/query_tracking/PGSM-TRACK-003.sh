#!/usr/bin/env bash

TEST_ID="PGSM-TRACK-003"
TEST_NAME="Verify pgsm_track=all tracks nested statements"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_track" \
        "top" || true
}

test_body()
{
    local count

    pgsm_reset || return 1

    pgsm_set_guc \
        "pg_stat_monitor.pgsm_track" \
        "all" || return 1

    execute_sql \
        "SELECT COUNT(*) FROM generate_series(1, 3)" >/dev/null || return 1

    count="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%generate_series%'"
    )" || return 1

    assert_not_empty \
        "Nested/query activity is recorded with pgsm_track=all" \
        "${count}" || return 1

    return 0
}
