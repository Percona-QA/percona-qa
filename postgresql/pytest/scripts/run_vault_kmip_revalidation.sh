#!/usr/bin/env bash
# Verify HashiCorp Vault **KMIP secrets engine** with pg_tde pytest.
#
# Not the same as Cosmian KMIP (test_kmip.py / OpenBao+KMIP scenarios).
# Requires Vault Enterprise with the KMIP engine enabled.
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   ./scripts/run_vault_kmip_revalidation.sh
#
# Strict pass after pg_tde fixes Register -2:
#   VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1 ./scripts/run_vault_kmip_revalidation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
    echo "Starting Vault API (SSL dev) via setup_vault_for_pytest.sh ..." >&2
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_vault_for_pytest.sh"
fi

if [[ -z "${KMIP_VAULT_HOST:-}" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_vault_kmip_for_pytest.sh"
fi

if [[ -z "${KMIP_VAULT_HOST:-}" ]]; then
    echo "ERROR: KMIP_VAULT_HOST not set after setup_vault_kmip_for_pytest.sh" >&2
    echo "  Vault KMIP requires Vault Enterprise (secrets enable kmip)." >&2
    exit 1
fi

echo "Vault KMIP revalidation"
echo "  docs: docs/vault_kmip.md"
echo "  KMIP_VAULT_HOST=${KMIP_VAULT_HOST}"
echo "  KMIP_VAULT_PORT=${KMIP_VAULT_PORT:-5696}"
echo "  VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}"
echo ""

exec pytest tests/test_vault_kmip.py -v "$@"
