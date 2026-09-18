#!/usr/bin/env bash

TEST_ID="PGSM-INT-011"
TEST_NAME="Verify prepared statement execution is tracked"
TEST_SUITE="integration"

STATEMENT_NAME="pgsm_int_011_stmt"

test_body()
{
    local result

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<'EOF'
PREPARE pgsm_int_011_stmt AS
SELECT 21001 AS pgsm_int_011_extended_test;

EXECUTE pgsm_int_011_stmt;
EOF
    then
        log_error "Unable to execute prepared statement workload"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_011_extended_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to query prepared statement workload"
        return 1
    }

    assert_not_empty \
        "Prepared statement query is tracked" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DEALLOCATE ${STATEMENT_NAME};" \
        >/dev/null 2>&1 || true
}
