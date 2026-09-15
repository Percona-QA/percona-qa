#!/usr/bin/env bash

###############################################################################
# PGSM Test Framework
#
# Test ID:   PGSM-BUCKET-005
# Test Name: Verify statistics are removed when an old bucket is reused
# Suite:     buckets
#
###############################################################################

TEST_ID="PGSM-BUCKET-005"
TEST_NAME="Verify statistics are removed when an old bucket is reused"
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
    local old_query
    local new_query
    local old_count
    local new_count

    old_query="SELECT 50001 AS pgsm_bucket_test_005_old;"

    log_info "Executing query that should eventually be overwritten"

    execute_sql "${old_query}" >/dev/null || {
        log_error "Initial test query failed"
        return 1
    }

    old_count="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_005_old%';"
    )" || {
        log_error "Unable to verify initial query"
        return 1
    }

    assert_equal \
        "Initial query is tracked" \
        "1" \
        "${old_count}" || return 1

    log_info "Initial query is present in pg_stat_monitor"

    log_info "Waiting for the bucket chain to rotate and reuse the oldest bucket"

    # Three buckets x two seconds plus an additional interval to ensure
    # the oldest bucket has expired and is eligible for reuse.
    sleep 7

    new_query="SELECT 50002 AS pgsm_bucket_test_005_new;"

    log_info "Executing query after bucket chain rotation"

    execute_sql "${new_query}" >/dev/null || {
        log_error "Final test query failed"
        return 1
    }

    new_count="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_005_new%';"
    )" || {
        log_error "Unable to verify final query"
        return 1
    }

    assert_equal \
        "New query is tracked after bucket rotation" \
        "1" \
        "${new_count}" || return 1

    log_info "Checking whether the old query was removed"

    old_count="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query LIKE '%pgsm_bucket_test_005_old%';"
    )" || {
        log_error "Unable to verify old query after bucket rotation"
        return 1
    }

    assert_equal \
        "Old bucket statistics are removed when the bucket is reused" \
        "0" \
        "${old_count}" || return 1

    return 0
}
