#!/usr/bin/env bash

TEST_ID="PGSM-INT-005"
TEST_NAME="Verify SQL executed inside PL/pgSQL function is tracked"
TEST_SUITE="integration"

FUNCTION_NAME="pgsm_int_005_function"

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql "
CREATE OR REPLACE FUNCTION ${FUNCTION_NAME}()
RETURNS integer
LANGUAGE plpgsql
AS \$\$
BEGIN
    PERFORM 15001 AS pgsm_int_005_function_test;
    RETURN 15001;
END;
\$\$;
" >/dev/null || {
        log_error "Unable to create PL/pgSQL function"
        return 1
    }

    execute_sql \
        "SELECT ${FUNCTION_NAME}();" >/dev/null || {
        log_error "Unable to execute PL/pgSQL function"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_005_function_test%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "SQL executed inside PL/pgSQL function is tracked" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    execute_sql \
        "DROP FUNCTION IF EXISTS ${FUNCTION_NAME}();" \
        >/dev/null 2>&1 || true
}
