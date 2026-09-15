#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-005"
TEST_NAME="Verify pg_stat_monitor handles deeply nested queries"
TEST_SUITE="stress"

test_body()
{
    local depth=100
    local query="SELECT 1"
    local i
    local result

    log_info "Generating nested query with depth ${depth}"

    for ((i = 1; i <= depth; i++)); do
        query="SELECT (${query})"
    done

    log_info "Executing deeply nested query"

    execute_sql "${query}" >/dev/null || {
        log_error "Deeply nested query failed"
        return 1
    }

    assert_command_success \
        "PostgreSQL remains running after deeply nested query" \
        postgres_is_running || return 1

    result="$(
        pgsm_query \
            "SELECT count(*)
             FROM pg_stat_monitor
             WHERE query IS NOT NULL;"
    )" || {
        log_error "pg_stat_monitor became inaccessible after nested query"
        return 1
    }

    assert_not_empty \
        "pg_stat_monitor remains accessible after nested query" \
        "${result}" || return 1

    return 0
}
