# Shared helpers for HashiCorp Vault pg_tde bash revalidation.
# shellcheck shell=bash
# Usage: source scripts/hashicorp_vault_common.sh

set -euo pipefail

HC_VAULT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC_VAULT_PYTEST_ROOT="$(cd "${HC_VAULT_SCRIPT_DIR}/.." && pwd)"

HC_VAULT_PASS_COUNT=0
HC_VAULT_FAIL_COUNT=0
HC_VAULT_XFAIL_COUNT=0

hc_vault_hr() {
    printf '\n══════════════════════════════════════════════════════════════\n'
}

hc_vault_say() {
    printf '[STEP] %s\n' "$*"
}

hc_vault_pass() {
    HC_VAULT_PASS_COUNT=$((HC_VAULT_PASS_COUNT + 1))
    printf '  [PASS] %s\n' "$*"
}

hc_vault_fail() {
    HC_VAULT_FAIL_COUNT=$((HC_VAULT_FAIL_COUNT + 1))
    printf '  [FAIL] %s\n' "$*" >&2
}

hc_vault_xfail() {
    HC_VAULT_XFAIL_COUNT=$((HC_VAULT_XFAIL_COUNT + 1))
    printf '  [XFAIL/KNOWN] %s\n' "$*"
}

hc_vault_require_cmd() {
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || {
        hc_vault_fail "required command not found: ${cmd}"
        exit 2
    }
}

hc_vault_sql_null_or_quote() {
    local val=${1:-}
    if [[ -z "${val}" ]]; then
        printf 'NULL'
    else
        printf "'%s'" "${val//\'/''}"
    fi
}

hc_vault_init_pg_tools() {
    if [[ -z "${INSTALL_DIR:-}" ]]; then
        hc_vault_fail "set INSTALL_DIR to a PostgreSQL install with pg_tde"
        exit 2
    fi
    PSQL="${INSTALL_DIR}/bin/psql"
    PG_CTL="${INSTALL_DIR}/bin/pg_ctl"
    INITDB="${INSTALL_DIR}/bin/initdb"
    PG_ISREADY="${INSTALL_DIR}/bin/pg_isready"
    for bin in "${PSQL}" "${PG_CTL}" "${INITDB}" "${PG_ISREADY}"; do
        [[ -x "${bin}" ]] || {
            hc_vault_fail "missing or not executable: ${bin}"
            exit 2
        }
    done
    export PSQL PG_CTL INITDB PG_ISREADY
}

hc_vault_psql() {
    # shellcheck disable=SC2068
    "${PSQL}" -p "${PORT}" -U "${PGUSER}" -v ON_ERROR_STOP=1 "$@"
}

hc_vault_psql_expect_fail() {
    local db=$1
    shift
    local sql=$1
    if hc_vault_psql -d "${db}" -c "${sql}" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

hc_vault_add_global_vault_v2() {
    local provider=$1
    local ca_sql ns_sql
    ca_sql="$(hc_vault_sql_null_or_quote "${VAULT_CA_PATH:-}")"
    ns_sql="$(hc_vault_sql_null_or_quote "${VAULT_NAMESPACE:-}")"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_add_global_key_provider_vault_v2(
            '${provider}', '${VAULT_ADDR}', '${VAULT_SECRET_MOUNT}',
            '${VAULT_TOKEN_FILE}', ${ca_sql}, ${ns_sql});"
}

hc_vault_add_db_vault_v2() {
    local provider=$1
    local db=$2
    local ca_sql ns_sql
    ca_sql="$(hc_vault_sql_null_or_quote "${VAULT_CA_PATH:-}")"
    ns_sql="$(hc_vault_sql_null_or_quote "${VAULT_NAMESPACE:-}")"
    hc_vault_psql -d "${db}" -c \
        "SELECT pg_tde_add_database_key_provider_vault_v2(
            '${provider}', '${VAULT_ADDR}', '${VAULT_SECRET_MOUNT}',
            '${VAULT_TOKEN_FILE}', ${ca_sql}, ${ns_sql});"
}

hc_vault_add_global_kmip() {
    local provider=$1
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_add_global_key_provider_kmip(
            '${provider}', '${KMIP_VAULT_HOST}', ${KMIP_VAULT_PORT},
            '${KMIP_VAULT_CLIENT_CERT}', '${KMIP_VAULT_CLIENT_KEY}',
            '${KMIP_VAULT_SERVER_CA}');"
}

hc_vault_add_db_kmip() {
    local provider=$1
    local db=$2
    hc_vault_psql -d "${db}" -c \
        "SELECT pg_tde_add_database_key_provider_kmip(
            '${provider}', '${KMIP_VAULT_HOST}', ${KMIP_VAULT_PORT},
            '${KMIP_VAULT_CLIENT_CERT}', '${KMIP_VAULT_CLIENT_KEY}',
            '${KMIP_VAULT_SERVER_CA}');"
}

