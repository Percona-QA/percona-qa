#!/usr/bin/env bash
# Defaults and normalization for HashiCorp Vault revalidation scripts.
# shellcheck shell=bash

HC_VAULT_DEFAULT_ADDR="${HC_VAULT_DEFAULT_ADDR:-http://127.0.0.1:8200}"
HC_VAULT_DEFAULT_MOUNT="${HC_VAULT_DEFAULT_MOUNT:-pg_tde}"
HC_VAULT_DEFAULT_NAMESPACE="${HC_VAULT_DEFAULT_NAMESPACE:-ns1/}"
HC_VAULT_DEFAULT_TOKEN_FILE="${HC_VAULT_DEFAULT_TOKEN_FILE:-/tmp/token_ent}"

hc_vault_apply_defaults() {
    # .env.sh from setup_test_env.sh often sets VAULT_ADDR="" — treat empty as unset.
    export VAULT_ADDR="${VAULT_ADDR:-${HC_VAULT_DEFAULT_ADDR}}"
    export VAULT_SECRET_MOUNT="${VAULT_SECRET_MOUNT:-${HC_VAULT_DEFAULT_MOUNT}}"
    export VAULT_NAMESPACE="${VAULT_NAMESPACE:-${HC_VAULT_DEFAULT_NAMESPACE}}"
    export VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-${HC_VAULT_DEFAULT_TOKEN_FILE}}"
    export VAULT_CA_PATH="${VAULT_CA_PATH:-}"

    export KMIP_VAULT_HOST="${KMIP_VAULT_HOST:-127.0.0.1}"
    export KMIP_VAULT_PORT="${KMIP_VAULT_PORT:-5696}"
    export KMIP_VAULT_CLIENT_CERT="${KMIP_VAULT_CLIENT_CERT:-/tmp/client_cert.pem}"
    export KMIP_VAULT_CLIENT_KEY="${KMIP_VAULT_CLIENT_KEY:-/tmp/client_key.pem}"
    export KMIP_VAULT_SERVER_CA="${KMIP_VAULT_SERVER_CA:-/tmp/server_cert.pem}"

    export RUN_DIR="${RUN_DIR:-/tmp/pg_tde_hashicorp_vault}"
    export PORT="${PORT:-5433}"
    export PGUSER="${PGUSER:-$(id -un)}"
    export PGDATA="${PGDATA:-${RUN_DIR}/data}"
    export HC_VAULT_SUITES="${HC_VAULT_SUITES:-all}"

    # pg_tde SQL expects namespace with trailing slash (e.g. ns1/).
    if [[ -n "${VAULT_NAMESPACE}" && "${VAULT_NAMESPACE}" != */ ]]; then
        export VAULT_NAMESPACE="${VAULT_NAMESPACE}/"
    fi

    # Strip trailing slash from URL for curl/vault CLI.
    export VAULT_ADDR="${VAULT_ADDR%/}"
}

hc_vault_env_ready() {
    hc_vault_apply_defaults
    [[ -n "${VAULT_ADDR}" ]] || return 1
    [[ -f "${VAULT_TOKEN_FILE}" ]] || return 1
    return 0
}

hc_vault_env_not_ready_message() {
    hc_vault_apply_defaults
    echo "HashiCorp Vault env incomplete:" >&2
    echo "  VAULT_ADDR=${VAULT_ADDR:-<unset>} (default: ${HC_VAULT_DEFAULT_ADDR})" >&2
    echo "  VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE:-<unset>}" >&2
    if [[ ! -f "${VAULT_TOKEN_FILE:-}" ]]; then
        echo "  token file missing — create it, e.g.: echo '<token>' > /tmp/token_ent" >&2
    fi
    echo "" >&2
    echo "Add to .env.sh or source scripts/config/hashicorp_vault.example.env" >&2
}
