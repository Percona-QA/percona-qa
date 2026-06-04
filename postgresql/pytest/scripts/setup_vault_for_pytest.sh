#!/usr/bin/env bash
# Start Vault (SSL dev setup from automation) and export pytest env vars.
#
# Alternative for a quick local run:
#   docker compose -f postgresql/pytest/docker-compose.yml up -d vault
#   export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root VAULT_SECRET_MOUNT=secret
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="${SCRIPT_DIR}/../../automation/helper_scripts"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_pytest_vault}"
LOG_DIR="${LOG_DIR:-${RUN_DIR}/logs}"
export HELPER_DIR RUN_DIR LOG_DIR
mkdir -p "${LOG_DIR}"

# shellcheck source=/dev/null
source "${HELPER_DIR}/setup_vault.sh"
start_vault_server

export VAULT_ADDR="${vault_url}"
export VAULT_TOKEN="${token}"
export VAULT_TOKEN_FILE="${token_file}"
export VAULT_SECRET_MOUNT="${secret_mount_point}"
export VAULT_CA_PATH="${vault_ca:-}"
unset VAULT_NAMESPACE

# Optional: restricted token for mount-metadata test (HashiCorp parity)
VAULT_BIN="${VAULT_BIN:-}"
for candidate in vault "${HELPER_DIR}/vault/vault"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        VAULT_BIN="$(command -v "${candidate}")"
        break
    fi
    if [[ -x "${candidate}" ]]; then
        VAULT_BIN="${candidate}"
        break
    fi
done
if [[ -n "${VAULT_BIN}" ]] && command -v jq >/dev/null 2>&1; then
    POLICY="${RUN_DIR}/policy_kv_only_hc.hcl"
    cat > "${POLICY}" <<EOF
path "${VAULT_SECRET_MOUNT}/data/*" {
  capabilities = ["create", "read"]
}
path "${VAULT_SECRET_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
path "sys/internal/ui/mounts/*" { capabilities = [] }
path "sys/mounts/*" { capabilities = [] }
EOF
    VAULT_ADDR="${vault_url}" VAULT_TOKEN="${token}" VAULT_SKIP_VERIFY=true \
        "${VAULT_BIN}" policy write kv_only "${POLICY}" 2>/dev/null || true
    export VAULT_KV_ONLY_TOKEN_FILE="${RUN_DIR}/token_kv_only_hc"
    VAULT_ADDR="${vault_url}" VAULT_TOKEN="${token}" VAULT_SKIP_VERIFY=true \
        "${VAULT_BIN}" token create -policy=kv_only -no-default-policy -format=json \
        | jq -r .auth.client_token > "${VAULT_KV_ONLY_TOKEN_FILE}" 2>/dev/null || true
fi

echo "Vault pytest environment:"
echo "  VAULT_ADDR=${VAULT_ADDR}"
echo "  VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE}"
echo "  VAULT_SECRET_MOUNT=${VAULT_SECRET_MOUNT}"
echo "  VAULT_CA_PATH=${VAULT_CA_PATH}"
echo ""
echo "  VAULT_KV_ONLY_TOKEN_FILE=${VAULT_KV_ONLY_TOKEN_FILE:-}"
echo ""
echo "Run: pytest tests/test_vault_providers.py tests/test_vault_hashicorp_parity.py -v"
