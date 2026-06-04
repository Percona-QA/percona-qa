#!/usr/bin/env bash
# Configure HashiCorp Vault KMIP secrets engine and export KMIP_VAULT_* for pytest.
#
# Requires Vault Enterprise with the KMIP engine (not Vault KV v2).
# Prerequisite: a running Vault API (e.g. source scripts/setup_vault_for_pytest.sh).
#
# Usage:
#   cd postgresql/pytest
#   source scripts/setup_vault_for_pytest.sh    # optional: local SSL dev Vault
#   source scripts/setup_vault_kmip_for_pytest.sh
#   pytest tests/test_vault_kmip.py -v
#
# Strict pass after a fix:
#   export VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1
#   pytest tests/test_vault_kmip.py -v
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${RUN_DIR:-/tmp/pg_tde_pytest_vault_kmip}"
CERT_DIR="${RUN_DIR}/certs"
SCOPE="${VAULT_KMIP_SCOPE:-pg_tde}"
ROLE="${VAULT_KMIP_ROLE:-pg_tde_ops}"
KMIP_PORT="${VAULT_KMIP_LISTEN_PORT:-5696}"

if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
    echo "ERROR: set VAULT_ADDR and VAULT_TOKEN (source scripts/setup_vault_for_pytest.sh)" >&2
    return 1 2>/dev/null || exit 1
fi

VAULT_BIN="${VAULT_BIN:-}"
if [[ -z "${VAULT_BIN}" ]]; then
    for candidate in vault "${SCRIPT_DIR}/../../automation/helper_scripts/vault/vault"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            VAULT_BIN="$(command -v "${candidate}")"
            break
        fi
        if [[ -x "${candidate}" ]]; then
            VAULT_BIN="${candidate}"
            break
        fi
    done
fi
if [[ -z "${VAULT_BIN}" ]]; then
    echo "ERROR: vault CLI not found; install Vault or set VAULT_BIN" >&2
    return 1 2>/dev/null || exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required to parse KMIP credentials" >&2
    return 1 2>/dev/null || exit 1
fi

export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
mkdir -p "${CERT_DIR}"

_vault() {
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
        VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY}" \
        "${VAULT_BIN}" "$@"
}

echo "Enabling Vault KMIP secrets engine (Enterprise feature)..."
if ! _vault secrets enable kmip 2>/dev/null; then
    if ! _vault secrets list -format=json | jq -e '."kmip/"' >/dev/null 2>&1; then
        echo "ERROR: could not enable kmip engine — is this Vault Enterprise?" >&2
        return 1 2>/dev/null || exit 1
    fi
    echo "  kmip engine already enabled"
fi

echo "Configuring KMIP listener on 0.0.0.0:${KMIP_PORT} (RSA CA for client certs)..."
_vault write kmip/config \
    listen_addrs="0.0.0.0:${KMIP_PORT}" \
    server_hostnames=127.0.0.1 \
    server_ips=127.0.0.1 \
    tls_ca_key_type=rsa \
    tls_ca_key_bits=2048

_vault write -f "kmip/scope/${SCOPE}" 2>/dev/null || true
_vault write "kmip/scope/${SCOPE}/role/${ROLE}" operation_all=true

CRED_JSON="${CERT_DIR}/credential.json"
_vault write -format=json \
    "kmip/scope/${SCOPE}/role/${ROLE}/credential/generate" \
    format=pem > "${CRED_JSON}"

jq -r .data.certificate < "${CRED_JSON}" > "${CERT_DIR}/client_cert.pem"
jq -r .data.private_key < "${CRED_JSON}" > "${CERT_DIR}/client_key.pem"
_vault read -format=json kmip/ca | jq -r '.data.ca_pem' > "${CERT_DIR}/server_ca.pem"

export KMIP_VAULT_HOST="${KMIP_VAULT_HOST:-127.0.0.1}"
export KMIP_VAULT_PORT="${KMIP_VAULT_PORT:-${KMIP_PORT}}"
export KMIP_VAULT_CLIENT_CERT="${KMIP_VAULT_CLIENT_CERT:-${CERT_DIR}/client_cert.pem}"
export KMIP_VAULT_CLIENT_KEY="${KMIP_VAULT_CLIENT_KEY:-${CERT_DIR}/client_key.pem}"
export KMIP_VAULT_SERVER_CA="${KMIP_VAULT_SERVER_CA:-${CERT_DIR}/server_ca.pem}"
export VAULT_KMIP_TEST_PROVIDER_NAME="${VAULT_KMIP_TEST_PROVIDER_NAME:-kmip-provider-1}"
export VAULT_KMIP_TEST_KEY_NAME="${VAULT_KMIP_TEST_KEY_NAME:-kmip-key-12012025}"

echo "Vault KMIP pytest environment:"
echo "  KMIP_VAULT_HOST=${KMIP_VAULT_HOST}"
echo "  KMIP_VAULT_PORT=${KMIP_VAULT_PORT}"
echo "  KMIP_VAULT_CLIENT_CERT=${KMIP_VAULT_CLIENT_CERT}"
echo "  KMIP_VAULT_CLIENT_KEY=${KMIP_VAULT_CLIENT_KEY}"
echo "  KMIP_VAULT_SERVER_CA=${KMIP_VAULT_SERVER_CA}"
echo "  VAULT_KMIP_TEST_PROVIDER_NAME=${VAULT_KMIP_TEST_PROVIDER_NAME}"
echo "  VAULT_KMIP_TEST_KEY_NAME=${VAULT_KMIP_TEST_KEY_NAME}"
echo ""
echo "Run: pytest tests/test_vault_kmip.py -v"
