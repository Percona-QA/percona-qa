#!/usr/bin/env bash

TEST_ID="PGSM-PERM-002"
TEST_NAME="Verify unprivileged user can see own query information"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_002"

test_setup()
{
    execute_sql "
        DROP ROLE IF EXISTS ${PERM_ROLE};
        CREATE ROLE ${PERM_ROLE};
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

    result="$(
        execute_sql_session <<EOF
SET ROLE ${PERM_ROLE};

SELECT 50002 AS pgsm_perm_002_test;

SELECT query
FROM pg_stat_monitor
WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = '${PERM_ROLE}')
  AND query LIKE '%pgsm_perm_002_test%'
LIMIT 1;
EOF
    )" || {
        log_error "Unable to execute query as unprivileged user"
        return 1
    }

    assert_contains \
        "Unprivileged user can see own query text" \
        "${result}" \
        "pgsm_perm_002_test" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}

