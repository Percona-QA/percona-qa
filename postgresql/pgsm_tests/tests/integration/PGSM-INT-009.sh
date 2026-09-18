#!/usr/bin/env bash

TEST_ID="PGSM-INT-009"
TEST_NAME="Verify queries are attributed to the executing user"
TEST_SUITE="integration"

INT_ROLE="pgsm_int_009"

test_setup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${INT_ROLE};
         CREATE ROLE ${INT_ROLE};
         GRANT CONNECT ON DATABASE ${PGSM_TEST_DB} TO ${INT_ROLE};" \
        >/dev/null || {
        log_error "Unable to create integration test role"
        return 1
    }

    return 0
}

test_body()
{
    local result

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<EOF
SET ROLE ${INT_ROLE};

SELECT 19001 AS pgsm_int_009_user_test;
EOF
    then
        log_error "Unable to execute workload as ${INT_ROLE}"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT username
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_009_user_test%'
              LIMIT 1"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_equal \
        "Query is attributed to integration test role" \
        "${INT_ROLE}" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${INT_ROLE};" \
        >/dev/null 2>&1 || true
}
