#!/bin/bash

set -e

start_vault_server() {
    local vault_dir="${HELPER_DIR}/vault"
    local config_file="$vault_dir/keyring_vault_ps.cnf"
    local token_file="/tmp/token_file"

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
