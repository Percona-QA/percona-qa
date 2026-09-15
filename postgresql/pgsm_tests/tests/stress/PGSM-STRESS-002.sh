#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-002"
TEST_NAME="Verify pg_stat_monitor handles many distinct queries"
TEST_SUITE="stress"

test_setup()
{
    log_info "Setting pgsm_max to 10 MB"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_max" \
        "10" || {
        log_error "Unable to configure pgsm_max"
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
    log_info "Restoring pgsm_max"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_max" \
        "256" || {
        log_warn "Unable to restore pgsm_max"
        return 1
    }

    postgres_restart || {
        log_warn "Unable to restart PostgreSQL"
        return 1
    }
}

test_body()
{
    local query_count=5000
    local i
    local result

    log_info "Generating ${query_count} distinct queries"

    for ((i = 1; i <= query_count; i++)); do

        execute_sql \
            "SELECT ${i} AS pgsm_stress_002_${i};" \
            >/dev/null || {
                log_error "Query execution failed at iteration ${i}"
                return 1
            }

    done

    log_info "Verifying PostgreSQL remains available"

    assert_command_success \
        "PostgreSQL remains running after many distinct queries" \
        postgres_is_running || return 1

    result="$(
        pgsm_query \
            "SELECT count(*) FROM pg_stat_monitor;"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "pg_stat_monitor remains accessible" \
        "${result}" || return 1

    log_info "Tracked rows: ${result}"

    return 0
}
