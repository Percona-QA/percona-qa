#!/bin/bash

start_vault_server() {
    local script_dir="${SCRIPT_DIR:-$(pwd)}"
    local vault_dir="$script_dir/vault"
    local config_file="$vault_dir/keyring_vault_ps.cnf"

    echo "=> Killing any running Vault processes..."
    killall vault > /dev/null 2>&1 || true

    echo "=> Starting Vault server..."

    mkdir -p "$vault_dir"
    rm -rf "$vault_dir"/*

    "$script_dir/helper_scripts/vault_test_setup.sh" \
        --workdir="$vault_dir" \
        --setup-pxc-mount-points \
        --use-ssl > /dev/null 2>&1

    if [[ ! -f "$config_file" ]]; then
        echo "Error: Vault config file not found at $config_file"
        return 1
    fi

    export vault_url=$(grep 'vault_url' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export secret_mount_point=$(grep 'secret_mount_point' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export token=$(grep 'token' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    export vault_ca=$(grep 'vault_ca' "$config_file" | awk -F '=' '{print $2}' | tr -d '[:space:]')

    echo ".. Vault server started"
}

