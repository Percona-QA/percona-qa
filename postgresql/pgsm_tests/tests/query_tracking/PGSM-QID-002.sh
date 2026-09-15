#!/usr/bin/env bash

TEST_ID="PGSM-QID-002"
TEST_NAME="Verify PGSM query ID can be disabled"
TEST_SUITE="query_id"

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

    execute_sql_session <<'EOF'
SET pg_stat_monitor.pgsm_enable_pgsm_query_id = 'off';
SHOW pg_stat_monitor.pgsm_enable_pgsm_query_id;
SELECT 44444 AS pgsm_query_id_disabled_test;
EOF

    query_id="$(
        pgsm_query \
            "SELECT pgsm_query_id
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_query_id_disabled_test%'
              LIMIT 1"
    )" || return 1

    assert_empty \
        "PGSM query ID is empty when disabled" \
        "${query_id}" || return 1

    return 0
}
