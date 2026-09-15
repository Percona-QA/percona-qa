#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-006"
TEST_NAME="Verify pg_stat_monitor handles queries ending with comments"
TEST_SUITE="stress"

test_body()
{
    local result

    log_info "Executing query ending with a closed comment"

    execute_sql \
        "SELECT 60001 AS pgsm_stress_006_closed; /* closed comment */" \
        >/dev/null || {
        log_error "Query with closed comment failed"
        return 1
    }

    log_info "Executing query ending with an unclosed comment"

    execute_sql \
        "SELECT 60002 AS pgsm_stress_006_unclosed; /* unclosed comment" \
        >/dev/null 2>&1 || {
        log_warn "Unclosed comment query was rejected by PostgreSQL"
    }

    assert_command_success \
        "PostgreSQL remains running after commeP0+r4B33\P0+r4B34\P0+r4B35\P0+r6B42\P0+r5053\P0+r5045\nt workload" \
        postgres_is_running || return 1

    result="$(
        pgsm_query \
            "SELECT count(*) FROM pg_stat_monitor;"
    )" || {
        log_error "Unable to query pg_stat_monitor after comment workload"
        return 1
    }

    assert_not_empty \
        "pg_stat_monitor remains accessible after comment workload" \
        "${result}" || return 1

    return 0
}
