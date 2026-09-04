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
# Robust download: -f makes curl fail on HTTP errors instead of saving the
# error/rate-limit HTML page as the tarball (which then fails with "not in gzip
# format"). GitHub throttles unauthenticated parallel downloads, so retry and
# verify the archive is a valid gzip before accepting it.
download_ok=false
for attempt in 1 2 3 4 5; do
    if curl -fSL --retry 3 --retry-delay 5 "$OPENBAO_URL" -o "$TARBALL" \
       && tar -tzf "$TARBALL" >/dev/null 2>&1; then
        download_ok=true
        break
    fi
    echo "[WARN] OpenBao download/verify failed (attempt $attempt; got $(stat -c%s "$TARBALL" 2>/dev/null || echo 0) bytes); retrying..."
    sleep 10
done
if [ "$download_ok" != true ]; then
    echo "[ERROR] Could not download a valid OpenBao tarball from $OPENBAO_URL"
    exit 1
fi

echo "[INFO] Extracting..."
tar -xzf "$TARBALL" -C "$RUN_DIR"
NAME=$(basename "$TARBALL" | sed 's/\.tar\.gz$//')

cd "$RUN_DIR/$NAME"

# -------------------------------
# BUILD OPENBAO
# -------------------------------
echo "[INFO] Building OpenBao..."
git init -q
git add . -A >/dev/null 2>&1
git -c user.name="CI Builder" -c user.email="ci-builder@example.com" commit --allow-empty -q -m "imported source"
make

# -------------------------------
# START OPENBAO SERVER
# -------------------------------
echo "[INFO] Starting OpenBao server in dev mode..."

# run in background and capture output
./bin/bao server -dev > bao_server.log 2>&1 &

sleep 3

# -------------------------------
# EXTRACT ROOT TOKEN
# -------------------------------
ROOT_TOKEN=$(grep -m1 "Root Token:" bao_server.log | awk '{print $3}')

if [[ -z "$ROOT_TOKEN" ]]; then
    echo "[ERROR] Could not extract root token!"
    exit 1
fi

if [ -f $token_filepath ]; then
  rm -f $token_filepath
fi

echo "$ROOT_TOKEN" > $token_filepath

# -------------------------------
# EXPORT ENV VARIABLES
# -------------------------------
export VAULT_ADDR="$vault_url"
export VAULT_TOKEN="$ROOT_TOKEN"


# -------------------------------
# ENABLE SECRET ENGINE
# -------------------------------
echo "[INFO] Enabling KV v2 engine at mount '$secret_mount_point'..."

./bin/bao namespace create pg_tde_ns1

export VAULT_NAMESPACE=pg_tde_ns1
./bin/bao secrets enable -version=2 -path="$secret_mount_point" kv

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
  local POLICY_NAME=$1
  local POLICY_FILE=$2
  local TOKEN_FILE=$3

  ./bin/bao policy write "$POLICY_NAME" "$POLICY_FILE"

  TOKEN=$(./bin/bao token create -policy="$POLICY_NAME" -no-default-policy -format=json | jq -r .auth.client_token)
  echo "$TOKEN" > "$TOKEN_FILE"
}
