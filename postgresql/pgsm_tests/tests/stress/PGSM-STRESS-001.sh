#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-001"
TEST_NAME="Verify pg_stat_monitor handles high query volume"
TEST_SUITE="stress"

test_body()
{
    local query_count=10000
    local i
    local result

    log_info "Resetting pg_stat_monitor"

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor"
        return 1
    }

    log_info "Executing ${query_count} queries"

    for ((i = 1; i <= query_count; i++)); do

        execute_sql \
            "SELECT ${i} AS pgsm_stress_001;" \
            >/dev/null || {
                log_error "Query execution failed at iteration ${i}"
                return 1
            }

    done

    log_info "Verifying PostgreSQL is still running"

    assert_command_success \
        "PostgreSQL remains running after high query volume" \
        postgres_is_running || return 1

    log_info "Verifying pg_stat_monitor is still accessible"

    result="$(pgsm_query "SELECT count(*) FROM pg_stat_monitor;")" || {
        log_error "Unable to query pg_stat_monitor after high query volume"
        return 1
    }

    assert_not_empty \
        "pg_stat_monitor remains queryable" \
        "${result}" || return 1

    log_info "Tracked rows after stress workload: ${result}"

    return 0
}
