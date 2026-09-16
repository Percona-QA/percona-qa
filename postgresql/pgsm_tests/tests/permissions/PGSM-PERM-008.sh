#!/usr/bin/env bash

TEST_ID="PGSM-PERM-008"
TEST_NAME="Verify privileged user can access unrestricted pg_stat_monitor information"
TEST_SUITE="permissions"

test_body()
{
    local result

    pgsm_reset || return 1

    execute_sql \
        "SELECT 50008 AS pgsm_perm_008_test;" >/dev/null || {
        log_error "Unable to execute privileged test query"
        return 1
    }

    result="$(
        pgsm_query \
            "SELECT query, queryid, pgsm_query_id, client_ip
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_perm_008_test%'
              LIMIT 1"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_contains \
        "Privileged user can see query text" \
        "${result}" \
        "pgsm_perm_008_test" || return 1

    assert_not_empty \
        "Privileged user can see queryid" \
        "${result}" || return 1

    return 0
}

test_cleanup()
{
    pgsm_reset || true
}
