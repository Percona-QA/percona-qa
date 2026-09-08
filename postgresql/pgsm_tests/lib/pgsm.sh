#!/bin/bash

###############################################################################
# PGSM Test Framework
#
# pg_stat_monitor specific helpers.
#
###############################################################################

###############################################################################
# Internal helpers
###############################################################################

pgsm_validate_guc_name()
{
    local guc_name="${1:-}"

    if [[ -z "${guc_name}" ]]; then
        log_error "GUC name cannot be empty"
        return 1
    fi

    #
    # PGSM GUC names are identifiers. Restrict the input to avoid accidentally
    # constructing invalid SQL.
    #
    if [[ ! "${guc_name}" =~ ^pg_stat_monitor\.[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid PGSM GUC name: ${guc_name}"
        return 1
    fi

    return 0
}


###############################################################################
# Check whether pg_stat_monitor is available
###############################################################################

pgsm_is_available()
{
    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    local result

    result="$(
        execute_sql \
            "SELECT 1
               FROM pg_available_extensions
              WHERE name = 'pg_stat_monitor';"
    )" || {
        log_error "Unable to query pg_available_extensions"
        return 1
    }

    [[ "${result}" == "1" ]]
}


###############################################################################
# Check whether pg_stat_monitor is loaded
#
# This verifies shared_preload_libraries.
###############################################################################

pgsm_is_loaded()
{
    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    local result

    result="$(
        execute_sql \
            "SELECT 1
               FROM pg_settings
              WHERE name = 'shared_preload_libraries'
                AND pg_stat_monitor = ANY(string_to_array(setting, ','));"
    )" 2>/dev/null || true

    #
    # The above query is intentionally kept simple below by using a more
    # reliable regexp check against the actual setting.
    #
    local libraries

    libraries="$(
        execute_sql \
            "SHOW shared_preload_libraries;"
    )" || {
        log_error "Unable to read shared_preload_libraries"
        return 1
    }

    if [[ ",${libraries}," == *",pg_stat_monitor,"* ]]; then
        return 0
    fi

    log_error "pg_stat_monitor is not present in shared_preload_libraries"

    return 1
}


###############################################################################
# Check whether pg_stat_monitor extension exists in current database
###############################################################################

pgsm_extension_exists()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    local result

    result="$(
        execute_sql \
            "SELECT 1
               FROM pg_extension
              WHERE extname = 'pg_stat_monitor';" \
            "${database}"
    )" || {
        log_error "Unable to query pg_extension"
        return 1
    }

    [[ "${result}" == "1" ]]
}


###############################################################################
# Create pg_stat_monitor extension
###############################################################################

pgsm_create_extension()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    if ! pgsm_is_available; then
        log_error "pg_stat_monitor extension is not available"
        return 1
    fi

    if pgsm_extension_exists "${database}"; then
        log_debug "pg_stat_monitor extension already exists in database '${database}'"
        return 0
    fi

    log_info "Creating pg_stat_monitor extension in database '${database}'"

    execute_sql \
        "CREATE EXTENSION pg_stat_monitor;" \
        "${database}" >/dev/null || {
            log_error "Failed to create pg_stat_monitor extension"
            return 1
        }

    if ! pgsm_extension_exists "${database}"; then
        log_error "pg_stat_monitor extension was not created successfully"
        return 1
    fi

    log_info "pg_stat_monitor extension created successfully"

    return 0
}


###############################################################################
# Drop pg_stat_monitor extension
###############################################################################

pgsm_drop_extension()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    if ! pgsm_extension_exists "${database}"; then
        log_debug "pg_stat_monitor extension does not exist in database '${database}'"
        return 0
    fi

    log_info "Dropping pg_stat_monitor extension from database '${database}'"

    execute_sql \
        "DROP EXTENSION pg_stat_monitor;" \
        "${database}" >/dev/null || {
            log_error "Failed to drop pg_stat_monitor extension"
            return 1
        }

    return 0
}


