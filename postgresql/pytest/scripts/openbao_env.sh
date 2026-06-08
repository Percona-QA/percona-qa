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
        curl -fsS -m 5 -H "X-Vault-Token: ${token}" "${url}" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# pg_tde POSTs to /v1/{mount}/data/{key} with X-Vault-Namespace (e.g. pg_tde_ns1/).
openbao_kv_mount_ready() {
    local addr="${VAULT_ADDR:-}"
    local mount="${VAULT_SECRET_MOUNT:-${OPENBAO_DEFAULT_MOUNT}}"
    local ns="${VAULT_NAMESPACE:-}"
    local token
    token="$(_vault_token_value)" || return 1
    [[ -n "${addr}" && -n "${ns}" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
        -H "X-Vault-Token: ${token}" \
        -H "X-Vault-Namespace: ${ns}" \
        -H "Content-Type: application/json" \
        -X POST "${addr%/}/v1/${mount}/data/pytest_mount_probe" \
        -d '{"data":{"key":"dGVzdA=="}}')"
    [[ "${code}" == "200" || "${code}" == "204" ]]
}

# Run ``bao`` at the root namespace (never inherit VAULT_NAMESPACE from the shell).
_bao_at_root() {
    local bao="$1" token="$2" addr="$3"
    shift 3
    env -u VAULT_NAMESPACE VAULT_ADDR="${addr}" VAULT_TOKEN="${token}" \
        "${bao}" "$@"
}

# Run ``bao`` inside child namespace ``ns`` (no trailing slash).
_bao_at_ns() {
    local bao="$1" token="$2" addr="$3" ns="$4"
    shift 4
    env -u VAULT_NAMESPACE \
        VAULT_ADDR="${addr}" VAULT_TOKEN="${token}" VAULT_NAMESPACE="${ns}" \
        "${bao}" "$@"
}

# Create namespace + KV v2 mount (mirrors automation setup_openbao.sh).
openbao_bootstrap_namespace_mount() {
    local bao="$1"
    local root_token="$2"
    local ns="${3:-${OPENBAO_DEFAULT_NAMESPACE}}"
    local mount="${4:-${OPENBAO_DEFAULT_MOUNT}}"
    local addr="${VAULT_ADDR:-${OPENBAO_DEFAULT_ADDR}}"
    local err_log="${5:-/tmp/pg_tde_pytest_openbao/bootstrap.err}"

    mkdir -p "$(dirname "${err_log}")"
    : > "${err_log}"

    if ! _bao_at_root "${bao}" "${root_token}" "${addr}" namespace read "${ns}" \
        >/dev/null 2>&1; then
        if ! _bao_at_root "${bao}" "${root_token}" "${addr}" namespace create "${ns}" \
            >>"${err_log}" 2>&1; then
            if ! _bao_at_root "${bao}" "${root_token}" "${addr}" namespace list -format=json \
                2>>"${err_log}" | grep -q "\"${ns}/\""; then
                echo "ERROR: failed to create OpenBao namespace '${ns}'" >&2
                echo "  Hint: unset VAULT_NAMESPACE before setup (stale export breaks namespace create)" >&2
                cat "${err_log}" >&2
                return 1
            fi
        fi
    fi

    if ! _bao_at_ns "${bao}" "${root_token}" "${addr}" "${ns}" secrets list -format=json \
        2>>"${err_log}" | grep -q "\"${mount}/\""; then
        if ! _bao_at_ns "${bao}" "${root_token}" "${addr}" "${ns}" \
            secrets enable -version=2 -path="${mount}" kv >>"${err_log}" 2>&1; then
            echo "ERROR: failed to enable KV v2 mount '${mount}' in namespace '${ns}'" >&2
            cat "${err_log}" >&2
            return 1
        fi
    fi

    export VAULT_ADDR="${addr}"
    export VAULT_SECRET_MOUNT="${mount}"
    export VAULT_NAMESPACE="${ns}/"

    if ! openbao_kv_mount_ready; then
        echo "ERROR: KV mount '${mount}' not writable in namespace '${ns}/'" >&2
        echo "  Probe: POST ${addr}/v1/${mount}/data/pytest_mount_probe" >&2
        cat "${err_log}" >&2
        return 1
    fi
    return 0
}

vault_pytest_env_ready() {
    [[ -n "${VAULT_ADDR:-}" ]] \
        && _vault_token_value >/dev/null \
        && vault_server_reachable "${VAULT_ADDR}"
}

openbao_pytest_env_ready() {
    vault_pytest_env_ready \
        && [[ -n "${VAULT_NAMESPACE:-}" ]] \
        && openbao_kv_mount_ready
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
  OPENBAO_FORCE_RESTART=1 source scripts/setup_openbao_for_pytest.sh

Option B — manual install (pg_tde ci_scripts/ubuntu-deps.sh):
  OPENBAO_VERSION=2.5.4
  ARCH=$(dpkg --print-architecture)
  wget https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb
  sudo dpkg -i openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb
  OPENBAO_FORCE_RESTART=1 source scripts/setup_openbao_for_pytest.sh

See docs/vault.md § Install OpenBao
EOF
}
