#!/bin/bash

# setup_vault.sh — compatibility shim over OpenBao.
#
# Tests call start_vault_server() and consume $vault_url, $secret_mount_point,
# $token_file, and $vault_ca.  HashiCorp Vault is no longer installed; OpenBao
# (already set up by setup_openbao.sh) provides the same KV v2 API at the same
# address.  This file wires the old variable names to the OpenBao equivalents.

set -e

start_vault_server() {
    # Delegate to OpenBao (sourced via test_runner.sh before this file).
    start_openbao_server

    # Export the variable names that vault-using tests expect.
    export vault_url="http://127.0.0.1:8200"
    export secret_mount_point="pg_tde"
    export token_file="$token_filepath"   # token_filepath is set by start_openbao_server
    export token="$ROOT_TOKEN"
    export vault_ca=""                    # OpenBao dev mode has no TLS

    echo ".. Vault server started (via OpenBao)"
}

create_token() {
    local POLICY_NAME=$1
    local POLICY_FILE=$2
    local TOKEN_FILE=$3

    # Delegate to the OpenBao token creation helper.
    create_bao_token "$POLICY_NAME" "$POLICY_FILE" "$TOKEN_FILE"
}
