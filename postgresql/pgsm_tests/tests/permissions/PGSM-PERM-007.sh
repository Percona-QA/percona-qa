#!/usr/bin/env bash

TEST_ID="PGSM-PERM-007"
TEST_NAME="Verify user without PGSM privileges can execute normal SQL"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_007"

test_setup()
{
    execute_sql "
        DROP ROLE IF EXISTS ${PERM_ROLE};
        CREATE ROLE ${PERM_ROLE};
    " || {
        log_error "Unable to create test role"
        return 1
    }
}

test_body()
{
    local result
    result="$(
        execute_sql_session <<EOF
\set QUIET on
SET ROLE ${PERM_ROLE};
SELECT 50007 AS pgsm_normal_sql_test;
EOF
    )" || {
        log_error "Normal SQL failed for user without PGSM privileges"
        return 1
    }

    assert_equal \
        "User can execute normal SQL without PGSM privileges" \
        "50007" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}
