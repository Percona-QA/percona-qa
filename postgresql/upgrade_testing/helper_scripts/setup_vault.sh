#!/bin/bash

set -e

start_vault_server() {
    vault_dir="${HELPER_DIR}/vault"
    config_file="$vault_dir/keyring_vault_ps.cnf"
    token_file="$RUN_DIR/token_file"

    echo "=> Killing any running Vault processes..."
    killall vault > /dev/null 2>&1 || true

    echo "=> Starting Vault server..."

    mkdir -p "$vault_dir"
    rm -rf "$vault_dir"/*

    "${HELPER_DIR}/vault_test_setup.sh" \
        --workdir="$vault_dir" \
        --use-ssl > ${LOG_DIR}/vault.log 2>&1

    if [[ ! -f "$config_file" ]]; then
        echo "Error: Vault config file not found at $config_file"
        exit 1
    fi

    export vault_url=$(grep 'vault_url' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export secret_mount_point=$(grep 'secret_mount_point' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export token=$(grep 'token' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export vault_ca=$(grep 'vault_ca' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')

    echo "$token" > "$token_file"
    export token_file

    echo ".. Vault server started"
}

create_token() {
  local POLICY_NAME=$1
  local POLICY_FILE=$2
  local TOKEN_FILE=$3

  export VAULT_ADDR="$vault_url"
  export VAULT_TOKEN="$token"
  export VAULT_SKIP_VERIFY=true

  $HELPER_DIR/vault/vault policy write "$POLICY_NAME" "$POLICY_FILE"

  TOKEN=$($HELPER_DIR/vault/vault token create -policy="$POLICY_NAME" -no-default-policy -format=json | jq -r .auth.client_token)
  echo "$TOKEN" > "$TOKEN_FILE"
}
