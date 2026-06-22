#!/usr/bin/env bash
# HashiCorp Vault KV v2 scenarios for pg_tde (namespaced Enterprise setup).
#
# Parity with pytest:
#   tests/test_vault_providers.py
#   tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression
#   automation/tests/pg_tde_hashicorp_vault_mount_permission_warning_test.sh (scenario 10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hashicorp_vault_common.sh
source "${SCRIPT_DIR}/../hashicorp_vault_common.sh"

KEYFILE_MULTI="${RUN_DIR}/keyring_multi.file"
KEYFILE_DEL="${RUN_DIR}/keyring_del.file"
KEYFILE_DEFAULT="${RUN_DIR}/keyring_default.file"

hc_vault_scenario_1_global_smoke() {
    hc_vault_hr
    hc_vault_say "Scenario 1: global Vault provider, encrypted table, restart"
    hc_vault_add_global_vault_v2 "vault_smoke_ring"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('vault_smoke_key','vault_smoke_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('vault_smoke_key','vault_smoke_ring');"
    hc_vault_psql -d postgres -c \
        "CREATE TABLE vault_t1(id INT) USING tde_heap; INSERT INTO vault_t1 SELECT generate_series(1,150);"
    hc_vault_restart_pg
    hc_vault_assert_row postgres "SELECT COUNT(*) FROM vault_t1" "150"
}

hc_vault_scenario_2_key_rotation() {
    hc_vault_hr
    hc_vault_say "Scenario 2: principal key rotation"
    hc_vault_add_global_vault_v2 "vault_rot_ring"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('vault_rot_a','vault_rot_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('vault_rot_a','vault_rot_ring');"
    hc_vault_psql -d postgres -c \
        "CREATE TABLE vault_rot_t(id INT) USING tde_heap; INSERT INTO vault_rot_t VALUES (1);"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('vault_rot_b','vault_rot_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('vault_rot_b','vault_rot_ring');"
    hc_vault_restart_pg
    hc_vault_assert_row postgres "SELECT COUNT(*) FROM vault_rot_t" "1"
}

hc_vault_scenario_3_multi_db_vault_and_file() {
    hc_vault_hr
    hc_vault_say "Scenario 3: multi-database — db1 Vault, db3 file"
    rm -f "${KEYFILE_MULTI}"
    hc_vault_add_global_vault_v2 "vault_keyring2"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_add_global_key_provider_file('file_keyring2','${KEYFILE_MULTI}');"
    for db in db1 db3; do
        hc_vault_psql -d postgres -c "DROP DATABASE IF EXISTS ${db};"
        hc_vault_psql -d postgres -c "CREATE DATABASE ${db};"
        hc_vault_enable_extension "${db}"
    done
    hc_vault_psql -d db1 -c \
        "SELECT pg_tde_create_key_using_global_key_provider('vault_key2','vault_keyring2');"
    hc_vault_psql -d db1 -c \
        "SELECT pg_tde_set_key_using_global_key_provider('vault_key2','vault_keyring2');"
    hc_vault_psql -d db3 -c \
        "SELECT pg_tde_create_key_using_global_key_provider('file_key2','file_keyring2');"
    hc_vault_psql -d db3 -c \
        "SELECT pg_tde_set_key_using_global_key_provider('file_key2','file_keyring2');"
    hc_vault_psql -d db1 -c "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (100);"
    hc_vault_psql -d db3 -c "CREATE TABLE t3(a INT) USING tde_heap; INSERT INTO t3 VALUES (300);"
    hc_vault_restart_pg
    hc_vault_assert_row db1 "SELECT a FROM t1" "100"
    hc_vault_assert_row db3 "SELECT a FROM t3" "300"
}

hc_vault_scenario_4_database_scoped_provider() {
    hc_vault_hr
    hc_vault_say "Scenario 4: database-scoped Vault provider (sbtest2)"
    hc_vault_psql -d postgres -c "DROP DATABASE IF EXISTS sbtest2;"
    hc_vault_psql -d postgres -c "CREATE DATABASE sbtest2;"
    hc_vault_enable_extension sbtest2
    hc_vault_add_db_vault_v2 "vault_keyring4" sbtest2
    hc_vault_psql -d sbtest2 -c \
        "SELECT pg_tde_create_key_using_database_key_provider('vault_key4','vault_keyring4');"
    hc_vault_psql -d sbtest2 -c \
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key4','vault_keyring4');"
    hc_vault_psql -d sbtest2 -c \
        "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (42);"
    hc_vault_restart_pg
    hc_vault_assert_row sbtest2 "SELECT a FROM t1" "42"
}

hc_vault_scenario_5_delete_unused_global() {
    hc_vault_hr
    hc_vault_say "Scenario 5: delete unused global Vault provider"
    rm -f "${KEYFILE_DEL}"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_add_global_key_provider_file('file_ring','${KEYFILE_DEL}');"
    hc_vault_add_global_vault_v2 "vault_keyring3"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('file_key','file_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('file_key','file_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_delete_global_key_provider('vault_keyring3');"
    if hc_vault_psql -d postgres -t -A -c \
        "SELECT name FROM pg_tde_list_all_global_key_providers();" \
        | grep -qx 'vault_keyring3'; then
        hc_vault_fail "vault_keyring3 still listed after delete"
    else
        hc_vault_pass "unused vault_keyring3 deleted"
    fi
}

hc_vault_scenario_6_delete_in_use_fails() {
    hc_vault_hr
    hc_vault_say "Scenario 6: delete in-use Vault provider must fail"
    hc_vault_add_global_vault_v2 "vault_in_use"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('vault_active','vault_in_use');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('vault_active','vault_in_use');"
    hc_vault_psql -d postgres -c \
        "CREATE TABLE vdel(id INT) USING tde_heap; INSERT INTO vdel VALUES (1);"
    if hc_vault_psql_expect_fail postgres \
        "SELECT pg_tde_delete_global_key_provider('vault_in_use');"; then
        hc_vault_pass "delete in-use provider rejected"
    else
        hc_vault_fail "delete in-use provider unexpectedly succeeded"
    fi
}

hc_vault_scenario_7_namespace_db_scoped() {
    hc_vault_hr
    hc_vault_say "Scenario 7: namespaced DB-scoped provider (ns1/pg_tde)"
    if [[ -z "${VAULT_NAMESPACE:-}" ]]; then
        hc_vault_xfail "VAULT_NAMESPACE not set — skip namespace scenario"
        return 0
    fi
    hc_vault_psql -d postgres -c "DROP DATABASE IF EXISTS db1;"
    hc_vault_psql -d postgres -c "CREATE DATABASE db1;"
    hc_vault_enable_extension db1
    hc_vault_add_db_vault_v2 "vault_keyring" db1
    hc_vault_psql -d db1 -c \
        "SELECT pg_tde_create_key_using_database_key_provider('vault_key1','vault_keyring');"
    hc_vault_psql -d db1 -c \
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key1','vault_keyring');"
    hc_vault_psql -d db1 -c \
        "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (1);"
    hc_vault_restart_pg
    hc_vault_assert_row db1 "SELECT a FROM t1" "1"
}

hc_vault_scenario_8_namespace_default_key() {
    hc_vault_hr
    hc_vault_say "Scenario 8: namespaced DB key + file default principal"
    if [[ -z "${VAULT_NAMESPACE:-}" ]]; then
        hc_vault_xfail "VAULT_NAMESPACE not set — skip"
        return 0
    fi
    rm -f "${KEYFILE_DEFAULT}"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_add_global_key_provider_file('file_keyring3','${KEYFILE_DEFAULT}');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('file_key3','file_keyring3');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_default_key_using_global_key_provider('file_key3','file_keyring3');"
    for db in test1 test2; do
        hc_vault_psql -d postgres -c "DROP DATABASE IF EXISTS ${db};"
        hc_vault_psql -d postgres -c "CREATE DATABASE ${db};"
        hc_vault_enable_extension "${db}"
    done
    hc_vault_add_db_vault_v2 "vault_keyring3" test1
    hc_vault_psql -d test1 -c \
        "SELECT pg_tde_create_key_using_database_key_provider('vault_key3','vault_keyring3');"
    hc_vault_psql -d test1 -c \
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key3','vault_keyring3');"
    hc_vault_psql -d test1 -c \
        "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (100);"
    hc_vault_psql -d test2 -c \
        "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (1);"
    hc_vault_restart_pg
    hc_vault_assert_row test1 "SELECT a FROM t1" "100"
    hc_vault_assert_row test2 "SELECT a FROM t1" "1"
}

hc_vault_scenario_9_namespace_roundtrip() {
    hc_vault_hr
    hc_vault_say "Scenario 9: PG-1959 namespace provider roundtrip after restart"
    if [[ -z "${VAULT_NAMESPACE:-}" ]]; then
        hc_vault_xfail "VAULT_NAMESPACE not set — skip"
        return 0
    fi
    hc_vault_add_global_vault_v2 "ns_roundtrip_ring"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_global_key_provider('ns_roundtrip_key','ns_roundtrip_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_global_key_provider('ns_roundtrip_key','ns_roundtrip_ring');"
    hc_vault_psql -d postgres -c \
        "CREATE TABLE ns_rt(id INT) USING tde_heap; INSERT INTO ns_rt VALUES (7),(8);"
    hc_vault_restart_pg
    hc_vault_assert_row postgres "SELECT COUNT(*) FROM ns_rt" "2"
    hc_vault_psql -d postgres -c "SELECT pg_tde_verify_key();" >/dev/null
    hc_vault_pass "pg_tde_verify_key after restart"
}

hc_vault_scenario_10_kv_only_token() {
    hc_vault_hr
    hc_vault_say "Scenario 10: KV-only token without mount metadata (PG-1959)"
    if [[ -z "${VAULT_ROOT_TOKEN:-}" ]]; then
        hc_vault_xfail "set VAULT_ROOT_TOKEN to create kv-only policy token"
        return 0
    fi
    hc_vault_require_cmd jq
    VAULT_BIN="${VAULT_BIN:-vault}"
    hc_vault_require_cmd "${VAULT_BIN}"
    local policy="${RUN_DIR}/policy_kv_only.hcl"
    local token_file="${RUN_DIR}/token_kv_only"
    cat > "${policy}" <<EOF
path "${VAULT_SECRET_MOUNT}/data/*" {
  capabilities = ["create", "read"]
}
path "${VAULT_SECRET_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
path "sys/internal/ui/mounts/*" { capabilities = [] }
path "sys/mounts/*" { capabilities = [] }
EOF
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
        VAULT_NAMESPACE="${VAULT_NAMESPACE%/}" \
        "${VAULT_BIN}" policy write kv_only_pg_tde "${policy}"
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
        VAULT_NAMESPACE="${VAULT_NAMESPACE%/}" \
        "${VAULT_BIN}" token create -policy=kv_only_pg_tde -no-default-policy -format=json \
        | jq -r .auth.client_token > "${token_file}"

    local saved_token="${VAULT_TOKEN_FILE}"
    VAULT_TOKEN_FILE="${token_file}"
    hc_vault_add_db_vault_v2 "vault_kvonly_ring" postgres
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_create_key_using_database_key_provider('vault_kvonly_key','vault_kvonly_ring');"
    hc_vault_psql -d postgres -c \
        "SELECT pg_tde_set_key_using_database_key_provider('vault_kvonly_key','vault_kvonly_ring');"
    hc_vault_psql -d postgres -c \
        "CREATE TABLE hc_kv_t(a INT) USING tde_heap; INSERT INTO hc_kv_t VALUES (100),(200);"
    hc_vault_restart_pg
    hc_vault_assert_row postgres "SELECT COUNT(*) FROM hc_kv_t" "2"
    VAULT_TOKEN_FILE="${saved_token}"
}

hc_vault_run_kv_scenarios() {
    hc_vault_scenario_1_global_smoke
    hc_vault_scenario_2_key_rotation
    hc_vault_scenario_3_multi_db_vault_and_file
    hc_vault_scenario_4_database_scoped_provider
    hc_vault_scenario_5_delete_unused_global
    hc_vault_scenario_6_delete_in_use_fails
    hc_vault_scenario_7_namespace_db_scoped
    hc_vault_scenario_8_namespace_default_key
    hc_vault_scenario_9_namespace_roundtrip
    hc_vault_scenario_10_kv_only_token
}

hc_vault_run_kv_scenarios
