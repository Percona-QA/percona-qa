#!/usr/bin/env bash

###############################################################################
# PGSM Test Framework
#
# Test ID:   PGSM-BUCKET-001
# Test Name: Verify executed query is assigned to a bucket
# Suite:     buckets
#
###############################################################################

TEST_ID="PGSM-BUCKET-001"
TEST_NAME="Verify executed query is assigned to a bucket"
TEST_SUITE="buckets"

test_body()
{
    log_info "Resetting pg_stat_monitor statistics"

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor"
        return 1
    }

    local query
    local result

    query="SELECT 10001 AS pgsm_bucket_test_001;"

    log_info "Executing test query"

    execute_sql "${query}" >/dev/null || {
        log_error "Test query failed"
        return 1
    }

    log_info "Checking bucket information"

    result="$(
        pgsm_query \
            "SELECT bucket, bucket_start_time
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_001%'
             ORDER BY bucket DESC
             LIMIT 1;"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    log_info "Bucket result: ${result}"

    assert_not_empty \
        "Tracked query has bucket information" \
        "${result}" || return 1

    local bucket
    local bucket_start_time

    bucket="$(printf '%s\n' "${result}" | cut -d'|' -f1)"
    bucket_start_time="$(printf '%s\n' "${result}" | cut -d'|' -f2)"

    assert_not_empty \
        "Bucket ID is not empty" \
        "${bucket}" || return 1

    assert_not_empty \
        "Bucket start time is not empty" \
        "${bucket_start_time}" || return 1

    if [[ ! "${bucket}" =~ ^[0-9]+$ ]]; then
        log_error "Bucket ID is not numeric: ${bucket}"
        return 1
    fi

    log_info "Query assigned to bucket: ${bucket}"
    log_info "Bucket start time: ${bucket_start_time}"

    return 0
}