hc_vault_check_vault_api() {
    hc_vault_say "Vault API health (${VAULT_ADDR})"
    hc_vault_require_cmd curl
    if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null; then
        hc_vault_pass "Vault health endpoint reachable"
    else
        hc_vault_fail "Vault health check failed at ${VAULT_ADDR}"
        return 1
    fi
    if [[ -n "${VAULT_BIN:-}" ]] && command -v "${VAULT_BIN}" >/dev/null 2>&1; then
        VAULT_ADDR="${VAULT_ADDR}" "${VAULT_BIN}" status >/dev/null && \
            hc_vault_pass "vault status OK" || hc_vault_fail "vault status failed"
    fi
    [[ -f "${VAULT_TOKEN_FILE}" ]] || {
        hc_vault_fail "token file missing: ${VAULT_TOKEN_FILE}"
        return 1
    }
    hc_vault_pass "token file present: ${VAULT_TOKEN_FILE}"
}

hc_vault_check_kmip_files() {
    local label path
    for label path in \
        "client cert" "${KMIP_VAULT_CLIENT_CERT}" \
        "client key" "${KMIP_VAULT_CLIENT_KEY}" \
        "server CA" "${KMIP_VAULT_SERVER_CA}"; do
        [[ -f "${path}" ]] || {
            hc_vault_fail "KMIP ${label} missing: ${path}"
            return 1
        }
    done
    hc_vault_pass "KMIP cert files present"
}

hc_vault_check_kmip_tcp() {
    hc_vault_say "KMIP TCP ${KMIP_VAULT_HOST}:${KMIP_VAULT_PORT}"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w3 "${KMIP_VAULT_HOST}" "${KMIP_VAULT_PORT}" && \
            hc_vault_pass "KMIP port reachable" || {
            hc_vault_fail "cannot connect to KMIP ${KMIP_VAULT_HOST}:${KMIP_VAULT_PORT}"
            return 1
        }
    else
        hc_vault_pass "nc not installed — skipping TCP probe"
    fi
}

hc_vault_stop_pg() {
    [[ "${HC_VAULT_USE_EXISTING_PG:-0}" == "1" ]] && return 0
    "${PG_CTL}" -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
}

hc_vault_start_pg() {
    [[ "${HC_VAULT_USE_EXISTING_PG:-0}" == "1" ]] && return 0
    mkdir -p "${PGDATA}"
    if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
        hc_vault_say "initdb ${PGDATA}"
        "${INITDB}" -D "${PGDATA}" --no-data-checksums >/dev/null
        cat >> "${PGDATA}/postgresql.conf" <<EOF
port = ${PORT}
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
listen_addresses = '127.0.0.1'
EOF
        echo "local all all trust" >> "${PGDATA}/pg_hba.conf"
        echo "host all all 127.0.0.1/32 trust" >> "${PGDATA}/pg_hba.conf"
    fi
    "${PG_CTL}" -D "${PGDATA}" -l "${PGDATA}/server.log" start >/dev/null
    "${PG_ISREADY}" -p "${PORT}" -U "${PGUSER}" -t 30 >/dev/null
}

hc_vault_restart_pg() {
    [[ "${HC_VAULT_USE_EXISTING_PG:-0}" == "1" ]] && return 0
    hc_vault_stop_pg
    hc_vault_start_pg
}

hc_vault_setup_pg() {
    hc_vault_init_pg_tools
    if [[ "${HC_VAULT_USE_EXISTING_PG:-0}" == "1" ]]; then
        hc_vault_say "Using existing PostgreSQL on port ${PORT}"
        "${PG_ISREADY}" -p "${PORT}" -U "${PGUSER}" -t 10 >/dev/null || {
            hc_vault_fail "existing PostgreSQL not ready on port ${PORT}"
            exit 2
        }
        hc_vault_pass "PostgreSQL ready (existing cluster)"
        return 0
    fi
    mkdir -p "${RUN_DIR}"
    hc_vault_stop_pg
    hc_vault_start_pg
    hc_vault_pass "PostgreSQL started (${PGDATA}, port ${PORT})"
}

hc_vault_enable_extension() {
    local db=${1:-postgres}
    hc_vault_psql -d "${db}" -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"
}

hc_vault_assert_row() {
    local db=$1 sql=$2 expected=$3
    local got
    got="$(hc_vault_psql -d "${db}" -t -A -c "${sql}" | tr -d '[:space:]')"
    if [[ "${got}" == "${expected}" ]]; then
        hc_vault_pass "${sql} => ${expected}"
    else
        hc_vault_fail "${sql} expected '${expected}', got '${got}'"
        return 1
    fi
}

hc_vault_print_summary() {
    hc_vault_hr
    printf 'Summary: %d passed, %d failed, %d known-issue (xfail)\n' \
        "${HC_VAULT_PASS_COUNT}" "${HC_VAULT_FAIL_COUNT}" "${HC_VAULT_XFAIL_COUNT}"
    if [[ "${HC_VAULT_FAIL_COUNT}" -gt 0 ]]; then
        return 1
    fi
    return 0
}
