#!/usr/bin/env bash

TEST_ID="PGSM-PERM-006"
TEST_NAME="Verify granted user can reset pg_stat_monitor statistics"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_006"

test_setup()
{
    execute_sql "
        DROP ROLE IF EXISTS ${PERM_ROLE};
        CREATE ROLE ${PERM_ROLE};

        GRANT EXECUTE
        ON FUNCTION pg_stat_monitor_reset()
        TO ${PERM_ROLE};
    " || {
        log_error "Unable to create role or grant reset privilege"
        return 1
    }
}

test_body()
{
    local result

    execute_sql \
        "SELECT 50006 AS pgsm_perm_006_test;" >/dev/null || {
        log_error "Unable to create statistics before reset"
        return 1
    }

    result="$(
        execute_sql_session <<EOF
SET ROLE ${PERM_ROLE};

SELECT pg_stat_monitor_reset();
EOF
    )" || {
        log_error "Granted user could not reset pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Granted user can execute pg_stat_monitor_reset" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "REVOKE EXECUTE ON FUNCTION pg_stat_monitor_reset() FROM ${PERM_ROLE};" \
        || true

    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}
