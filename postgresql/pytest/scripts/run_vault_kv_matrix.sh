#!/usr/bin/env bash
# Run shared Vault KV v2 matrix + optional server-specific suites.
#
# Usage (HashiCorp Enterprise ns1/pg_tde):
#   source .env.sh
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_NAMESPACE=ns1/
#   export VAULT_SECRET_MOUNT=pg_tde
#   export VAULT_TOKEN_FILE=/tmp/token_ent
#   export VAULT_KV_PROFILES=hashicorp_enterprise
#   ./scripts/run_vault_kv_matrix.sh
#
# OpenBao:
#   source scripts/setup_openbao_for_pytest.sh
#   VAULT_KV_PROFILES=openbao ./scripts/run_vault_kv_matrix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

# shellcheck source=hashicorp_vault_env.sh
source "${SCRIPT_DIR}/hashicorp_vault_env.sh"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

hc_vault_apply_defaults

export VAULT_KV_PROFILES="${VAULT_KV_PROFILES:-${VAULT_KV_PROFILE:-auto}}"

echo "Vault KV matrix profiles: ${VAULT_KV_PROFILES}"
echo "  VAULT_ADDR=${VAULT_ADDR}"
echo "  VAULT_NAMESPACE=${VAULT_NAMESPACE:-}"
echo "  docs: docs/key_provider_matrix.md"
echo ""

TARGETS=(tests/test_vault_kv_common_matrix.py)

# Server-specific (non-shared) — enable with VAULT_KV_INCLUDE_SPECIFIC=1
if [[ "${VAULT_KV_INCLUDE_SPECIFIC:-0}" == "1" ]]; then
    TARGETS+=(
        tests/test_vault_hashicorp_parity.py
        tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression
        tests/test_openbao_bash_parity.py
    )
fi

exec pytest "${TARGETS[@]}" -v "$@"
