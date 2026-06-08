#!/usr/bin/env bash
# Start local OpenBao (dev mode) and export pytest env vars (namespace + mount).
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   source scripts/setup_openbao_for_pytest.sh
#   pytest -m openbao -v
#
# Requires ``bao`` on PATH — install via scripts/install_openbao.sh.
# Scenarios 2–8 in open_bao_tests also need KMIP:
#   source scripts/setup_cosmian_for_pytest.sh
#
# Legacy source build (Go >= 1.25.4): OPENBAO_BUILD_FROM_SOURCE=1 source this script.
#
# NOTE: Sourced script — no ``set -e`` (SSH-safe on failure).
set -uo pipefail

_SCRIPT_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _SCRIPT_SOURCED=1
fi

_openbao_setup_fail() {
    openbao_not_configured_message >&2
    if [[ "${_SCRIPT_SOURCED}" -eq 1 ]]; then
        return 1
    fi
    exit 1
}

_openbao_setup_abort() {
    _openbao_setup_fail || true
    return 1 2>/dev/null || exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openbao_env.sh
source "${SCRIPT_DIR}/openbao_env.sh"

RUN_DIR="${OPENBAO_PYTEST_RUN_DIR:-/tmp/pg_tde_pytest_openbao}"
mkdir -p "${RUN_DIR}"

# Stale VAULT_NAMESPACE in the shell makes ``bao namespace create`` target a
# non-existent parent and return HTTP 404.
if [[ "${OPENBAO_FORCE_RESTART:-0}" == "1" ]]; then
    unset VAULT_NAMESPACE VAULT_KV_ONLY_TOKEN_FILE
fi

if [[ "${OPENBAO_FORCE_RESTART:-0}" != "1" ]] && openbao_pytest_env_ready; then
    export OPENBAO_BIN="${OPENBAO_BIN:-$(openbao_find_binary 2>/dev/null || true)}"
    vault_print_pytest_env "OpenBao pytest environment (VAULT_* already set)"
    echo "  (set OPENBAO_FORCE_RESTART=1 to spawn a fresh dev server)"
    return 0 2>/dev/null || exit 0
fi

if [[ "${OPENBAO_BUILD_FROM_SOURCE:-0}" == "1" ]]; then
    HELPER_DIR="${SCRIPT_DIR}/../../automation/helper_scripts"
    export RUN_DIR
    # shellcheck source=/dev/null
    source "${HELPER_DIR}/setup_openbao.sh"
    start_openbao_server
    export VAULT_ADDR="${vault_url:-http://127.0.0.1:8200}"
    export VAULT_TOKEN="${ROOT_TOKEN:-${VAULT_TOKEN}}"
    export VAULT_TOKEN_FILE="${token_filepath}"
    export VAULT_SECRET_MOUNT="${secret_mount_point:-pg_tde}"
    export VAULT_NAMESPACE="${VAULT_NAMESPACE:-pg_tde_ns1/}"
    export OPENBAO_BIN="${OPENBAO_BIN:-$(find "${RUN_DIR}" -maxdepth 3 -path '*/bin/bao' -type f 2>/dev/null | head -1)}"
else
    BAO_BIN="$(openbao_find_binary)" || {
        echo "ERROR: bao not found." >&2
        echo "  Run: ./scripts/install_openbao.sh" >&2
        _openbao_setup_abort
    }
    export OPENBAO_BIN="${BAO_BIN}"

    # Stop stale dev servers from prior pytest runs.
    pkill -f "[b]ao server" 2>/dev/null || true
    sleep 0.5

    BAO_LOG="${RUN_DIR}/bao_server.log"
    : > "${BAO_LOG}"
    "${BAO_BIN}" server -dev -dev-listen-address=127.0.0.1:8200 >"${BAO_LOG}" 2>&1 &
    OPENBAO_PID=$!
    export OPENBAO_PID

    ROOT_TOKEN=""
    deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        if grep -q "Root Token:" "${BAO_LOG}" 2>/dev/null; then
            ROOT_TOKEN="$(grep -m1 "Root Token:" "${BAO_LOG}" | awk '{print $3}')"
            break
        fi
        if ! kill -0 "${OPENBAO_PID}" 2>/dev/null; then
            echo "ERROR: bao server exited early. Log:" >&2
            cat "${BAO_LOG}" >&2
            _openbao_setup_abort
        fi
        sleep 0.3
    done

    if [[ -z "${ROOT_TOKEN}" ]]; then
        echo "ERROR: could not read Root Token from ${BAO_LOG}" >&2
        cat "${BAO_LOG}" >&2
        _openbao_setup_abort
    fi

    TOKEN_FILE="${RUN_DIR}/bao_root_token"
    printf '%s\n' "${ROOT_TOKEN}" > "${TOKEN_FILE}"

    export VAULT_ADDR="${OPENBAO_DEFAULT_ADDR}"
    export VAULT_TOKEN_FILE="${TOKEN_FILE}"
    unset VAULT_TOKEN
    export VAULT_SECRET_MOUNT="${OPENBAO_DEFAULT_MOUNT}"
    export VAULT_NAMESPACE="${OPENBAO_DEFAULT_NAMESPACE}/"

    if ! openbao_bootstrap_namespace_mount \
        "${BAO_BIN}" "${ROOT_TOKEN}" "${OPENBAO_DEFAULT_NAMESPACE}" \
        "${OPENBAO_DEFAULT_MOUNT}" "${RUN_DIR}/bootstrap.err"; then
        _openbao_setup_abort
    fi

    echo "Local OpenBao dev server:"
    echo "  bao=${BAO_BIN} pid=${OPENBAO_PID}"
    echo "  log=${BAO_LOG}"
    echo "  namespace=${VAULT_NAMESPACE} mount=${VAULT_SECRET_MOUNT} (KV v2 verified)"
fi

if [[ "${OPENBAO_BUILD_FROM_SOURCE:-0}" == "1" ]]; then
    ROOT="$(tr -d '[:space:]' < "${VAULT_TOKEN_FILE}")"
    if ! openbao_bootstrap_namespace_mount \
        "${OPENBAO_BIN}" "${ROOT}" "${OPENBAO_DEFAULT_NAMESPACE}" \
        "${OPENBAO_DEFAULT_MOUNT}" "${RUN_DIR}/bootstrap.err"; then
        _openbao_setup_abort
    fi
fi

# PG-1959: restricted token (KV read/write, no sys/mounts)
if [[ -n "${OPENBAO_BIN:-}" && -x "${OPENBAO_BIN}" && -f "${VAULT_TOKEN_FILE:-}" ]]; then
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
    ROOT="$(tr -d '[:space:]' < "${VAULT_TOKEN_FILE}")"
    NS_TRIM="${VAULT_NAMESPACE%/}"
    # Policy + token live in the child namespace (matches automation setup).
    if _bao_at_ns "${OPENBAO_BIN}" "${ROOT}" "${VAULT_ADDR}" "${NS_TRIM}" \
        policy write kv_only "${POLICY}" 2>"${RUN_DIR}/policy_kv_only.err"; then
        export VAULT_KV_ONLY_TOKEN_FILE="${RUN_DIR}/token_kv_only"
        if _bao_at_ns "${OPENBAO_BIN}" "${ROOT}" "${VAULT_ADDR}" "${NS_TRIM}" \
            token create -policy=kv_only -no-default-policy -format=json \
            2>"${RUN_DIR}/token_kv_only.err" \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['auth']['client_token'])" \
            > "${VAULT_KV_ONLY_TOKEN_FILE}"; then
            :
        else
            echo "WARN: could not create kv_only token (PG-1959 test may skip)" >&2
            unset VAULT_KV_ONLY_TOKEN_FILE
        fi
    else
        echo "WARN: could not write kv_only policy — see ${RUN_DIR}/policy_kv_only.err" >&2
        unset VAULT_KV_ONLY_TOKEN_FILE
    fi
fi

if ! openbao_pytest_env_ready; then
    echo "ERROR: OpenBao KV mount not ready after setup" >&2
    _openbao_setup_abort
fi

vault_print_pytest_env "OpenBao pytest environment"
echo ""
echo "Full OpenBao suite: ./scripts/run_openbao_revalidation.sh"
echo "Note: dev server stops when the shell session ends (or pkill bao server)."
