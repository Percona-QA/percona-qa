#!/usr/bin/env bash

TEST_ID="PGSM-GUC-001"
TEST_NAME="Verify all pg_stat_monitor GUCs"
TEST_SUITE="guc"

test_body()
{
    log_info "Checking pg_stat_monitor GUCs"


    # --------------------------------------------------------------------------
    # Expected GUCs
    # --------------------------------------------------------------------------

    local expected_gucs=(
        "pg_stat_monitor.pgsm_max"
        "pg_stat_monitor.pgsm_query_max_len"
        "pg_stat_monitor.pgsm_max_buckets"
        "pg_stat_monitor.pgsm_bucket_time"
        "pg_stat_monitor.pgsm_histogram_min"
        "pg_stat_monitor.pgsm_histogram_max"
        "pg_stat_monitor.pgsm_histogram_buckets"
        "pg_stat_monitor.pgsm_query_shared_buffer"
        "pg_stat_monitor.pgsm_track_utility"
        "pg_stat_monitor.pgsm_track_application_names"
        "pg_stat_monitor.pgsm_enable_pgsm_query_id"
        "pg_stat_monitor.pgsm_normalized_query"
        "pg_stat_monitor.pgsm_enable_overflow"
        "pg_stat_monitor.pgsm_enable_query_plan"
        "pg_stat_monitor.pgsm_extract_comments"
        "pg_stat_monitor.pgsm_track"
        "pg_stat_monitor.pgsm_track_planning"
    )


    # --------------------------------------------------------------------------
    # Verify every expected GUC exists
    # --------------------------------------------------------------------------

    local guc
    local setting

    for guc in "${expected_gucs[@]}"; do

        setting="$(
            execute_sql \
                "SELECT setting
                   FROM pg_settings
                  WHERE name = '${guc}';"
        )" || {
            log_error "Unable to query GUC: ${guc}"
            return 1
        }

        assert_not_empty \
            "${guc} exists" \
            "${setting}" || return 1

        log_debug "${guc} = ${setting}"
    done


    # --------------------------------------------------------------------------
    # Verify there are no unexpected PGSM GUCs
    # --------------------------------------------------------------------------

    local actual_gucs
    local unexpected_gucs

    actual_gucs="$(
        execute_sql \
            "SELECT name
               FROM pg_settings
              WHERE name LIKE 'pg_stat_monitor.%'
              ORDER BY name;"
    )" || {
        log_error "Unable to retrieve pg_stat_monitor GUC list"
        return 1
    }


    unexpected_gucs=""

    while IFS= read -r guc; do
        [[ -z "${guc}" ]] && continue

        local found=false

        for expected in "${expected_gucs[@]}"; do
            if [[ "${guc}" == "${expected}" ]]; then
                found=true
                break
            fi
        done

        if [[ "${found}" == "false" ]]; then
            unexpected_gucs+="${guc}"$'\n'
        fi
    done <<< "${actual_gucs}"


    if [[ -n "${unexpected_gucs}" ]]; then
        log_error "Unexpected pg_stat_monitor GUCs found:"
        printf '%s' "${unexpected_gucs}" >&2
        return 1
    fi

    log_info "[PASS] No unexpected pg_stat_monitor GUCs found"


    # --------------------------------------------------------------------------
    # Verify GUC metadata
    # --------------------------------------------------------------------------

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_max" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_query_max_len" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_max_buckets" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_bucket_time" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_histogram_min" \
        "real" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_histogram_max" \
        "real" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_histogram_buckets" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_query_shared_buffer" \
        "integer" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_track_utility" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_track_application_names" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_enable_pgsm_query_id" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_normalized_query" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_enable_overflow" \
        "bool" \
        "postmaster" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_enable_query_plan" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_extract_comments" \
        "bool" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_track" \
        "enum" \
        "user" || return 1

    assert_guc_metadata \
        "pg_stat_monitor.pgsm_track_planning" \
        "bool" \
        "user" || return 1


    # --------------------------------------------------------------------------
    # Verify pgsm_track enum values
    # --------------------------------------------------------------------------

    local enum_values

    enum_values="$(
        execute_sql \
            "SELECT enumvals
               FROM pg_settings
              WHERE name = 'pg_stat_monitor.pgsm_track';"
    )" || {
        log_error "Unable to retrieve pgsm_track enum values"
        return 1
    }

    assert_contains \
        "pgsm_track contains 'top'" \
        "${enum_values}" \
        "top" || return 1

    assert_contains \
        "pgsm_track contains 'all'" \
        "${enum_values}" \
        "all" || return 1

    assert_contains \
        "pgsm_track contains 'none'" \
        "${enum_values}" \
        "none" || return 1

    # --------------------------------------------------------------------------
    # Verify pgsm_overflow_target has been removed
    # --------------------------------------------------------------------------

    local overflow_target

    overflow_target="$(
        execute_sql \
            "SELECT name
               FROM pg_settings
              WHERE name = 'pg_stat_monitor.pgsm_overflow_target';"
    )" || {
        log_error "Unable to check removed pgsm_overflow_target GUC"
        return 1
    }

    assert_empty \
        "pgsm_overflow_target is removed" \
        "${overflow_target}" || return 1


    log_info "[PASS] All pg_stat_monitor GUC checks passed"

    return 0
}


# ------------------------------------------------------------------------------
# GUC metadata assertion
# ------------------------------------------------------------------------------

assert_guc_metadata()
{
    local guc="$1"
    local expected_type="$2"
    local expected_context="$3"

    local metadata
    local actual_type
    local actual_context

    metadata="$(
        execute_sql \
            "SELECT vartype || '|' || context
               FROM pg_settings
              WHERE name = '${guc}';"
    )" || {
        log_error "Unable to retrieve metadata for ${guc}"
        return 1
    }

    assert_not_empty \
        "${guc} metadata exists" \
        "${metadata}" || return 1

    IFS='|' read -r actual_type actual_context <<< "${metadata}"

    assert_equal \
        "${guc} type" \
        "${expected_type}" \
        "${actual_type}" || return 1

    assert_equal \
        "${guc} context" \
        "${expected_context}" \
        "${actual_context}" || return 1

    log_debug "${guc}: type=${actual_type}, context=${actual_context}"

    return 0
}
