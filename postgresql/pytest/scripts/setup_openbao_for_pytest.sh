#!/usr/bin/env bash
# Build/start OpenBao dev server and export pytest env vars (namespace + mount).
#
# Requires Go >= 1.25.4 (see automation helper). Also start KMIP if running
# open_bao_tests scenario 2/3: source scripts/setup_cosmian_for_pytest.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="${SCRIPT_DIR}/../../automation/helper_scripts"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_pytest_openbao}"
export RUN_DIR
mkdir -p "${RUN_DIR}"

# shellcheck source=/dev/null
source "${HELPER_DIR}/setup_openbao.sh"
start_openbao_server

export VAULT_ADDR="${vault_url:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${ROOT_TOKEN:-${VAULT_TOKEN}}"
export VAULT_TOKEN_FILE="${token_filepath}"
export VAULT_SECRET_MOUNT="${secret_mount_point:-pg_tde}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-pg_tde_ns1/}"

# PG-1959: restricted token (KV read/write, no sys/mounts) for mount-metadata test
if [[ -z "${OPENBAO_BIN:-}" ]]; then
  OPENBAO_BIN="$(find "${RUN_DIR}" -maxdepth 3 -path '*/bin/bao' -type f 2>/dev/null | head -1)"
  [[ -n "${OPENBAO_BIN}" ]] && export OPENBAO_BIN
fi
if [[ -n "${OPENBAO_BIN:-}" && -x "${OPENBAO_BIN}" && -f "${token_filepath}" ]]; then
  POLICY="${RUN_DIR}/policy_kv_only.hcl"
  cat > "${POLICY}" <<EOF
path "${VAULT_SECRET_MOUNT}/data/*" {
  capabilities = ["create", "read"]
}
path "${VAULT_SECRET_MOUNT}/metadata/*" {
  capabilities = ["read", "list"]
}
path "sys/internal/ui/mounts/*" {
  capabilities = []
}
path "sys/mounts/*" {
  capabilities = []
}
EOF
  export VAULT_NAMESPACE="${VAULT_NAMESPACE%/}"
  VAULT_TOKEN="$(cat "${token_filepath}")" "${OPENBAO_BIN}" policy write kv_only "${POLICY}"
  export VAULT_KV_ONLY_TOKEN_FILE="${RUN_DIR}/token_kv_only"
  VAULT_TOKEN="$(cat "${token_filepath}")" "${OPENBAO_BIN}" token create \
    -policy=kv_only -no-default-policy -format=json \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['auth']['client_token'])" \
    > "${VAULT_KV_ONLY_TOKEN_FILE}"
  export VAULT_NAMESPACE="${VAULT_NAMESPACE}/"
  echo "  VAULT_KV_ONLY_TOKEN_FILE=${VAULT_KV_ONLY_TOKEN_FILE}"
fi

echo "OpenBao pytest environment:"
echo "  VAULT_ADDR=${VAULT_ADDR}"
echo "  VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE}"
echo "  VAULT_SECRET_MOUNT=${VAULT_SECRET_MOUNT}"
echo "  VAULT_NAMESPACE=${VAULT_NAMESPACE}"
echo ""
echo "Run: pytest tests/test_vault_providers.py::TestOpenBaoKeyProvider -v"
echo "     pytest tests/test_external_key_provider_regressions.py -v"
