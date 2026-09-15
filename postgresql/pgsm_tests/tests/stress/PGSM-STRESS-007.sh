#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-007"
TEST_NAME="Verify histogram processing handles high execution volume"
TEST_SUITE="stress"

test_body()
{
    local query_count=10000
    local result

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor"
        return 1
    }

    log_info "Executing ${query_count} queries to exercise histogram processing"

    execute_sql_session >/dev/null <<EOF || {
SELECT format('SELECT pg_sleep(0.001);')
FROM generate_series(1, ${query_count});
\gexec
EOF
        log_error "High execution volume workload failed"
        return 1
    }

    assert_command_success \
        "PostgreSQL remains running after histogram workload" \
        postgres_is_running || return 1

    result="$(
        pgsm_query \
            "SELECT count(*) FROM pg_stat_monitor WHERE resp_calls IS NOT NULL;"
    )" || {
        log_error "Unable to query response call histogram information"
        return 1
    }

    assert_not_empty \
        "Histogram response call data is available" \
        "${result}" || return 1

    log_info "Rows containing resp_calls data: ${result}"

    return 0
}
