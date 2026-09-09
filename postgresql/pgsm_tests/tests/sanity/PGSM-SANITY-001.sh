#!/bin/bash

TEST_ID="PGSM-SANITY-001"
TEST_NAME="Verify pg_stat_monitor installation and version"
TEST_SUITE="sanity"

test_body()
{
    log_info "Checking PostgreSQL is running"

    assert_command_success \
        "PostgreSQL is running" \
        postgres_is_running


    log_info "Checking pg_stat_monitor is loaded"

    assert_command_success \
        "pg_stat_monitor is loaded in shared_preload_libraries" \
        pgsm_is_loaded


    log_info "Checking pg_stat_monitor extension is available"

    assert_command_success \
        "pg_stat_monitor extension is available" \
        pgsm_is_available


    log_info "Checking pg_stat_monitor extension exists"

    assert_command_success \
        "pg_stat_monitor extension exists in database" \
        pgsm_extension_exists


    log_info "Checking pg_stat_monitor version"

    local version

    version="$(pgsm_version)" || {
        log_error "Unable to retrieve pg_stat_monitor version"
        return 1
    }

    if [[ -z "${version}" ]]; then
        log_error "pg_stat_monitor version is empty"
        return 1
    fi

    log_info "pg_stat_monitor version: ${version}"

    local expected_version
    expected_version="${PGSM_EXPECTED_VERSION}"

    assert_not_empty \
        "Expected pg_stat_monitor version is configured" \
        "${expected_version}" || return 1

    assert_not_empty \
        "Installed pg_stat_monitor version" \
        "${version}" || return 1

    assert_equal \
        "pg_stat_monitor version matches expected release version" \
        "${expected_version}" \
        "${version}" || return 1

    return 0
}
