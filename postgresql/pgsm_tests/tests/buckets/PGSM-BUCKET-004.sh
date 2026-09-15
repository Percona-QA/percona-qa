#!/bin/bash

###############################################################################
# PGSM Test Framework
#
# Test ID:   PGSM-BUCKET-004
# Test Name: Verify oldest bucket is reused after bucket chain is exhausted
# Suite:     buckets
#
###############################################################################

TEST_ID="PGSM-BUCKET-004"
TEST_NAME="Verify oldest bucket is reused after bucket chain is exhausted"
TEST_SUITE="buckets"

test_setup()
{
    log_info "Setting pgsm_max_buckets to 3"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_max_buckets" \
        "3" || {
        log_error "Unable to configure pgsm_max_buckets"
        return 1
    }

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
    log_info "Restoring bucket configuration"

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_max_buckets" \
        "10" || {
        log_warn "Unable to restore pgsm_max_buckets"
        return 1
    }

    pgsm_set_guc_system \
        "pg_stat_monitor.pgsm_bucket_time" \
        "60" || {
        log_warn "Unable to restore pgsm_bucket_time"
        return 1
    }

    postgres_restart || {
        log_warn "Unable to restart PostgreSQL after restoring bucket configuration"
        return 1
    }
}

test_body()
{
    local first_bucket
    local first_queryid
    local second_bucket
    local third_bucket
    local fourth_bucket
    local bucket_count
    local first_query_count
    local fourth_query_count

    ###########################################################################
    # First query
    ###########################################################################

    log_info "Executing first query"

    execute_sql \
        "SELECT 40001 AS pgsm_bucket_test_004_a;" >/dev/null || {
        log_error "First test query failed"
        return 1
    }

    first_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_a%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first bucket"
        return 1
    }

    first_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_a%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first queryid"
        return 1
    }

    assert_not_empty \
        "First query is tracked" \
        "${first_bucket}" || return 1

    assert_not_empty \
        "First queryid is available" \
        "${first_queryid}" || return 1

    log_info "First query bucket: ${first_bucket}"
    log_info "First queryid: ${first_queryid}"

    ###########################################################################
    # Second query - force second bucket
    ###########################################################################

    log_info "Waiting for next bucket"

    sleep 3

    log_info "Executing second query"

    execute_sql \
        "SELECT 40002 AS pgsm_bucket_test_004_b;" >/dev/null || {
        log_error "Second test query failed"
        return 1
    }

    second_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_b%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second bucket"
        return 1
    }

    assert_not_empty \
        "Second query is tracked" \
        "${second_bucket}" || return 1

    assert_not_equal \
        "Second query is stored in a different bucket" \
        "${first_bucket}" \
        "${second_bucket}" || return 1

    log_info "Second query bucket: ${second_bucket}"

    ###########################################################################
    # Third query - force third bucket
    ###########################################################################

    log_info "Waiting for next bucket"

    sleep 3

    log_info "Executing third query"

    execute_sql \
        "SELECT 40003 AS pgsm_bucket_test_004_c;" >/dev/null || {
        log_error "Third test query failed"
        return 1
    }

    third_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_c%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve third bucket"
        return 1
    }

    assert_not_empty \
        "Third query is tracked" \
        "${third_bucket}" || return 1

    assert_not_equal \
        "Third query is stored in a different bucket" \
        "${second_bucket}" \
        "${third_bucket}" || return 1

    log_info "Third query bucket: ${third_bucket}"

    ###########################################################################
    # Verify three buckets exist
    ###########################################################################

    bucket_count="$(
        pgsm_query \
            "SELECT count(DISTINCT bucket)
               FROM pg_stat_monitor"
    )" || {
        log_error "Unable to determine active bucket count"
        return 1
    }

    log_info "Active bucket count before exhaustion: ${bucket_count}"

    assert_equal \
        "Three active buckets exist before bucket chain exhaustion" \
        "3" \
        "${bucket_count}" || return 1

    ###########################################################################
    # Fourth query - exhaust bucket chain
    ###########################################################################

    log_info "Waiting for next bucket"

    sleep 3

    log_info "Executing fourth query"

    execute_sql \
        "SELECT 40004 AS pgsm_bucket_test_004_d;" >/dev/null || {
        log_error "Fourth test query failed"
        return 1
    }

    fourth_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_d%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve fourth bucket"
        return 1
    }

    assert_not_empty \
        "Fourth query is tracked" \
        "${fourth_bucket}" || return 1

    log_info "Fourth query bucket: ${fourth_bucket}"

    ###########################################################################
    # Verify bucket count does not exceed configured maximum.
    ###########################################################################

    bucket_count="$(
        pgsm_query \
            "SELECT count(DISTINCT bucket)
               FROM pg_stat_monitor"
    )" || {
        log_error "Unable to determine final bucket count"
        return 1
    }

    log_info "Final active bucket count: ${bucket_count}"

    if [[ "${bucket_count}" -gt 3 ]]; then
        log_error \
            "Bucket count exceeded configured pgsm_max_buckets: ${bucket_count}"
        return 1
    fi

    ###########################################################################
    # Verify oldest query was removed.
    #
    # IMPORTANT:
    # Do NOT search by query text here because the verification query itself
    # would contain the query text and could be tracked by PGSM.
    ###########################################################################

    first_query_count="$(
        pgsm_query \
            "SELECT count(*)
               FROM pg_stat_monitor
              WHERE bucket = ${first_bucket}
                AND queryid = ${first_queryid}"
    )" || {
        log_error "Unable to verify oldest query removal"
        return 1
    }

    assert_equal \
        "Oldest query is removed after bucket chain exhaustion" \
        "0" \
        "${first_query_count}" || return 1

    ###########################################################################
    # Verify newest query remains.
    ###########################################################################

    local fourth_queryid

    fourth_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_bucket_test_004_d%'
              ORDER BY bucket DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve fourth queryid"
        return 1
    }

    fourth_query_count="$(
        pgsm_query \
            "SELECT count(*)
               FROM pg_stat_monitor
              WHERE bucket = ${fourth_bucket}
                AND queryid = ${fourth_queryid}"
    )" || {
        log_error "Unable to verify newest query retention"
        return 1
    }

    assert_equal \
        "Newest query remains available after bucket reuse" \
        "1" \
        "${fourth_query_count}" || return 1

    return 0
}

