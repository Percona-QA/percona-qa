#!/usr/bin/env bash

TEST_ID="PGSM-INT-002"
TEST_NAME="Verify queries executed inside committed transactions are tracked"
TEST_SUITE="integration"

test_body()
{
    local result
    local calls

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<'EOF'
BEGIN;

SELECT 12001 AS pgsm_int_002_commit_test;

COMMIT;
EOF
    then
        log_error "Unable to execute committed transaction workload"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_002_commit_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to query committed transaction workload"
        return 1
    }

    assert_not_empty \
        "Query inside committed transaction is tracked" \
        "${result}" || return 1

    calls="$(
        pgsm_query \
            "SELECT calls
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_002_commit_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve committed transaction query calls"
        return 1
    }

    assert_equal \
        "Committed transaction query is tracked once" \
        "1" \
        "${calls}" || return 1

    return 0
}
