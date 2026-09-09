#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Assertion helpers
# ------------------------------------------------------------------------------

assert_command_success()
{
    local description="$1"
    shift

    if "$@"; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}"
    return 1
}


assert_command_failure()
{
    local description="$1"
    shift

    if "$@"; then
        log_error "[FAIL] ${description}"
        return 1
    fi

    log_info "[PASS] ${description}"
    return 0
}


assert_not_empty()
{
    local description="$1"
    local value="$2"

    if [[ -n "${value}" ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: value is empty"
    return 1
}


assert_empty()
{
    local description="$1"
    local value="$2"

    if [[ -z "${value}" ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: expected empty value, got '${value}'"
    return 1
}


assert_equal()
{
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "${expected}" == "${actual}" ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: expected '${expected}', got '${actual}'"
    return 1
}


assert_not_equal()
{
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "${expected}" != "${actual}" ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: value should not be '${expected}'"
    return 1
}


assert_contains()
{
    local description="$1"
    local value="$2"
    local expected="$3"

    if [[ "${value}" == *"${expected}"* ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: '${expected}' not found in '${value}'"
    return 1
}


assert_not_contains()
{
    local description="$1"
    local value="$2"
    local unexpected="$3"

    if [[ "${value}" != *"${unexpected}"* ]]; then
        log_info "[PASS] ${description}"
        return 0
    fi

    log_error "[FAIL] ${description}: unexpected '${unexpected}' found"
    return 1
}