###############################################################################
# Get pg_stat_monitor version
###############################################################################

pgsm_version()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    if ! pgsm_extension_exists "${database}"; then
        log_error "pg_stat_monitor extension does not exist in database '${database}'"
        return 1
    fi

    execute_sql \
        "SELECT pg_stat_monitor_version();" \
        "${database}"
}


###############################################################################
# Get installed extension version from pg_extension
###############################################################################

pgsm_extension_version()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    execute_sql \
        "SELECT extversion
           FROM pg_extension
          WHERE extname = 'pg_stat_monitor';" \
        "${database}"
}


###############################################################################
# Reset pg_stat_monitor statistics
###############################################################################

pgsm_reset()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    if ! pgsm_extension_exists "${database}"; then
        log_error "pg_stat_monitor extension does not exist in database '${database}'"
        return 1
    fi

    log_debug "Resetting pg_stat_monitor statistics"

    execute_sql \
        "SELECT pg_stat_monitor_reset();" \
        "${database}" >/dev/null || {
            log_error "Failed to reset pg_stat_monitor statistics"
            return 1
        }

    return 0
}


###############################################################################
# Get a PGSM GUC value
###############################################################################

pgsm_get_guc()
{
    local guc_name="${1:-}"

    pgsm_validate_guc_name "${guc_name}" || return 1

    execute_sql \
        "SHOW ${guc_name};"
}


###############################################################################
# Set a PGSM GUC value
#
# Usage:
#   pgsm_set_guc pg_stat_monitor.pgsm_track all
#   pgsm_set_guc pg_stat_monitor.pgsm_normalized_query on
###############################################################################

pgsm_set_guc()
{
    local guc_name="${1:-}"
    local guc_value="${2:-}"

    pgsm_validate_guc_name "${guc_name}" || return 1

    if [[ -z "${guc_value}" ]]; then
        log_error "GUC value cannot be empty"
        return 1
    fi

    log_debug "Setting ${guc_name}=${guc_value}"

    execute_sql \
        "SET ${guc_name} = '${guc_value}';" >/dev/null || {
            log_error "Failed to set ${guc_name}=${guc_value}"
            return 1
        }

    return 0
}


###############################################################################
# Reset a PGSM GUC to its default value
###############################################################################

pgsm_reset_guc()
{
    local guc_name="${1:-}"

    pgsm_validate_guc_name "${guc_name}" || return 1

    log_debug "Resetting GUC ${guc_name}"

    execute_sql \
        "RESET ${guc_name};" >/dev/null || {
            log_error "Failed to reset GUC ${guc_name}"
            return 1
        }

    return 0
}


###############################################################################
# Set a PGSM GUC using ALTER SYSTEM
#
# This is useful for GUCs whose context is postmaster and therefore cannot
# be changed with SET.
#
# A PostgreSQL restart is required after ALTER SYSTEM for postmaster GUCs.
###############################################################################

pgsm_set_guc_system()
{
    local guc_name="${1:-}"
    local guc_value="${2:-}"

    pgsm_validate_guc_name "${guc_name}" || return 1

    if [[ -z "${guc_value}" ]]; then
        log_error "GUC value cannot be empty"
        return 1
    fi

    log_debug "Setting system GUC ${guc_name}=${guc_value}"

    execute_sql \
        "ALTER SYSTEM SET ${guc_name} = '${guc_value}';" >/dev/null || {
            log_error "Failed to ALTER SYSTEM ${guc_name}=${guc_value}"
            return 1
        }

    return 0
}


###############################################################################
# Reset a PGSM GUC using ALTER SYSTEM
###############################################################################

pgsm_reset_guc_system()
{
    local guc_name="${1:-}"

    pgsm_validate_guc_name "${guc_name}" || return 1

    log_debug "Resetting system GUC ${guc_name}"

    execute_sql \
        "ALTER SYSTEM RESET ${guc_name};" >/dev/null || {
            log_error "Failed to ALTER SYSTEM RESET ${guc_name}"
            return 1
        }

    return 0
}


