#!/usr/bin/env bash

TEST_ID="PGSM-INT-010"
TEST_NAME="Verify application_name is recorded"
TEST_SUITE="integration"

APPLICATION_NAME="pgsm_int_010_application"

test_body()
{
    local result

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<EOF
SET application_name = '${APPLICATION_NAME}';

SELECT 20001 AS pgsm_int_010_application_test;
EOF
    then
        log_error "Unable to execute application_name workload"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT application_name
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_010_application_test%'
              LIMIT 1"
    )" || {
        log_error "Unable to query application_name metadata"
        return 1
    }

    assert_equal \
        "PGSM records application_name" \
        "${APPLICATION_NAME}" \
        "${result}" || return 1

    return 0
}
