#!/usr/bin/env bash

TEST_ID="PGSM-PERM-003"
TEST_NAME="Verify unprivileged user cannot see identifying information for another user"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_003"

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

    execute_sql \
        "SELECT 50003 AS pgsm_perm_003_secret;" >/dev/null || {
        log_error "Unable to create statistics for test query"
        return 1
    }

    result="$(
        execute_sql_session <<EOF
SET ROLE ${PERM_ROLE};

SELECT
    query,
    queryid,
    pgsm_query_id,
    client_ip
FROM pg_stat_monitor
WHERE userid <> (SELECT oid FROM pg_roles WHERE rolname = '${PERM_ROLE}')
  AND query LIKE '%pgsm_perm_003_secret%'
LIMIT 1;
EOF
    )" || {
        log_error "Unable to query pg_stat_monitor as unprivileged user"
        return 1
    }

    assert_not_contains \
        "Other user's query text is hidden" \
        "${result}" \
        "pgsm_perm_003_secret" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}