###############################################################################
# Get all pg_stat_monitor GUCs
###############################################################################

pgsm_show_gucs()
{
    execute_sql \
        "SELECT name || '=' || setting
           FROM pg_settings
          WHERE name LIKE 'pg_stat_monitor.%'
          ORDER BY name;"
}


###############################################################################
# Check whether PGSM view exists
###############################################################################

pgsm_view_exists()
{
    local database="${1:-${PGSM_TEST_DB}}"

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    local result

    result="$(
        execute_sql \
            "SELECT 1
               FROM pg_class c
               JOIN pg_namespace n
                 ON n.oid = c.relnamespace
              WHERE n.nspname = 'public'
                AND c.relname = 'pg_stat_monitor'
                AND c.relkind IN ('r', 'v');" \
            "${database}"
    )" || {
        log_error "Unable to check pg_stat_monitor view"
        return 1
    }

    [[ "${result}" == "1" ]]
}


###############################################################################
# Query pg_stat_monitor
###############################################################################

pgsm_query()
{
    local sql="${1:-}"
    local database="${2:-${PGSM_TEST_DB}}"

    if [[ -z "${sql}" ]]; then
        log_error "pgsm_query requires SQL"
        return 1
    fi

    if ! pgsm_extension_exists "${database}"; then
        log_error "pg_stat_monitor extension does not exist in database '${database}'"
        return 1
    fi

    execute_sql "${sql}" "${database}"
}


###############################################################################
# Get number of rows currently present in pg_stat_monitor
###############################################################################

pgsm_entry_count()
{
    local database="${1:-${PGSM_TEST_DB}}"

    pgsm_query \
        "SELECT count(*) FROM pg_stat_monitor;" \
        "${database}"
}


###############################################################################
# Get calls for a specific query
#
# Usage:
#   pgsm_query_calls "SELECT 1"
#
# This helper is intentionally simple for the first iteration.
# More robust query matching can be added later.
###############################################################################

pgsm_query_calls()
{
    local query="${1:-}"
    local database="${2:-${PGSM_TEST_DB}}"

    if [[ -z "${query}" ]]; then
        log_error "pgsm_query_calls requires a query"
        return 1
    fi

    #
    # Escape single quotes before constructing SQL.
    #
    local escaped_query
    escaped_query="${query//\'/\'\'}"

    pgsm_query \
        "SELECT COALESCE(sum(calls), 0)
           FROM pg_stat_monitor
          WHERE query = '${escaped_query}';" \
        "${database}"
}


###############################################################################
# Verify pg_stat_monitor is operational
#
# This performs the checks needed during environment setup.
###############################################################################

pgsm_verify()
{
    local database="${1:-${PGSM_TEST_DB}}"

    log_info "Verifying pg_stat_monitor..."

    if ! pgsm_is_available; then
        log_error "pg_stat_monitor is not available"
        return 1
    fi

    log_debug "pg_stat_monitor is available"

    if ! pgsm_is_loaded; then
        log_error "pg_stat_monitor is not loaded"
        return 1
    fi

    log_debug "pg_stat_monitor is loaded"

    if ! pgsm_extension_exists "${database}"; then
        log_error "pg_stat_monitor extension does not exist"
        return 1
    fi

    log_debug "pg_stat_monitor extension exists"

    if ! pgsm_view_exists "${database}"; then
        log_error "pg_stat_monitor view does not exist"
        return 1
    fi

    log_debug "pg_stat_monitor view exists"

    local version

    version="$(pgsm_version "${database}")" || {
        log_error "Unable to determine pg_stat_monitor version"
        return 1
    }

    if [[ -z "${version}" ]]; then
        log_error "pg_stat_monitor version is empty"
        return 1
    fi

    log_info "pg_stat_monitor version: ${version}"

    return 0
}
