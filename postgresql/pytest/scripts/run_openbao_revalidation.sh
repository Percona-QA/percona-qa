#!/usr/bin/env bash
# Run OpenBao pytest suite (namespace + pg_tde_open_bao_tests parity).
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   ./scripts/run_openbao_revalidation.sh
#
# KMIP-backed scenarios (open_bao_tests 2–8) need Cosmian:
#   source scripts/setup_cosmian_for_pytest.sh   # optional; script tries auto
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

# shellcheck source=openbao_env.sh
source "${SCRIPT_DIR}/openbao_env.sh"
# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

# .env.sh may export HashiCorp Vault defaults (e.g. VAULT_SECRET_MOUNT=secret).
# When the local OpenBao pytest token exists, restore mount/namespace for pg_tde.
OPENBAO_RUN_DIR="${OPENBAO_PYTEST_RUN_DIR:-/tmp/pg_tde_pytest_openbao}"
if [[ -f "${OPENBAO_RUN_DIR}/bao_root_token" ]]; then
    export VAULT_ADDR="${VAULT_ADDR:-${OPENBAO_DEFAULT_ADDR}}"
    export VAULT_TOKEN_FILE="${OPENBAO_RUN_DIR}/bao_root_token"
    export VAULT_SECRET_MOUNT="${OPENBAO_DEFAULT_MOUNT}"
    export VAULT_NAMESPACE="${OPENBAO_DEFAULT_NAMESPACE}/"
    unset VAULT_TOKEN
fi

if ! openbao_pytest_env_ready; then
    export OPENBAO_FORCE_RESTART=1
    unset VAULT_NAMESPACE VAULT_KV_ONLY_TOKEN_FILE
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_openbao_for_pytest.sh"
fi

if ! openbao_pytest_env_ready; then
    openbao_not_configured_message >&2
    exit 1
fi

# Scenarios 2–8 use KMIP alongside OpenBao; start Cosmian when missing.
if ! kmip_pytest_env_ready; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_cosmian_for_pytest.sh" 2>/dev/null || true
fi

if kmip_pytest_env_ready; then
    echo "KMIP available for OpenBao+KMIP scenarios."
else
    echo "WARN: KMIP not configured — OpenBao+KMIP tests will skip." >&2
fi

echo "OpenBao revalidation"
echo "  docs: docs/vault.md"
echo ""

exec pytest \
    tests/test_vault_providers.py::TestOpenBaoKeyProvider \
    tests/test_openbao_bash_parity.py \
    tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression \
    -v \
    "$@"
