#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-003"
TEST_NAME="Verify pg_stat_monitor handles long query text"
TEST_SUITE="stress"

test_setup()
{
    log_info "Setting pgsm_query_max_len to 4096"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_query_max_len" \
        "4096" || {
        log_error "Unable to configure pgsm_query_max_len"
        return 1
    }

    postgres_restart || {
        log_error "Unable to restart PostgreSQL"
        return 1
    }

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor"
        return 1
    }
}

test_cleanup()
{
    log_info "Restoring pgsm_query_max_len"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_query_max_len" \
        "2048" || {
        log_warn "Unable to restore pgsm_query_max_len"
        return 1
    }

    postgres_restart || {
        log_warn "Unable to restart PostgreSQL"
        return 1
    }
}

test_body()
{
    local long_value
    local query
    local result

    log_info "Generating long query"

    long_value="$(printf 'A%.0s' {1..3500})"

    query="SELECT '${long_value}' AS pgsm_stress_003;"

    log_info "Executing long query"

    execute_sql "${query}" >/dev/null || {
        log_error "Long query execution failed"
        return 1
    }

    log_info "Verifying pg_stat_monitor remains accessible"

    result="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_stress_003%';"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Long query is handled by pg_stat_monitor" \
        "${result}" || return 1

    assert_command_success \
        "PostgreSQL remains running after long query" \
        postgres_is_running || return 1

    return 0
}
