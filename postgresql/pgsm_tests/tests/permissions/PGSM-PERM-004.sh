#!/usr/bin/env bash

TEST_ID="PGSM-PERM-004"
TEST_NAME="Verify pg_read_all_stats user can see other users query information"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_004"

test_setup()
{
    execute_sql "
        DROP ROLE IF EXISTS ${PERM_ROLE};
        CREATE ROLE ${PERM_ROLE};
        GRANT pg_read_all_stats TO ${PERM_ROLE};
    " || {
        log_error "Unable to create test role"
        return 1
    }

    execute_sql \
        "GRANT CONNECT ON DATABASE ${PGSM_TEST_DB} TO ${PERM_ROLE};" || {
        log_error "Unable to grant CONNECT"
        return 1
    }
}

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql \
        "SELECT 50004 AS pgsm_perm_004_test;" >/dev/null || {
        log_error "Unable to create statistics for test query"
        return 1
    }

    result="$(
        execute_sql_session <<EOF
SET ROLE ${PERM_ROLE};

SELECT query
FROM pg_stat_monitor
WHERE query LIKE '%pgsm_perm_004_test%'
LIMIT 1;
EOF
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_contains \
        "pg_read_all_stats user can see other user's query text" \
        "${result}" \
        "pgsm_perm_004_test" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}
