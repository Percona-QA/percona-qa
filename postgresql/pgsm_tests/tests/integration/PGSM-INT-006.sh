#!/usr/bin/env bash

TEST_ID="PGSM-INT-006"
TEST_NAME="Verify nested function queries are tracked"
TEST_SUITE="integration"

INNER_FUNCTION="pgsm_int_006_inner"
OUTER_FUNCTION="pgsm_int_006_outer"

test_body()
{
    local result
    local count

    pgsm_reset || return 1

    execute_sql "
CREATE OR REPLACE FUNCTION ${INNER_FUNCTION}()
RETURNS integer
LANGUAGE plpgsql
AS \$\$
BEGIN
    PERFORM 16001 AS pgsm_int_006_inner_test;
    RETURN 16001;
END;
\$\$;

CREATE OR REPLACE FUNCTION ${OUTER_FUNCTION}()
RETURNS integer
LANGUAGE plpgsql
AS \$\$
BEGIN
    PERFORM ${INNER_FUNCTION}();
    RETURN 16002;
END;
\$\$;
" >/dev/null || {
        log_error "Unable to create nested functions"
        return 1
    }

    execute_sql \
        "SELECT ${OUTER_FUNCTION}();" >/dev/null || {
        log_error "Unable to execute nested function workload"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_006_inner_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to query nested function information"
        return 1
    }

    assert_not_empty \
        "Nested function query is tracked" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP FUNCTION IF EXISTS ${OUTER_FUNCTION}();" \
        >/dev/null 2>&1 || true

    execute_sql \
        "DROP FUNCTION IF EXISTS ${INNER_FUNCTION}();" \
        >/dev/null 2>&1 || true
}
