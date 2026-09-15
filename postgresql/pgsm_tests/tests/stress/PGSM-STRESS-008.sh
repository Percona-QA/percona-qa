#!/usr/bin/env bash

TEST_ID="PGSM-STRESS-008"
TEST_NAME="Verify pg_stat_monitor handles concurrent query execution"
TEST_SUITE="stress"

test_body()
{
    local clients=10
    local queries_per_client=500
    local pid_file
    local i
    local pid
    local result

    pid_file="${PGSM_RUNTIME_DIR}/pgsm_stress_008_pids"

    : > "${pid_file}" || {
        log_error "Unable to create PID file"
        return 1
    }

    pgsm_reset || {
        log_error "Unable to reset pg_stat_monitor"
        return 1
    }

    log_info \
        "Starting ${clients} concurrent clients with ${queries_per_client} queries each"

    for ((i = 1; i <= clients; i++)); do

        (
            local j

            for ((j = 1; j <= queries_per_client; j++)); do

                execute_sql \
                    "SELECT ${i}, ${j} AS pgsm_stress_008;" \
                    >/dev/null || exit 1

            done

        ) &

        pid=$!
        echo "${pid}" >> "${pid_file}"

    done

    log_info "Waiting for concurrent clients"

    local failed=0

    while IFS= read -r pid; do

        if ! wait "${pid}"; then
            log_error "Concurrent client ${pid} failed"
            failed=1
        fi

    done < "${pid_file}"

    rm -f "${pid_file}"

    if [[ "${failed}" -ne 0 ]]; then
        return 1
    fi

    assert_command_success \
        "PostgreSQL remains running after concurrent workload" \
        postgres_is_running || return 1

    result="$(
        pgsm_query \
            "SELECT count(*) FROM pg_stat_monitor;"
    )" || {
        log_error "Unable to query pg_stat_monitor after concurrent workload"
        return 1
    }

    assert_not_empty \
        "pg_stat_monitor remains accessible after concurrent workload" \
        "${result}" || return 1

    return 0
}
