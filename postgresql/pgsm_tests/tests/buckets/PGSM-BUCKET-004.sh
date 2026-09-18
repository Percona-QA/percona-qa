#!/usr/bin/env bash

TEST_ID="PGSM-BUCKET-004"
TEST_NAME="Verify oldest bucket is reused after bucket chain is exhausted"
TEST_SUITE="bucket"

FUNCTION_NAME="pgsm_bucket_test_004"

test_body()
{
    local first_bucket
    local first_bucket_time
    local first_queryid

    local second_bucket
    local second_bucket_time
    local second_queryid

    local third_bucket
    local third_bucket_time
    local third_queryid

    local fourth_bucket
    local fourth_bucket_time
    local fourth_queryid

    local bucket_count
    local result

    # -------------------------------------------------------------------------
    # Configure PGSM with a small bucket chain.
    # -------------------------------------------------------------------------

    pgsm_set_guc_system "pg_stat_monitor.pgsm_max_buckets" "3" || {
        log_error "Unable to set pgsm_max_buckets=3"
        return 1
    }

    pgsm_set_guc_system "pg_stat_monitor.pgsm_bucket_time" "2" || {
        log_error "Unable to set pgsm_bucket_time=2"
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

    # -------------------------------------------------------------------------
    # Bucket 1
    # -------------------------------------------------------------------------

    execute_sql \
        "SELECT 40001 AS ${FUNCTION_NAME}_a;" >/dev/null || {
        log_error "Unable to execute first bucket query"
        return 1
    }

    first_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_a%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first bucket"
        return 1
    }

    first_bucket_time="$(
        pgsm_query \
            "SELECT bucket_start_time
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_a%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first bucket start time"
        return 1
    }

    first_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_a%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve first queryid"
        return 1
    }

    assert_not_empty \
        "First query is tracked" \
        "${first_bucket}" || return 1

    log_info \
        "First bucket: ${first_bucket}, start time: ${first_bucket_time}, queryid: ${first_queryid}"

    # -------------------------------------------------------------------------
    # Wait until PGSM moves to a later bucket.
    # -------------------------------------------------------------------------

    local attempts=0
    local current_bucket_time

    while [[ ${attempts} -lt 10 ]]
    do
        current_bucket_time="$(
            pgsm_query \
                "SELECT MAX(bucket_start_time)
                   FROM pg_stat_monitor"
        )" || {
            log_error "Unable to determine current bucket"
            return 1
        }

        if [[ -n "${current_bucket_time}" &&
              "${current_bucket_time}" != "${first_bucket_time}" ]]
        then
            break
        fi

        sleep 1
        attempts=$((attempts + 1))
    done

    if [[ ${attempts} -eq 10 ]]
    then
        log_error "Timed out waiting for PGSM to create the second bucket"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Bucket 2
    # -------------------------------------------------------------------------

    execute_sql \
        "SELECT 40002 AS ${FUNCTION_NAME}_b;" >/dev/null || {
        log_error "Unable to execute second bucket query"
        return 1
    }

    second_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_b%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second bucket"
        return 1
    }

    second_bucket_time="$(
        pgsm_query \
            "SELECT bucket_start_time
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_b%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second bucket start time"
        return 1
    }

    second_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_b%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve second queryid"
        return 1
    }

    assert_not_empty \
        "Second query is tracked" \
        "${second_bucket}" || return 1

    assert_not_equal \
        "Second query is stored in a different bucket" \
        "${first_bucket}" \
        "${second_bucket}" || return 1

    log_info \
        "Second bucket: ${second_bucket}, start time: ${second_bucket_time}, queryid: ${second_queryid}"

    # -------------------------------------------------------------------------
    # Wait until PGSM moves to a third bucket.
    # -------------------------------------------------------------------------

    attempts=0

    while [[ ${attempts} -lt 10 ]]
    do
        current_bucket_time="$(
            pgsm_query \
                "SELECT MAX(bucket_start_time)
                   FROM pg_stat_monitor"
        )" || {
            log_error "Unable to determine current bucket"
            return 1
        }

        if [[ -n "${current_bucket_time}" &&
              "${current_bucket_time}" != "${second_bucket_time}" ]]
        then
            break
        fi

        sleep 1
        attempts=$((attempts + 1))
    done

    if [[ ${attempts} -eq 10 ]]
    then
        log_error "Timed out waiting for PGSM to create the third bucket"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Bucket 3
    # -------------------------------------------------------------------------

    execute_sql \
        "SELECT 40003 AS ${FUNCTION_NAME}_c;" >/dev/null || {
        log_error "Unable to execute third bucket query"
        return 1
    }

    third_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_c%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve third bucket"
        return 1
    }

    third_bucket_time="$(
        pgsm_query \
            "SELECT bucket_start_time
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_c%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve third bucket start time"
        return 1
    }

    third_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_c%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve third queryid"
        return 1
    }

    assert_not_empty \
        "Third query is tracked" \
        "${third_bucket}" || return 1

    assert_not_equal \
        "Third query is stored in a different bucket than the second query" \
        "${second_bucket}" \
        "${third_bucket}" || return 1

    log_info \
        "Third bucket: ${third_bucket}, start time: ${third_bucket_time}, queryid: ${third_queryid}"

    # -------------------------------------------------------------------------
    # Verify that the bucket chain has reached its configured maximum.
    # -------------------------------------------------------------------------

    bucket_count="$(
        pgsm_query \
            "SELECT COUNT(DISTINCT bucket)
               FROM pg_stat_monitor"
    )" || {
        log_error "Unable to determine active bucket count"
        return 1
    }

    assert_equal \
        "Three active buckets exist after bucket chain is filled" \
        "3" \
        "${bucket_count}" || return 1

    # -------------------------------------------------------------------------
    # Wait for the next bucket transition.
    # -------------------------------------------------------------------------

    attempts=0

    while [[ ${attempts} -lt 10 ]]
    do
        current_bucket_time="$(
            pgsm_query \
                "SELECT MAX(bucket_start_time)
                   FROM pg_stat_monitor"
        )" || {
            log_error "Unable to determine current bucket"
            return 1
        }

        if [[ -n "${current_bucket_time}" &&
              "${current_bucket_time}" != "${third_bucket_time}" ]]
        then
            break
        fi

        sleep 1
        attempts=$((attempts + 1))
    done

    if [[ ${attempts} -eq 10 ]]
    then
        log_error "Timed out waiting for bucket chain exhaustion"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Bucket 4
    #
    # Executing this query after the bucket transition forces PGSM to use
    # the newly active bucket.
    # -------------------------------------------------------------------------

    execute_sql \
        "SELECT 40004 AS ${FUNCTION_NAME}_d;" >/dev/null || {
        log_error "Unable to execute fourth bucket query"
        return 1
    }

    fourth_bucket="$(
        pgsm_query \
            "SELECT bucket
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_d%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve fourth bucket"
        return 1
    }

    fourth_bucket_time="$(
        pgsm_query \
            "SELECT bucket_start_time
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_d%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve fourth bucket start time"
        return 1
    }

    fourth_queryid="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_d%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to retrieve fourth queryid"
        return 1
    }

    assert_not_empty \
        "Fourth query is tracked" \
        "${fourth_bucket}" || return 1

    log_info \
        "Fourth bucket: ${fourth_bucket}, start time: ${fourth_bucket_time}, queryid: ${fourth_queryid}"

    # -------------------------------------------------------------------------
    # Verify that PGSM still respects pgsm_max_buckets=3.
    # -------------------------------------------------------------------------

    bucket_count="$(
        pgsm_query \
            "SELECT COUNT(DISTINCT bucket)
               FROM pg_stat_monitor"
    )" || {
        log_error "Unable to determine final active bucket count"
        return 1
    }

    if [[ ${bucket_count} -gt 3 ]]
    then
        log_error \
            "PGSM exceeded pgsm_max_buckets=3: found ${bucket_count} buckets"
        return 1
    fi

    log_info \
        "Final active bucket count: ${bucket_count}"

    # -------------------------------------------------------------------------
    # Verify that the oldest bucket has been evicted.
    #
    # Bucket chronology is determined by bucket_start_time, not bucket ID.
    # -------------------------------------------------------------------------

    result="$(
        pgsm_query \
            "SELECT COUNT(*)
               FROM pg_stat_monitor
              WHERE bucket_start_time = '${first_bucket_time}'"
    )" || {
       log_error "Unable to verify eviction of the oldest bucket"
       return 1
    }

    if [[ "${result}" != "0" ]]
    then
        log_error \
            "Oldest bucket was not evicted: bucket_start_time=${first_bucket_time}, rows=${result}"
        return 1
    fi

    log_info \
        "Oldest bucket was evicted successfully: bucket_start_time=${first_bucket_time}"

    # -------------------------------------------------------------------------
    # Verify that the newest query remains available.
    # -------------------------------------------------------------------------

    result="$(
        pgsm_query \
            "SELECT queryid
               FROM pg_stat_monitor
              WHERE bucket = ${fourth_bucket}
                AND queryid = ${fourth_queryid}
              LIMIT 1"
    )" || {
        log_error "Unable to verify newest bucket"
        return 1
    }

    assert_not_empty \
        "Newest bucket/query remains tracked after bucket reuse" \
        "${result}" || return 1

    # -------------------------------------------------------------------------
    # Final sanity check: verify the newest query by its marker.
    # -------------------------------------------------------------------------

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%${FUNCTION_NAME}_d%'
              ORDER BY bucket_start_time DESC
              LIMIT 1"
    )" || {
        log_error "Unable to verify newest query"
        return 1
    }

    assert_not_empty \
        "Newest query remains in pg_stat_monitor" \
        "${result}" || return 1

    log_info \
        "PGSM bucket chain exhausted and oldest bucket successfully reused"

    return 0
}
