#!/usr/bin/env bash
# Verify HashiCorp Vault **KMIP secrets engine** with pg_tde pytest.
#
# Not the same as Cosmian KMIP (test_kmip.py / OpenBao+KMIP scenarios).
# Requires Vault Enterprise with the KMIP engine enabled.
#
# Usage (external lab — your Enterprise server + certs on disk):
#   cd postgresql/pytest
#   source .env.sh
#   export KMIP_VAULT_HOST=127.0.0.1
#   export KMIP_VAULT_CLIENT_CERT=/tmp/client_cert.pem
#   export KMIP_VAULT_CLIENT_KEY=/tmp/client_key.pem
#   export KMIP_VAULT_SERVER_CA=/tmp/server_cert.pem
#   ./scripts/run_vault_kmip_revalidation.sh
#
# Or use the combined pytest runner:
#   HC_VAULT_PYTEST_SUITES=vault_kmip ./scripts/run_hashicorp_vault_pytest.sh
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

# shellcheck source=hashicorp_vault_env.sh
source "${SCRIPT_DIR}/hashicorp_vault_env.sh"
hc_vault_apply_defaults

if [[ -z "${KMIP_VAULT_HOST:-}" ]] || [[ ! -f "${KMIP_VAULT_CLIENT_CERT:-}" ]]; then
    if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
        echo "Starting Vault API (SSL dev) via setup_vault_for_pytest.sh ..." >&2
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/setup_vault_for_pytest.sh"
    fi
    if [[ -z "${KMIP_VAULT_HOST:-}" ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/setup_vault_kmip_for_pytest.sh"
    fi
fi

if [[ -z "${KMIP_VAULT_HOST:-}" ]]; then
    echo "ERROR: KMIP_VAULT_HOST not set" >&2
    echo "  External lab: export KMIP_VAULT_* (see scripts/config/hashicorp_vault.example.env)" >&2
    echo "  Local dev:    source scripts/setup_vault_kmip_for_pytest.sh" >&2
    exit 1
fi

export KMIP_VAULT_HOST KMIP_VAULT_PORT KMIP_VAULT_CLIENT_CERT KMIP_VAULT_CLIENT_KEY KMIP_VAULT_SERVER_CA
export VAULT_KMIP_REQUIRE_REGISTER_SUCCESS="${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS:-0}"

echo "Vault KMIP pytest"
echo "  docs: docs/kmip/vault-kmip-engine.md"
echo "  KMIP_VAULT_HOST=${KMIP_VAULT_HOST}"
echo "  KMIP_VAULT_PORT=${KMIP_VAULT_PORT:-5696}"
echo "  VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=${VAULT_KMIP_REQUIRE_REGISTER_SUCCESS}"
echo ""

exec pytest tests/test_vault_kmip.py -v "$@"
