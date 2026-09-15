#!/bin/bash

TEST_ID="PGSM-BUCKET-003"
TEST_NAME="Verify statistics are retained across active buckets"
TEST_SUITE="buckets"

test_setup()
{
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

test_body()
{
    local first_bucket
    local first_queryid
    local second_bucket
    local first_query_count

    pgsm_reset || return 1

    log_info "Executing first query"

    execute_sql \
        "SELECT 30001 AS pgsm_bucket_test_003_a;" >/dev/null || {
        log_error "Unable to execute first query"
        return 1
    }

    # Capture the bucket and queryid belonging to the first query.
    first_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query = 'SELECT 30001 AS pgsm_bucket_test_003_a'
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first query bucket"
        return 1
    }

    first_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query = 'SELECT 30001 AS pgsm_bucket_test_003_a'
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first queryid"
        return 1
    }

    assert_not_empty \
        "First query statistics are available" \
        "${first_bucket}" || return 1

    assert_not_empty \
        "First query ID is available" \
        "${first_queryid}" || return 1

    log_info "First query bucket: ${first_bucket}"
    log_info "First queryid: ${first_queryid}"

    sleep 3
    log_info "Executing second query"

    execute_sql \
        "SELECT 30002 AS pgsm_bucket_test_003_b;" >/dev/null || {
        log_error "Unable to execute second query"
        return 1
    }
    second_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query = 'SELECT 30002 AS pgsm_bucket_test_003_b'
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second query bucket"
        return 1
    }

    second_queryid="$(
        pgsm_query \
            "SELECT queryid
              FROM pg_stat_monitor
              WHERE query = 'SELECT 30002 AS pgsm_bucket_test_003_b'
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second queryid"
        return 1
    }

    assert_not_empty \
        "Second query statistics are available" \
        "${second_bucket}" || return 1

    assert_not_empty \
        "Second query ID is available" \
        "${second_queryid}" || return 1

    assert_not_empty \
        "Second bucket is available" \
        "${second_bucket}" || return 1

    assert_not_equal \
        "Queries are stored in different buckets" \
        "${first_bucket}" \
        "${second_bucket}" || return 1

    log_info "Second query bucket: ${second_bucket}"

    log_info "Verifying first query is still retained"

    first_query_count="$(
        pgsm_query \
            "SELECT count(*)
               FROM pg_stat_monitor
              WHERE bucket = ${first_bucket}
                AND queryid = ${first_queryid}"
    )" || {
        log_error "Unable to verify first query retention"
        return 1
    }

    assert_equal \
        "First query remains available in previous bucket" \
        "1" \
        "${first_query_count}" || return 1

    return 0
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

}

