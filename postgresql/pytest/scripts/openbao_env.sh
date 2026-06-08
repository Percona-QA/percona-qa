#!/usr/bin/env bash
# Shared Vault/OpenBao env helpers for pytest scripts.
# Sourced by setup_openbao_for_pytest.sh and run_openbao_revalidation.sh.

OPENBAO_DEFAULT_ADDR="${OPENBAO_DEFAULT_ADDR:-http://127.0.0.1:8200}"
OPENBAO_DEFAULT_MOUNT="${OPENBAO_DEFAULT_MOUNT:-pg_tde}"
OPENBAO_DEFAULT_NAMESPACE="${OPENBAO_DEFAULT_NAMESPACE:-pg_tde_ns1}"

openbao_find_binary() {
    if [[ -n "${OPENBAO_BIN:-}" && -x "${OPENBAO_BIN}" ]]; then
        echo "${OPENBAO_BIN}"
        return 0
    fi
    local candidate
    for candidate in bao /usr/bin/bao /usr/local/bin/bao; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

_vault_token_value() {
    if [[ -n "${VAULT_TOKEN_FILE:-}" && -f "${VAULT_TOKEN_FILE}" ]]; then
        tr -d '[:space:]' < "${VAULT_TOKEN_FILE}"
        return 0
    fi
    if [[ -n "${VAULT_TOKEN:-}" ]]; then
        echo "${VAULT_TOKEN}"
        return 0
    fi
    return 1
}

vault_server_reachable() {
    local addr="${1:-${VAULT_ADDR:-}}"
    local token
    [[ -n "${addr}" ]] || return 1
    token="$(_vault_token_value)" || return 1

    local url="${addr%/}/v1/sys/health"

    if command -v curl >/dev/null 2>&1; then
        # Cluster health — not scoped to a child namespace.
        curl -fsS -m 5 -H "X-Vault-Token: ${token}" "${url}" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# True when VAULT_* is set, token is available, and /v1/sys/health responds.
vault_pytest_env_ready() {
    [[ -n "${VAULT_ADDR:-}" ]] \
        && _vault_token_value >/dev/null \
        && vault_server_reachable "${VAULT_ADDR}"
}

openbao_pytest_env_ready() {
    vault_pytest_env_ready \
        && [[ -n "${VAULT_NAMESPACE:-}" ]]
}

vault_print_pytest_env() {
    local label="${1:-Vault/OpenBao pytest environment}"
    echo "${label}:"
    echo "  VAULT_ADDR=${VAULT_ADDR}"
    echo "  VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE:-}"
    echo "  VAULT_SECRET_MOUNT=${VAULT_SECRET_MOUNT:-}"
    echo "  VAULT_NAMESPACE=${VAULT_NAMESPACE:-}"
    echo "  VAULT_KV_ONLY_TOKEN_FILE=${VAULT_KV_ONLY_TOKEN_FILE:-}"
    echo "  OPENBAO_BIN=${OPENBAO_BIN:-}"
    echo ""
    echo "Run: pytest tests/test_vault_providers.py::TestOpenBaoKeyProvider -v"
}

openbao_not_configured_message() {
    cat <<'EOF'
ERROR: OpenBao pytest environment not configured.

Option A — install and start local OpenBao (recommended):
  cd postgresql/pytest
  ./scripts/install_openbao.sh
  source scripts/setup_openbao_for_pytest.sh

Option B — manual install (pg_tde ci_scripts/ubuntu-deps.sh):
  OPENBAO_VERSION=2.5.4
  ARCH=$(dpkg --print-architecture)
  wget https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb
  sudo dpkg -i openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb
  source scripts/setup_openbao_for_pytest.sh

Option C — reuse an existing OpenBao server:
  export VAULT_ADDR=http://127.0.0.1:8200
  export VAULT_TOKEN_FILE=/path/to/token
  export VAULT_SECRET_MOUNT=pg_tde
  export VAULT_NAMESPACE=pg_tde_ns1/

See docs/vault.md § Install OpenBao
EOF
}
