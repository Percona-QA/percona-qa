#!/bin/bash

set -e

OPENBAO_VERSION="2.5.4"
BAO_LOG="$RUN_DIR/bao-server.log"

start_openbao_server() {
# -------------------------------
# CONFIGURATION
# -------------------------------
vault_url="http://127.0.0.1:8200"
secret_mount_point="pg_tde"
token_filepath="$RUN_DIR/bao_token_file"

echo "[INFO] Cleaning up any existing OpenBao processes..."
pkill -f "bao server" 2>/dev/null || true
sleep 1   # allow OS to release cluster port 8201 before new server binds it

# -------------------------------
# INSTALL BAO BINARY IF MISSING
# -------------------------------
if ! command -v bao >/dev/null 2>&1; then
    echo "[INFO] bao not found — installing OpenBao ${OPENBAO_VERSION}..."
    # tar.gz arch uses Linux uname convention (x86_64 / arm64)
    ARCH=$(uname -m | sed 's/aarch64/arm64/')
    wget -q "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/bao_${OPENBAO_VERSION}_Linux_${ARCH}.tar.gz" \
        -O /tmp/openbao.tar.gz
    # Install to /usr/local/bin (Debian default PATH) or /usr/bin (RHEL).
    # Prefer /usr/local/bin; callers on RHEL should ensure /usr/local/bin is in PATH.
    tar -xzf /tmp/openbao.tar.gz -C /usr/local/bin bao
    chmod 0755 /usr/local/bin/bao
    rm -f /tmp/openbao.tar.gz
    echo "[INFO] OpenBao ${OPENBAO_VERSION} installed to /usr/local/bin/bao"
fi

# -------------------------------
# START OPENBAO SERVER
# -------------------------------
echo "[INFO] Starting OpenBao server in dev mode..."
bao server -dev > "$BAO_LOG" 2>&1 &

# Wait for the root token to appear in the log (up to 30 s).
# Use grep -a so binary frames in the log don't suppress text matches.
# Use || true so a non-zero grep exit (file absent, no match yet) doesn't
# trip set -euo pipefail in the test subshell.
local deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    ROOT_TOKEN=$(grep -a -m1 "Root Token:" "$BAO_LOG" 2>/dev/null | awk '{print $3}') || true
    [ -n "$ROOT_TOKEN" ] && break
    sleep 1
done

if [[ -z "$ROOT_TOKEN" ]]; then
    echo "[ERROR] Could not extract OpenBao root token!"
    cat "$BAO_LOG"
    exit 1
fi

rm -f "$token_filepath"
echo "$ROOT_TOKEN" > "$token_filepath"

# -------------------------------
# EXPORT ENV VARIABLES
# -------------------------------
export VAULT_ADDR="$vault_url"
export VAULT_TOKEN="$ROOT_TOKEN"

# -------------------------------
# ENABLE SECRET ENGINE
# -------------------------------
echo "[INFO] Enabling KV v2 engine at mount '$secret_mount_point'..."

bao namespace create pg_tde_ns1

export VAULT_NAMESPACE=pg_tde_ns1
bao secrets enable -version=2 -path="$secret_mount_point" kv

echo ""
echo "========================================"
echo " OpenBao Setup Completed Successfully!  "
echo "========================================"
echo ""
}

create_bao_token() {
  local POLICY_NAME=$1
  local POLICY_FILE=$2
  local TOKEN_FILE=$3

  bao policy write "$POLICY_NAME" "$POLICY_FILE"

  TOKEN=$(bao token create -policy="$POLICY_NAME" -no-default-policy -format=json | jq -r .auth.client_token)
  echo "$TOKEN" > "$TOKEN_FILE"
}
