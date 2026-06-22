#!/usr/bin/env bash
# Run full HashiCorp Vault Enterprise revalidation for pg_tde.
#
# Covers:
#   - Vault KV v2 with namespaces (ns1/pg_tde mount)
#   - Vault KMIP secrets engine (TCP 5696 + client certs)
#
# Usage on your testing system:
#   cd postgresql/pytest
#   cp scripts/config/hashicorp_vault.example.env /tmp/my_vault.env
#   # edit INSTALL_DIR, VAULT_TOKEN_FILE, KMIP cert paths, etc.
#   source /tmp/my_vault.env
#   ./scripts/run_hashicorp_vault_revalidation.sh
#
# Use existing PostgreSQL instead of ephemeral cluster:
#   export HC_VAULT_USE_EXISTING_PG=1
#   export PORT=5432
#
# Pytest equivalent (after sourcing the same env):
#   ./scripts/run_hashicorp_vault_revalidation.sh --pytest
#
# KV only or KMIP only:
#   HC_VAULT_SUITES=kv   ./scripts/run_hashicorp_vault_revalidation.sh
#   HC_VAULT_SUITES=kmip ./scripts/run_hashicorp_vault_revalidation.sh
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

# shellcheck source=hashicorp_vault_common.sh
source "${SCRIPT_DIR}/hashicorp_vault_common.sh"

RUN_PYTEST=0
PYTEST_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --pytest) RUN_PYTEST=1 ;;
        *) PYTEST_ARGS+=("${arg}") ;;
    esac
done

HC_VAULT_SUITES="${HC_VAULT_SUITES:-all}"

printf 'HashiCorp Vault pg_tde revalidation\n'
printf '  VAULT_ADDR=%s\n' "${VAULT_ADDR:-<unset>}"
printf '  VAULT_SECRET_MOUNT=%s\n' "${VAULT_SECRET_MOUNT:-<unset>}"
printf '  VAULT_NAMESPACE=%s\n' "${VAULT_NAMESPACE:-<unset>}"
printf '  VAULT_TOKEN_FILE=%s\n' "${VAULT_TOKEN_FILE:-<unset>}"
printf '  KMIP=%s:%s\n' "${KMIP_VAULT_HOST:-<unset>}" "${KMIP_VAULT_PORT:-5696}"
printf '  INSTALL_DIR=%s\n' "${INSTALL_DIR:-<unset>}"
printf '  suites=%s\n\n' "${HC_VAULT_SUITES}"

hc_vault_check_vault_api
hc_vault_setup_pg
hc_vault_enable_extension postgres

ver="$(hc_vault_psql -d postgres -t -A -c "SELECT pg_tde_version();" | head -1)"
hc_vault_pass "pg_tde_version: ${ver}"

run_kv=false
run_kmip=false
case "${HC_VAULT_SUITES}" in
    all)
        run_kv=true
        run_kmip=true
        ;;
    kv)
        run_kv=true
        ;;
    kmip)
        run_kmip=true
        ;;
    *)
        echo "ERROR: HC_VAULT_SUITES must be all, kv, or kmip" >&2
        exit 2
        ;;
esac

if [[ "${run_kv}" == true ]]; then
    hc_vault_hr
    printf '=== Vault KV v2 scenarios ===\n'
    # shellcheck source=scenarios/hashicorp_vault_kv_v2.sh
    source "${SCRIPT_DIR}/scenarios/hashicorp_vault_kv_v2.sh"
fi

if [[ "${run_kmip}" == true ]]; then
    if [[ -z "${KMIP_VAULT_HOST:-}" ]]; then
        hc_vault_xfail "KMIP_VAULT_HOST not set — skip KMIP suite"
    else
        hc_vault_hr
        printf '=== Vault KMIP engine scenarios ===\n'
        # shellcheck source=scenarios/hashicorp_vault_kmip.sh
        source "${SCRIPT_DIR}/scenarios/hashicorp_vault_kmip.sh"
    fi
fi

hc_vault_print_summary || exit 1

if [[ "${RUN_PYTEST}" -eq 1 ]]; then
    hc_vault_hr
    printf '=== Pytest vault markers ===\n'
    export VAULT_ADDR VAULT_SECRET_MOUNT VAULT_NAMESPACE VAULT_TOKEN_FILE VAULT_CA_PATH
    export KMIP_VAULT_HOST KMIP_VAULT_PORT KMIP_VAULT_CLIENT_CERT KMIP_VAULT_CLIENT_KEY KMIP_VAULT_SERVER_CA
    export VAULT_KMIP_REQUIRE_REGISTER_SUCCESS="${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}"
    exec pytest \
        tests/test_vault_providers.py::TestHashicorpVaultKeyProvider \
        tests/test_vault_hashicorp_parity.py \
        tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression \
        tests/test_vault_kmip.py \
        -v \
        "${PYTEST_ARGS[@]}"
fi

hc_vault_stop_pg
