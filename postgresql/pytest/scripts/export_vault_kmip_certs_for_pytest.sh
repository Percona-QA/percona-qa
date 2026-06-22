#!/usr/bin/env bash
# Export Vault KMIP client credentials to PEM files for pg_tde / pytest.
#
# For an existing Vault Enterprise KMIP engine (manual lab setup):
#
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=hvs....          # or vault login
#   ./scripts/export_vault_kmip_certs_for_pytest.sh
#   source /tmp/vault_kmip_pytest.env   # prints export lines — source this
#   pytest -m vault_kmip -v
#
# Matches scope/role from customer labs (override via env):
#   VAULT_KMIP_SCOPE=pg-tde VAULT_KMIP_ROLE=postgres ./scripts/export_vault_kmip_certs_for_pytest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KMIP_SCOPE="${VAULT_KMIP_SCOPE:-pg-tde}"
VAULT_KMIP_ROLE="${VAULT_KMIP_ROLE:-postgres}"
KMIP_VAULT_HOST="${KMIP_VAULT_HOST:-127.0.0.1}"
KMIP_VAULT_PORT="${KMIP_VAULT_PORT:-5696}"
CERT_DIR="${KMIP_VAULT_CERT_DIR:-/tmp}"
ENV_FILE="${KMIP_VAULT_ENV_FILE:-${CERT_DIR}/vault_kmip_pytest.env}"

VAULT_BIN="${VAULT_BIN:-vault}"
if ! command -v "${VAULT_BIN}" >/dev/null 2>&1; then
    echo "ERROR: vault CLI not found (set VAULT_BIN)" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required" >&2
    exit 2
fi

if [[ -z "${VAULT_TOKEN:-}" ]] && [[ -z "${VAULT_TOKEN_FILE:-}" ]]; then
    echo "ERROR: set VAULT_TOKEN or VAULT_TOKEN_FILE (vault login)" >&2
    exit 2
fi

_vault() {
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN:-$(tr -d '[:space:]' < "${VAULT_TOKEN_FILE}")}" \
        "${VAULT_BIN}" "$@"
}

mkdir -p "${CERT_DIR}"
CRED_JSON="${CERT_DIR}/vault_kmip_credential.json"

echo "Generating KMIP credential: kmip/scope/${VAULT_KMIP_SCOPE}/role/${VAULT_KMIP_ROLE}/credential/generate"
_vault write -format=json \
    "kmip/scope/${VAULT_KMIP_SCOPE}/role/${VAULT_KMIP_ROLE}/credential/generate" \
    format=pem > "${CRED_JSON}"

CLIENT_CERT="${CERT_DIR}/client_cert.pem"
CLIENT_KEY="${CERT_DIR}/client_key.pem"
SERVER_CA="${CERT_DIR}/server_cert.pem"

jq -r .data.certificate < "${CRED_JSON}" > "${CLIENT_CERT}"
jq -r .data.private_key < "${CRED_JSON}" > "${CLIENT_KEY}"
chmod 600 "${CLIENT_KEY}"

# Prefer KMIP engine CA; fall back to operator-supplied server cert path.
if _vault read -format=json kmip/ca >/dev/null 2>&1; then
    _vault read -format=json kmip/ca | jq -r '.data.ca_pem' > "${SERVER_CA}"
elif [[ -n "${VAULT_KMIP_SERVER_CERT:-}" && -f "${VAULT_KMIP_SERVER_CERT}" ]]; then
    cp "${VAULT_KMIP_SERVER_CERT}" "${SERVER_CA}"
else
    echo "WARN: kmip/ca not readable — set VAULT_KMIP_SERVER_CERT to your kmip-server.crt path" >&2
    : > "${SERVER_CA}"
fi

cat > "${ENV_FILE}" <<EOF
# source this file before pytest -m vault_kmip
export KMIP_VAULT_HOST=${KMIP_VAULT_HOST}
export KMIP_VAULT_PORT=${KMIP_VAULT_PORT}
export KMIP_VAULT_CLIENT_CERT=${CLIENT_CERT}
export KMIP_VAULT_CLIENT_KEY=${CLIENT_KEY}
export KMIP_VAULT_SERVER_CA=${SERVER_CA}
export VAULT_KMIP_TEST_PROVIDER_NAME=${VAULT_KMIP_TEST_PROVIDER_NAME:-kmip-provider-1}
export VAULT_KMIP_TEST_KEY_NAME=${VAULT_KMIP_TEST_KEY_NAME:-kmip-key-12012025}
EOF

echo "Wrote KMIP PEM files:"
echo "  ${CLIENT_CERT}"
echo "  ${CLIENT_KEY}"
echo "  ${SERVER_CA}"
echo ""
echo "Pytest env written to: ${ENV_FILE}"
echo "  source ${ENV_FILE}"
echo "  pytest -m vault_kmip -v"
