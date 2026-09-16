#!/usr/bin/env bash

TEST_ID="PGSM-PERM-001"
TEST_NAME="Verify unprivileged user can query pg_stat_monitor"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_001"

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

    result="$(
        execute_sql_session <<EOF
SET ROLE ${PERM_ROLE};

SELECT count(*)
FROM pg_stat_monitor;
EOF
    )" || {
        log_error "Unprivileged user could not query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Unprivileged user can query pg_stat_monitor" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}

