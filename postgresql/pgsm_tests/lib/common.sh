#!/usr/bin/bash

###############################################################################
# PGSM Test Framework
#
# Common framework utilities
#
# This file contains generic helper functions shared across the framework.
# It must not contain PostgreSQL-specific or PGSM-specific functionality.
#
###############################################################################

###############################################################################
# String helpers
###############################################################################

trim()
{
    local value="$*"

    # Remove leading whitespace.
    value="${value#"${value%%[![:space:]]*}"}"

    # Remove trailing whitespace.
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s' "${value}"
}

###############################################################################
# Command helpers
###############################################################################

command_exists()
{
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1
}

require_command()
{
    local command_name="$1"

    if ! command_exists "${command_name}"; then
        log_error "Required command not found: ${command_name}"
        return 1
    fi

    return 0
}

###############################################################################
# File and directory helpers
###############################################################################

ensure_directory()
{
    local directory="$1"

    if [[ -z "${directory}" ]]; then
        log_error "Directory path cannot be empty"
        return 1
    fi

    if [[ ! -d "${directory}" ]]; then
        mkdir -p "${directory}" || {
            log_error "Failed to create directory: ${directory}"
            return 1
        }
    fi

    return 0
}

require_file()
{
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        log_error "Required file not found: ${file}"
        return 1
    fi

    return 0
}

require_directory()
{
    local directory="$1"

    if [[ ! -d "${directory}" ]]; then
        log_error "Required directory not found: ${directory}"
        return 1
    fi

    return 0
}

###############################################################################
# Validation helpers
###############################################################################

is_integer()
{
    local value="$1"

    [[ "${value}" =~ ^[0-9]+$ ]]
}

is_positive_integer()
{
    local value="$1"

    [[ "${value}" =~ ^[1-9][0-9]*$ ]]
}

is_boolean()
{
    local value="${1,,}"

    case "${value}" in
        on|off|true|false|yes|no|1|0)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# Environment helpers
###############################################################################

get_timestamp()
{
    date '+%Y-%m-%d_%H-%M-%S'
}

get_epoch_time()
{
    date '+%s'
}

get_hostname()
{
    hostname
}

###############################################################################
# Cleanup helpers
###############################################################################

safe_remove()
{
    local path="$1"

    if [[ -z "${path}" ]]; then
        log_error "Refusing to remove an empty path"
        return 1
    fi

    if [[ "${path}" == "/" ]]; then
        log_error "Refusing to remove root directory"
        return 1
    fi

    rm -rf "${path}"
}

###############################################################################
# Retry helper
###############################################################################

retry_command()
{
    local attempts="$1"
    local delay="$2"

    shift 2

    if ! is_positive_integer "${attempts}"; then
        log_error "Invalid retry attempt count: ${attempts}"
        return 1
    fi

    if ! is_integer "${delay}"; then
        log_error "Invalid retry delay: ${delay}"
        return 1
    fi

    local attempt=1

    while [[ "${attempt}" -le "${attempts}" ]]; do

        if "$@"; then
            return 0
        fi

        if [[ "${attempt}" -lt "${attempts}" ]]; then
            log_debug \
                "Command failed. Retrying (${attempt}/${attempts})..."

            sleep "${delay}"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

###############################################################################
# Temporary file helpers
###############################################################################

create_empty_file()
{
    local file="$1"

    ensure_directory "$(dirname "${file}")" || return 1

    : > "${file}"
}

###############################################################################
# Framework information
###############################################################################

common_version()
{
    echo "1.0"
}
