#!/usr/bin/env bash

TEST_ID="PGSM-PERM-005"
TEST_NAME="Verify unprivileged user cannot reset pg_stat_monitor statistics"
TEST_SUITE="permissions"

PERM_ROLE="pgsm_perm_005"

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
SET ROLE ${PERM_ROLE};

SELECT pg_stat_monitor_reset();
EOF
    )" && {
        log_error "Unprivileged user was able to reset pg_stat_monitor"
        return 1
    }

    log_info "Unprivileged reset correctly failed"

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP ROLE IF EXISTS ${PERM_ROLE};" || true
}
