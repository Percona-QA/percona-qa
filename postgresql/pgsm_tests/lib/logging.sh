#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# PGSM Test Framework - Logging
# -----------------------------------------------------------------------------

LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3
LOG_LEVEL_DEBUG=4

PGSM_LOG_LEVEL="${PGSM_LOG_LEVEL:-${LOG_LEVEL_INFO}}"


log_timestamp()
{
    date '+%Y-%m-%d %H:%M:%S'
}


log_info()
{
    echo "[INFO] $(log_timestamp) $*"
}


log_warn()
{
    echo "[WARN] $(log_timestamp) $*" >&2
}


log_error()
{
    echo "[ERROR] $(log_timestamp) $*" >&2
}


log_debug()
{
    if [[ "${PGSM_VERBOSE:-0}" -eq 1 ]]; then
        echo "[DEBUG] $(log_timestamp) $*"
    fi
}


log_test_start()
{
    local test_id="$1"
    local test_name="$2"

    echo
    echo "======================================================================"
    echo "TEST: ${test_id}"
    echo "NAME: ${test_name}"
    echo "======================================================================"
}


log_test_pass()
{
    local test_id="$1"
    local test_name="$2"

    echo "[PASS] ${test_id}: ${test_name}"
}


log_test_fail()
{
    local test_id="$1"
    local test_name="$2"

    echo "[FAIL] ${test_id}: ${test_name}"
}


log_test_skip()
{
    local test_id="$1"
    local test_name="$2"
    local reason="${3:-No reason provided}"

    echo "[SKIP] ${test_id}: ${test_name}"
    echo "       Reason: ${reason}"
}


log_section()
{
    local title="$1"

    echo
    echo "----------------------------------------------------------------------"
    echo "${title}"
    echo "----------------------------------------------------------------------"
}


log_command()
{
    if [[ "${PGSM_VERBOSE:-0}" -eq 1 ]]; then
        echo "[CMD]  $*"
    fi
}


log_file_init()
{
    local log_file="$1"

    if [[ -z "${log_file}" ]]; then
        return 1
    fi

    mkdir -p "$(dirname "${log_file}")" || return 1

    : > "${log_file}" || return 1

    return 0
}


log_to_file()
{
    local log_file="$1"
    shift

    if [[ -z "${log_file}" ]]; then
        return 1
    fi

    printf '%s\n' "$*" >> "${log_file}"
}


log_result()
{
    local status="$1"
    local test_id="$2"
    local test_name="$3"

    case "${status}" in
        PASS)
            log_test_pass "${test_id}" "${test_name}"
            ;;
        FAIL)
            log_test_fail "${test_id}" "${test_name}"
            ;;
        SKIP)
            log_test_skip "${test_id}" "${test_name}"
            ;;
        *)
            log_error "Unknown test result: ${status}"
            return 1
            ;;
    esac
}
