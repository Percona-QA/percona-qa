#!/bin/bash

set -e 

start_openbao_server() {
# -------------------------------
# CONFIGURATION
# -------------------------------
OPENBAO_URL="https://github.com/openbao/openbao/archive/refs/tags/v2.5.0-beta20251125.tar.gz"
TARBALL="$RUN_DIR/openbao-2.5.0-beta20251125.tar.gz"

vault_url="http://127.0.0.1:8200"
secret_mount_point="pg_tde"
token_filepath="$RUN_DIR/bao_token_file"

echo "[INFO] Cleaning up any existing OpenBao processes..."

# Kill any running bao server
pkill -f "bao server" 2>/dev/null || true

# -------------------------------
# CHECK GO VERSION
# -------------------------------
echo "[INFO] Checking Go version..."

if ! command -v go >/dev/null 2>&1; then
    echo "[ERROR] Go is not installed. Install Go >= 1.25.4"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
REQUIRED="1.25.4"

if printf '%s\n%s\n' "$REQUIRED" "$GO_VERSION" | sort -V | head -n1 | grep -qv "$REQUIRED"; then
    echo "[ERROR] Go version $GO_VERSION is too old. Need >= $REQUIRED"
    exit 1
fi

echo "[INFO] Go version OK: $GO_VERSION"

# -------------------------------
# DOWNLOAD OPENBAO
# -------------------------------
echo "[INFO] Downloading OpenBao..."
curl -L "$OPENBAO_URL" -o "$TARBALL"

echo "[INFO] Extracting..."
tar -xzf "$TARBALL" -C "$RUN_DIR"
NAME=$(basename "$TARBALL" | sed 's/\.tar\.gz$//')

pushd "$RUN_DIR/$NAME" >/dev/null || exit 1

# -------------------------------
# BUILD OPENBAO
# -------------------------------
echo "[INFO] Building OpenBao..."
git init -q
git add . -A >/dev/null 2>&1
git -c user.name="CI Builder" -c user.email="ci-builder@example.com" commit --allow-empty -q -m "imported source"
make

export BAO_BIN="$RUN_DIR/$NAME/bin/bao"
# -------------------------------
# START OPENBAO SERVER
# -------------------------------
echo "[INFO] Starting OpenBao server in dev mode..."

# run in background and capture output
$BAO_BIN server -dev > bao_server.log 2>&1 &

sleep 3

# -------------------------------
# EXTRACT ROOT TOKEN
# -------------------------------
ROOT_TOKEN=$(grep -m1 "Root Token:" bao_server.log | awk '{print $3}')

if [[ -z "$ROOT_TOKEN" ]]; then
    echo "[ERROR] Could not extract root token!"
    exit 1
fi

if [ -f "$token_filepath" ]; then
  rm -f "$token_filepath"
fi

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

$BAO_BIN namespace create pg_tde_ns1

export VAULT_NAMESPACE=pg_tde_ns1
$BAO_BIN secrets enable -version=2 -path="$secret_mount_point" kv

popd >/dev/null

echo ""
echo "========================================"
echo " OpenBao Setup Completed Successfully!  "
echo "========================================"
#echo "Vault URL:             $vault_url"
#echo "Secret Mount Point:    $secret_mount_point"
#echo "Root Token:            $ROOT_TOKEN"
#echo "Root Token:            $ROOT_TOKEN"
echo ""
}

create_bao_token() {
  local POLICY_NAME="$1"
  local POLICY_FILE="$2"
  local TOKEN_FILE="$3"

  # -------------------------------
  # VALIDATIONS
  # -------------------------------
  if [[ -z "$BAO_BIN" || ! -x "$BAO_BIN" ]]; then
    echo "[ERROR] BAO_BIN is not set or not executable"
    exit 1
  fi

  if [[ ! -f "$POLICY_FILE" ]]; then
    echo "[ERROR] Policy file not found: $POLICY_FILE"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required but not installed"
    exit 1
  fi

  # -------------------------------
  # WRITE POLICY
  # -------------------------------
  echo "[INFO] Writing policy: $POLICY_NAME"
  "$BAO_BIN" policy write "$POLICY_NAME" "$POLICY_FILE"

  # -------------------------------
  # CREATE TOKEN
  # -------------------------------
  echo "[INFO] Creating token for policy: $POLICY_NAME"

  local TOKEN
  TOKEN=$("$BAO_BIN" token create \
    -policy="$POLICY_NAME" \
    -no-default-policy \
    -format=json | jq -r '.auth.client_token')

  # -------------------------------
  # VALIDATE TOKEN
  # -------------------------------
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "[ERROR] Failed to generate token"
    exit 1
  fi

  # -------------------------------
  # SAVE TOKEN
  # -------------------------------
  echo "$TOKEN" > "$TOKEN_FILE"

  echo "[INFO] Token successfully created at $TOKEN_FILE"
}
