#!/usr/bin/env bash
# HashiCorp Vault KMIP engine scenarios for pg_tde.
#
# Parity with pytest: tests/test_vault_kmip.py
#
# Known issue: Register symmetric key may return -2 on some builds.
# Set VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1 to fail hard after a fix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hashicorp_vault_common.sh
source "${SCRIPT_DIR}/../hashicorp_vault_common.sh"

KMIP_GLOBAL_PROVIDER="${VAULT_KMIP_TEST_PROVIDER_NAME:-kmip-provider-1}"
KMIP_GLOBAL_KEY="${VAULT_KMIP_TEST_KEY_NAME:-kmip-key-12012025}"
KMIP_DB_PROVIDER="${VAULT_KMIP_DB_PROVIDER_NAME:-kmip_provider2}"
KMIP_DB_KEY="${VAULT_KMIP_DB_KEY_NAME:-kmip-key-db}"

hc_kmip_is_register_minus_two() {
    grep -qi 'register symmetric key.*-2' <<<"$1"
}

hc_kmip_scenario_1_add_providers() {
    hc_vault_hr
    hc_vault_say "KMIP scenario 1: add global + database KMIP providers"
    hc_vault_add_global_kmip "${KMIP_GLOBAL_PROVIDER}"
    hc_vault_add_db_kmip "${KMIP_DB_PROVIDER}" postgres
    if hc_vault_psql -d postgres -t -A -c \
        "SELECT name FROM pg_tde_list_all_global_key_providers();" \
        | grep -qx "${KMIP_GLOBAL_PROVIDER}"; then
        hc_vault_pass "global provider ${KMIP_GLOBAL_PROVIDER} registered"
    else
        hc_vault_fail "global provider ${KMIP_GLOBAL_PROVIDER} not listed"
    fi
    if hc_vault_psql -d postgres -t -A -c \
        "SELECT name FROM pg_tde_list_all_database_key_providers();" \
        | grep -qx "${KMIP_DB_PROVIDER}"; then
        hc_vault_pass "database provider ${KMIP_DB_PROVIDER} registered"
    else
        hc_vault_fail "database provider ${KMIP_DB_PROVIDER} not listed"
    fi
}

hc_kmip_scenario_2_create_key_global() {
    hc_vault_hr
    hc_vault_say "KMIP scenario 2: create_key via global provider (customer repro)"
    local sql err rc=0
    sql="SELECT pg_tde_create_key_using_global_key_provider('${KMIP_GLOBAL_KEY}','${KMIP_GLOBAL_PROVIDER}');"
    err="$(hc_vault_psql -d postgres -c "${sql}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        hc_vault_pass "global create_key succeeded"
        hc_vault_psql -d postgres -c \
            "SELECT pg_tde_set_key_using_global_key_provider('${KMIP_GLOBAL_KEY}','${KMIP_GLOBAL_PROVIDER}');"
        hc_vault_psql -d postgres -c \
            "CREATE TABLE vault_kmip_g(id INT) USING tde_heap; INSERT INTO vault_kmip_g VALUES (1);"
        hc_vault_restart_pg
        hc_vault_assert_row postgres "SELECT id FROM vault_kmip_g" "1"
        return 0
    fi
    if hc_kmip_is_register_minus_two "${err}"; then
        if [[ "${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}" == "1" ]]; then
            hc_vault_fail "Register -2 still present but VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1"
            return 1
        fi
        hc_vault_xfail "Register symmetric key -2 (known Vault KMIP issue): ${err}"
        return 0
    fi
    hc_vault_fail "unexpected create_key error: ${err}"
    return 1
}

hc_kmip_scenario_3_create_key_database() {
    hc_vault_hr
    hc_vault_say "KMIP scenario 3: create_key via database provider (your SQL pattern)"
    local sql err rc=0
    sql="SELECT pg_tde_create_key_using_database_key_provider('${KMIP_DB_KEY}','${KMIP_DB_PROVIDER}');"
    err="$(hc_vault_psql -d postgres -c "${sql}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        hc_vault_pass "database create_key succeeded"
        hc_vault_psql -d postgres -c \
            "SELECT pg_tde_set_key_using_database_key_provider('${KMIP_DB_KEY}','${KMIP_DB_PROVIDER}');"
        hc_vault_psql -d postgres -c \
            "CREATE TABLE vault_kmip_d(id INT) USING tde_heap; INSERT INTO vault_kmip_d VALUES (2);"
        hc_vault_restart_pg
        hc_vault_assert_row postgres "SELECT id FROM vault_kmip_d" "2"
        return 0
    fi
    if hc_kmip_is_register_minus_two "${err}"; then
        if [[ "${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}" == "1" ]]; then
            hc_vault_fail "Register -2 on database provider"
            return 1
        fi
        hc_vault_xfail "database Register -2 (known): ${err}"
        return 0
    fi
    hc_vault_fail "unexpected database create_key error: ${err}"
    return 1
}

hc_kmip_scenario_4_verify_key() {
    hc_vault_hr
    hc_vault_say "KMIP scenario 4: pg_tde_verify_key when principal key is set"
    local principal
    principal="$(hc_vault_psql -d postgres -t -A -c "SELECT pg_tde_key_info();" 2>/dev/null | head -1 || true)"
    if [[ -z "${principal}" || "${principal}" == *"not configured"* ]]; then
        hc_vault_xfail "no principal key set (create_key may have xfailed)"
        return 0
    fi
    hc_vault_psql -d postgres -c "SELECT pg_tde_verify_key();" >/dev/null
    hc_vault_pass "pg_tde_verify_key OK"
}

hc_vault_run_kmip_scenarios() {
    hc_vault_check_kmip_files
    hc_vault_check_kmip_tcp
    hc_kmip_scenario_1_add_providers
    hc_kmip_scenario_2_create_key_global
    hc_kmip_scenario_3_create_key_database
    hc_kmip_scenario_4_verify_key
}

hc_vault_run_kmip_scenarios
