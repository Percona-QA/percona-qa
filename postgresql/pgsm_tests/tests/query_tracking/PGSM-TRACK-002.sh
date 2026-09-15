#!/usr/bin/env bash

TEST_ID="PGSM-TRACK-002"
TEST_NAME="Verify pgsm_track=none disables query tracking"
TEST_SUITE="query_tracking"

test_cleanup()
{
    pgsm_set_guc \
        "pg_stat_monitor.pgsm_track" \
        "top" || true
}

test_body()
{
    local query_text="SELECT 22222 AS pgsm_tracking_none_test"
    local count

    pgsm_reset || return 1

    execute_sql_session <<'EOF'
SET pg_stat_monitor.pgsm_track = 'none';
SHOW pg_stat_monitor.pgsm_track;
SELECT 55555 AS pgsm_track_none_test;
EOF

    count="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE query LIKE '%22222%'"
    )" || return 1

    assert_equal \
        "Query is not tracked when pgsm_track=none" \
        "0" \
        "${count}" || return 1

    return 0
}
