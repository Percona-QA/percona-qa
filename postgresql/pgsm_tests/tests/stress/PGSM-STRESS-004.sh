#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-004"
TEST_NAME="Verify query normalization handles a large workload"
TEST_SUITE="stress"

test_setup()
{
    log_info "Enabling query normalization"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_normalized_query" \
        "on" || {
        log_error "Unable to enable query normalization"
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
    log_info "Restoring query normalization"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_normalized_query" \
        "off" || {
        log_warn "Unable to restore query normalization"
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

    log_info "Executing ${query_count} queries requiring normalization"

    for ((i = 1; i <= query_count; i++)); do

        execute_sql \
            "SELECT ${i} AS pgsm_stress_004;" \
            >/dev/null || {
                log_error "Query execution failed at iteration ${i}"
                return 1
            }

    done

    result="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_stress_004%';"
    )" || {
        log_error "Unable to query normalized statements"
        return 1
    }

    assert_not_empty \
        "Normalized workload is present in pg_stat_monitor" \
        "${result}" || return 1

    assert_command_success \
        "PostgreSQL remains running after normalization workload" \
        postgres_is_running || return 1

    return 0
}
