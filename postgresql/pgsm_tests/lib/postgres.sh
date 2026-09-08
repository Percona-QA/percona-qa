#!/bin/bash

###############################################################################
# PGSM Test Framework
#
# PostgreSQL lifecycle and SQL execution helpers.
#
###############################################################################

###############################################################################
# Resolve PostgreSQL binaries
###############################################################################

if [[ -n "${PGSM_PG_BIN_DIR:-}" ]]; then
    PG_CTL="${PGSM_PG_BIN_DIR}/pg_ctl"
    INITDB="${PGSM_PG_BIN_DIR}/initdb"
    PSQL="${PGSM_PG_BIN_DIR}/psql"
else
    PG_CTL="$(command -v pg_ctl || true)"
    INITDB="$(command -v initdb || true)"
    PSQL="$(command -v psql || true)"
fi


###############################################################################
# Internal helpers
###############################################################################

postgres_check_binaries()
{
    if [[ -z "${PG_CTL}" || ! -x "${PG_CTL}" ]]; then
        log_error "pg_ctl not found"
        return 1
    fi

    if [[ -z "${INITDB}" || ! -x "${INITDB}" ]]; then
        log_error "initdb not found"
        return 1
    fi

    if [[ -z "${PSQL}" || ! -x "${PSQL}" ]]; then
        log_error "psql not found"
        return 1
    fi

    return 0
}


postgres_connection_options()
{
    echo \
        "-h ${PGSM_PGHOST} " \
        "-p ${PGSM_PGPORT} " \
        "-U ${PGSM_TEST_USER}"
}


###############################################################################
# Initialize PostgreSQL cluster
###############################################################################

postgres_init()
{
    log_info "Initializing PostgreSQL test cluster..."

    postgres_check_binaries || return 1

    #
    # If a previous cluster exists, do not silently reuse it.
    # The test framework should always start from a clean environment.
    #
    if [[ -d "${PGSM_PGDATA}" ]]; then
        log_debug "Removing existing PostgreSQL data directory: ${PGSM_PGDATA}"

        rm -rf "${PGSM_PGDATA}" || {
            log_error "Unable to remove ${PGSM_PGDATA}"
            return 1
        }
    fi

    if [[ -d "${PGSM_SOCKET_DIR}" ]]; then
        rm -rf "${PGSM_SOCKET_DIR}" || {
            log_error "Unable to remove ${PGSM_SOCKET_DIR}"
            return 1
        }
    fi

    mkdir -p "${PGSM_RUNTIME_DIR}" || {
        log_error "Unable to create runtime directory: ${PGSM_RUNTIME_DIR}"
        return 1
    }

    mkdir -p "${PGSM_SOCKET_DIR}" || {
        log_error "Unable to create socket directory: ${PGSM_SOCKET_DIR}"
        return 1
    }

    #
    # Initialize PostgreSQL.
    #
    if [[ -n "${PGSM_INITDB_LOCALE}" ]]; then

        "${INITDB}" \
            --encoding="${PGSM_INITDB_ENCODING}" \
            --locale="${PGSM_INITDB_LOCALE}" \
            "${PGSM_PGDATA}" || {
                log_error "PostgreSQL initdb failed"
                return 1
            }

    else

        "${INITDB}" \
            --no-locale \
            --encoding="${PGSM_INITDB_ENCODING}" \
            "${PGSM_PGDATA}" || {
                log_error "PostgreSQL initdb failed"
                return 1
            }

    fi

    postgres_configure || {
        log_error "PostgreSQL configuration failed"
        return 1
    }

    log_info "PostgreSQL test cluster initialized"

    return 0
}


###############################################################################
# Configure PostgreSQL
###############################################################################

postgres_configure()
{
    log_debug "Configuring PostgreSQL"

    local config_file="${PGSM_PGDATA}/postgresql.conf"

    if [[ ! -f "${config_file}" ]]; then
        log_error "PostgreSQL configuration file not found: ${config_file}"
        return 1
    fi

    #
    # Add framework-specific settings.
    #
    cat >> "${config_file}" <<EOF

# ---------------------------------------------------------------------------
# PGSM Test Framework Configuration
# ---------------------------------------------------------------------------

port = ${PGSM_PGPORT}
listen_addresses = '${PGSM_LISTEN_ADDRESSES}'

unix_socket_directories = '${PGSM_SOCKET_DIR}'

shared_preload_libraries = '${PGSM_SHARED_PRELOAD_LIBRARIES}'

logging_collector = off
log_min_messages = '${PGSM_LOG_MIN_MESSAGES}'

EOF

    #
    # Configure pg_hba.conf to allow the test framework to connect without
    # requiring a password.
    #
    #
    # This cluster exists only for automated testing and listens only on
    # localhost.
    #
    cat >> "${PGSM_PGDATA}/pg_hba.conf" <<EOF

# PGSM Test Framework
host    all    all    127.0.0.1/32    trust
host    all    all    ::1/128         trust

EOF

    return 0
}


###############################################################################
# Start PostgreSQL
###############################################################################

postgres_start()
{
    log_info "Starting PostgreSQL..."

    postgres_check_binaries || return 1

    if postgres_is_running; then
        log_info "PostgreSQL is already running"
        return 0
    fi

    if [[ ! -d "${PGSM_PGDATA}" ]]; then
        log_error "PostgreSQL data directory does not exist: ${PGSM_PGDATA}"
        return 1
    fi

    #
    # Start PostgreSQL and wait until it is ready.
    #
    "${PG_CTL}" \
        -D "${PGSM_PGDATA}" \
        -l "${PGSM_PGLOG}" \
        -w \
        start || {
            log_error "Failed to start PostgreSQL"
            return 1
        }

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running after startup"
        return 1
    fi

    log_info "PostgreSQL started successfully"

    return 0
}


