#!/usr/bin/env bash

TEST_ID="PGSM-INT-001"
TEST_NAME="Verify prepared statements are tracked"
TEST_SUITE="integration"

test_body()
{
    local calls

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<'EOF'
PREPARE pgsm_int_001_stmt AS
    SELECT 11001 AS pgsm_int_001_test;

EXECUTE pgsm_int_001_stmt;
EXECUTE pgsm_int_001_stmt;
EOF
    then
        log_error "Unable to execute prepared statement workload"
        return 1
    fi

    log_info "Querying pg_stat_monitor for prepared statement"

    calls="$(
        pgsm_query \
            "SELECT calls
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_001_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve prepared statement call count"
        return 1
    }

    assert_not_empty \
        "Prepared statement call count is available" \
        "${calls}" || return 1

    assert_equal \
        "Prepared statement executed twice" \
        "2" \
        "${calls}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DEALLOCATE pgsm_int_001_stmt;" >/dev/null 2>&1 || true
}

