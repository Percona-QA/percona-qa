#!/usr/bin/env bash

TEST_ID="PGSM-NORM-001"
TEST_NAME="Verify query normalization when enabled"
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

    if ! execute_sql_session >/dev/null <<'EOF'
SET pg_stat_monitor.pgsm_normalized_query = 'on';

SELECT 12345 AS pgsm_normalization_test;
EOF
    then
        log_error "Unable to execute normalization test workload"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE 'SELECT %pgsm_normalization_test%'
              LIMIT 1"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Normalized query is present" \
        "${result}" || return 1

    assert_not_contains \
        "Literal value is replaced in normalized query" \
        "${result}" \
        "12345" || return 1

    return 0
}
