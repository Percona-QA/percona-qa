#!/usr/bin/env bash
# Pytest only — HashiCorp Vault KV v2 + Vault KMIP engine (external lab server).
#
# Does NOT start Vault or run bash scenarios. Set env from your lab, then:
#
#   cd postgresql/pytest
#   source .env.sh
#   ./scripts/run_hashicorp_vault_pytest.sh
#
# Subsets:
#   HC_VAULT_PYTEST_SUITES=vault      ./scripts/run_hashicorp_vault_pytest.sh
#   HC_VAULT_PYTEST_SUITES=vault_kmip ./scripts/run_hashicorp_vault_pytest.sh
#   HC_VAULT_PYTEST_SUITES=all        ./scripts/run_hashicorp_vault_pytest.sh  # default
#
# Extra pytest args:
#   ./scripts/run_hashicorp_vault_pytest.sh -k smoke --maxfail=1
#
# Strict KMIP (fail on Register -2):
#   VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1 ./scripts/run_hashicorp_vault_pytest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

if [[ -f "${HC_VAULT_ENV_FILE:-}" ]]; then
    # shellcheck source=/dev/null
    source "${HC_VAULT_ENV_FILE}"
fi

# shellcheck source=hashicorp_vault_env.sh
source "${SCRIPT_DIR}/hashicorp_vault_env.sh"
hc_vault_apply_defaults

HC_VAULT_PYTEST_SUITES="${HC_VAULT_PYTEST_SUITES:-all}"

printf 'HashiCorp Vault pytest (manual / external server)\n'
printf '  docs: docs/vault.md, docs/vault_kmip.md\n'
printf '  VAULT_ADDR=%s\n' "${VAULT_ADDR}"
printf '  VAULT_SECRET_MOUNT=%s\n' "${VAULT_SECRET_MOUNT}"
printf '  VAULT_NAMESPACE=%s\n' "${VAULT_NAMESPACE}"
printf '  VAULT_TOKEN_FILE=%s\n' "${VAULT_TOKEN_FILE}"
printf '  KMIP=%s:%s\n' "${KMIP_VAULT_HOST}" "${KMIP_VAULT_PORT}"
printf '  INSTALL_DIR=%s\n' "${INSTALL_DIR:-<unset>}"
printf '  suites=%s\n\n' "${HC_VAULT_PYTEST_SUITES}"

if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "ERROR: set INSTALL_DIR (pg_tde PostgreSQL install)" >&2
    exit 2
fi

run_vault=false
run_vault_kmip=false
case "${HC_VAULT_PYTEST_SUITES}" in
    all)
        run_vault=true
        run_vault_kmip=true
        ;;
    vault)
        run_vault=true
        ;;
    vault_kmip|kmip)
        run_vault_kmip=true
        ;;
    *)
        echo "ERROR: HC_VAULT_PYTEST_SUITES must be all, vault, or vault_kmip" >&2
        exit 2
        ;;
esac

if [[ "${run_vault}" == true ]]; then
    if ! hc_vault_env_ready; then
        hc_vault_env_not_ready_message >&2
        exit 2
    fi
fi

if [[ "${run_vault_kmip}" == true ]]; then
    for f in "${KMIP_VAULT_CLIENT_CERT}" "${KMIP_VAULT_CLIENT_KEY}" "${KMIP_VAULT_SERVER_CA}"; do
        [[ -f "${f}" ]] || {
            echo "ERROR: KMIP cert missing: ${f}" >&2
            exit 2
        }
    done
fi

export VAULT_ADDR VAULT_SECRET_MOUNT VAULT_NAMESPACE VAULT_TOKEN_FILE VAULT_CA_PATH
export VAULT_KV_ONLY_TOKEN_FILE="${VAULT_KV_ONLY_TOKEN_FILE:-}"
export KMIP_VAULT_HOST KMIP_VAULT_PORT KMIP_VAULT_CLIENT_CERT KMIP_VAULT_CLIENT_KEY KMIP_VAULT_SERVER_CA
export VAULT_KMIP_REQUIRE_REGISTER_SUCCESS="${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}"
export VAULT_KMIP_TEST_PROVIDER_NAME="${VAULT_KMIP_TEST_PROVIDER_NAME:-kmip-provider-1}"
export VAULT_KMIP_TEST_KEY_NAME="${VAULT_KMIP_TEST_KEY_NAME:-kmip-key-12012025}"

PYTEST_TARGETS=()

if [[ "${run_vault}" == true ]]; then
    PYTEST_TARGETS+=(
        tests/test_vault_providers.py::TestHashicorpVaultKeyProvider
        tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression
    )
fi

if [[ "${run_vault_kmip}" == true ]]; then
    PYTEST_TARGETS+=(tests/test_vault_kmip.py)
fi

exec pytest "${PYTEST_TARGETS[@]}" -v "$@"