###############################################################################
# Stop PostgreSQL
###############################################################################

postgres_stop()
{
    log_info "Stopping PostgreSQL..."

    postgres_check_binaries || return 1

    if ! postgres_is_running; then
        log_debug "PostgreSQL is not running"
        return 0
    fi

    "${PG_CTL}" \
        -D "${PGSM_PGDATA}" \
        -m fast \
        -w \
        stop || {
            log_error "Failed to stop PostgreSQL"
            return 1
        }

    if postgres_is_running; then
        log_error "PostgreSQL is still running after shutdown"
        return 1
    fi

    log_info "PostgreSQL stopped successfully"

    return 0
}


###############################################################################
# Restart PostgreSQL
###############################################################################

postgres_restart()
{
    log_info "Restarting PostgreSQL..."

    postgres_stop || return 1
    postgres_start || return 1

    log_info "PostgreSQL restarted successfully"

    return 0
}


###############################################################################
# Reload PostgreSQL configuration
###############################################################################

postgres_reload()
{
    log_info "Reloading PostgreSQL configuration..."

    postgres_check_binaries || return 1

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    "${PG_CTL}" \
        -D "${PGSM_PGDATA}" \
        reload || {
            log_error "PostgreSQL configuration reload failed"
            return 1
        }

    log_debug "PostgreSQL configuration reloaded"

    return 0
}


###############################################################################
# Check whether PostgreSQL is running
###############################################################################

postgres_is_running()
{
    postgres_check_binaries >/dev/null 2>&1 || return 1

    "${PG_CTL}" \
        -D "${PGSM_PGDATA}" \
        status >/dev/null 2>&1
}


###############################################################################
# Get PostgreSQL version
###############################################################################

postgres_version()
{
    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    execute_sql \
        "SELECT version();" \
        "${PGSM_TEST_DB}" \
        2>/dev/null
}


###############################################################################
# Create database
###############################################################################

postgres_create_database()
{
    local database_name="${1:-}"

    if [[ -z "${database_name}" ]]; then
        log_error "postgres_create_database requires a database name"
        return 1
    fi

    #
    # Database names passed to this helper are identifiers, not arbitrary SQL.
    # Restrict them to safe PostgreSQL identifier characters.
    #
    if [[ ! "${database_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid database name: ${database_name}"
        return 1
    fi

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    #
    # Check whether database already exists.
    #
    local exists

    exists="$(
        execute_sql \
            "SELECT 1 FROM pg_database WHERE datname = '${database_name}';" \
            "${PGSM_TEST_DB}"
    )"

    if [[ "${exists}" == "1" ]]; then
        log_debug "Database already exists: ${database_name}"
        return 0
    fi

    log_debug "Creating database: ${database_name}"

    execute_sql \
        "CREATE DATABASE ${database_name};" \
        "${PGSM_TEST_DB}" >/dev/null || {
            log_error "Failed to create database: ${database_name}"
            return 1
        }

    log_debug "Database created: ${database_name}"

    return 0
}


###############################################################################
# Drop database
###############################################################################

postgres_drop_database()
{
    local database_name="${1:-}"

    if [[ -z "${database_name}" ]]; then
        log_error "postgres_drop_database requires a database name"
        return 1
    fi

    if [[ ! "${database_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid database name: ${database_name}"
        return 1
    fi

    if [[ "${database_name}" == "${PGSM_TEST_DB}" ]]; then
        log_error "Refusing to drop default test database: ${PGSM_TEST_DB}"
        return 1
    fi

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    #
    # DROP DATABASE ... WITH (FORCE) is supported by modern PostgreSQL
    # versions and makes cleanup much more reliable.
    #
    execute_sql \
        "DROP DATABASE IF EXISTS ${database_name} WITH (FORCE);" \
        "${PGSM_TEST_DB}" >/dev/null || {
            log_error "Failed to drop database: ${database_name}"
            return 1
        }

    log_debug "Database dropped: ${database_name}"

    return 0
}


###############################################################################
# Execute SQL
###############################################################################

execute_sql()
{
    local sql="${1:-}"
    local database="${2:-${PGSM_TEST_DB}}"

    if [[ -z "${sql}" ]]; then
        log_error "execute_sql requires SQL"
        return 1
    fi

    if [[ -z "${database}" ]]; then
        log_error "Database name cannot be empty"
        return 1
    fi

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    log_debug "Executing SQL on database '${database}': ${sql}"

    "${PSQL}" \
        -X \
        -h "${PGSM_PGHOST}" \
        -p "${PGSM_PGPORT}" \
        -U "${PGSM_TEST_USER}" \
        -d "${database}" \
        -v ON_ERROR_STOP=1 \
        -At \
        -c "${sql}"
}


###############################################################################
# Execute SQL file
###############################################################################

execute_sql_file()
{
    local sql_file="${1:-}"
    local database="${2:-${PGSM_TEST_DB}}"

    if [[ -z "${sql_file}" ]]; then
        log_error "execute_sql_file requires a SQL file"
        return 1
    fi

    if [[ ! -f "${sql_file}" ]]; then
        log_error "SQL file not found: ${sql_file}"
        return 1
    fi

    if ! postgres_is_running; then
        log_error "PostgreSQL is not running"
        return 1
    fi

    log_debug "Executing SQL file '${sql_file}' on database '${database}'"

    "${PSQL}" \
        -X \
        -h "${PGSM_PGHOST}" \
        -p "${PGSM_PGPORT}" \
        -U "${PGSM_TEST_USER}" \
        -d "${database}" \
        -v ON_ERROR_STOP=1 \
        -f "${sql_file}"
}
