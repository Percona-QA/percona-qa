#!/usr/bin/env bash

###############################################################################
# PGSM Test Framework
#
# Test ID:   PGSM-BUCKET-002
# Test Name: Verify bucket changes after bucket expiration
# Suite:     buckets
#
###############################################################################

TEST_ID="PGSM-BUCKET-002"
TEST_NAME="Verify bucket changes after bucket expiration"
TEST_SUITE="buckets"

test_setup()
{
    log_info "Setting pgsm_bucket_time to 2 seconds"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_bucket_time" \
        "2" || {
            log_error "Unable to configure pgsm_bucket_time"
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
    log_info "Restoring pgsm_bucket_time"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_bucket_time" \
        "60" || {
            log_warn "Unable to restore pgsm_bucket_time"
            return 1
        }

    postgres_restart || {
        log_warn "Unable to restart PostgreSQL after restoring pgsm_bucket_time"
        return 1
    }
}

test_body()
{
    local query_1
    local query_2
    local bucket_1
    local bucket_2

    query_1="SELECT 20001 AS pgsm_bucket_test_002_a;"
    query_2="SELECT 20002 AS pgsm_bucket_test_002_b;"

    log_info "Executing first test query"

    execute_sql "${query_1}" >/dev/null || {
        log_error "First test query failed"
        return 1
    }

    bucket_1="$(
        pgsm_query \
            "SELECT bucket
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_002_a%'
             ORDER BY bucket DESC
             LIMIT 1;"
    )" || {
        log_error "Unable to retrieve bucket for first query"
        return 1
    }

    assert_not_empty \
        "First query has a bucket" \
        "${bucket_1}" || return 1

    log_info "First query bucket: ${bucket_1}"

    log_info "Waiting for bucket expiration"

    sleep 3

    log_info "Executing second test query"

    execute_sql "${query_2}" >/dev/null || {
        log_error "Second test query failed"
        return 1
    }

    bucket_2="$(
        pgsm_query \
            "SELECT bucket
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_002_b%'
             ORDER BY bucket DESC
             LIMIT 1;"
    )" || {
        log_error "Unable to retrieve bucket for second query"
        return 1
    }

    assert_not_empty \
        "Second query has a bucket" \
        "${bucket_2}" || return 1

    log_info "Second query bucket: ${bucket_2}"

    assert_not_equal \
        "Query executed after bucket expiration is assigned to a different bucket" \
        "${bucket_1}" \
        "${bucket_2}" || return 1

    return 0
}
