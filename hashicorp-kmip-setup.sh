#!/usr/bin/env bash
set -euo pipefail

VERBOSE=false
CERTS_DIR=""  # Initialize as empty

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --cert-dir=*|--certs-dir=*)
            CERTS_DIR="${1#*=}"
            if [[ -z "$CERTS_DIR" ]]; then
                echo "Error: --cert-dir= or --certs-dir= requires a directory path"
                exit 1
            fi
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Base directory under $HOME
VAULT_BASE="${HOME}/vault"
CONFIG_DIR="${VAULT_BASE}/config"
DATA_DIR="${VAULT_BASE}/data"
LOG_DIR="${VAULT_BASE}/log"
CERTS_DIR="${CERTS_DIR:-${VAULT_BASE}/certs}"
VAULT_HCL="${CONFIG_DIR}/vault.hcl"
SCRIPT_DIR="$(pwd)"
VAULT_LICENSE="${SCRIPT_DIR}/vault.hclic"
CONTAINER_NAME="kmip_hashicorp"

# Create all necessary directories, and provide permissions for Docker container access.
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${CERTS_DIR}"
sudo chown -R 100:1000 "${CONFIG_DIR}"
sudo chown -R 100:1000 "${DATA_DIR}"
sudo chown -R 100:1000 "${LOG_DIR}"
sudo chown -R 100:1000 "${CERTS_DIR}"

# Ensure license file exists
echo "[INFO] Checking for license in working directory..."

if [[ ! -f "${VAULT_LICENSE}" ]]; then
    echo "[ERROR] License file 'vault.hclic' not found in:"
    echo "  ${SCRIPT_DIR}"
    echo "[INFO] Please place the license file here and retry"
    exit 1
fi

create_vault_hcl() {
  if [[ -f "${VAULT_HCL}" ]]; then
    echo "[INFO] Vault HCL config already exists at ${VAULT_HCL}"
    return 0
  fi

  echo "[INFO] Creating Vault HCL config at ${VAULT_HCL}"
  cat > "${VAULT_HCL}" <<EOF
# vault.hcl autogenerated
storage "raft" {
  path    = "/vault/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
disable_mlock = true

log_level  = "trace"
log_format = "json"
log_file   = "/vault/log/vault.log"
EOF
}

start_vault_container() {

  local container_status
  container_status=$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)

  case "${container_status}" in
    running)
      echo "[INFO] Vault container already running"
      return 0
      ;;
    exited)
      echo "[INFO] Starting existing Vault container"
      docker start "${CONTAINER_NAME}" >/dev/null
      ;;
    *)
      echo "[INFO] Launching new Vault container"
      docker run -d \
        --name "${CONTAINER_NAME}" \
        -e VAULT_DISABLE_MLOCK=true \
        --cap-add IPC_LOCK \
        -p 8200:8200 \
        -p 8201:8201 \
        -p 5696:5696 \
        -v "${CERTS_DIR}:/vault/certs" \
        -v "${VAULT_HCL}:/vault/config/vault.hcl" \
        -v "${DATA_DIR}:/vault/data" \
        -v "${LOG_DIR}:/vault/log" \
        -e "VAULT_LICENSE=$(<"${VAULT_LICENSE}")" \
        hashicorp/vault-enterprise:latest \
        vault server -config=/vault/config/vault.hcl >/dev/null
      ;;
  esac
  sleep 10
  echo "[INFO] Vault container started"
}

initialize_vault() {
  local init_file="${CERTS_DIR}/init_token.json"

  if [[ -f "${init_file}" ]]; then
    echo "[INFO] Vault already initialized at ${init_file}"
  else
    echo "[INFO] Initializing Vault..."
    docker exec "${CONTAINER_NAME}" apk add --no-cache jq >/dev/null

    docker exec "${CONTAINER_NAME}" sh -c '
      export VAULT_ADDR="http://127.0.0.1:8200"
      vault operator init -format=json > /vault/certs/init_token.json
    ' || {
      echo "[ERROR] Vault initialization failed"
      return 1
    }
    echo "[INFO] Vault initialized."
  fi

  echo "[INFO] Unsealing Vault..."

  for i in {0..2}; do
    local unseal_key
    unseal_key=$(docker exec "${CONTAINER_NAME}" jq -r ".unseal_keys_b64[${i}]" /vault/certs/init_token.json)
    docker exec "${CONTAINER_NAME}" sh -c "export VAULT_ADDR='http://127.0.0.1:8200' && vault operator unseal '${unseal_key}'" >/dev/null || {
      echo "[ERROR] Failed to unseal with key ${i}"
      return 1
    }
  done

  echo "[INFO] Vault unsealed successfully"
}

configure_kmip() {
  local root_token
  root_token=$(docker exec "${CONTAINER_NAME}" \
    jq -rM '.root_token' /vault/certs/init_token.json)

  echo "[INFO] Configuring KMIP secrets engine"
    docker exec "${CONTAINER_NAME}" sh -c "
    export VAULT_ADDR='http://127.0.0.1:8200' VAULT_TOKEN='${root_token}'
    set -e

    if ! vault secrets list | grep -q kmip/; then
      vault secrets enable kmip
    fi

    vault write kmip/config \
      tls_ca_key_type='rsa' \
      tls_ca_key_bits=2048 \
      listen_addrs='0.0.0.0:5696' \
      server_hostnames='172.17.0.1'

    vault read -field=ca_pem kmip/ca > /vault/certs/root_certificate.pem

    # Check if scope exists before creating
    if ! vault list kmip/scope 2>/dev/null | grep -q my-service 2>/dev/null; then
      vault write -f kmip/scope/my-service
    fi

    vault write kmip/scope/my-service/role/admin \
      operation_all=true \
      tls_client_key_bits=2048 \
      tls_client_key_type=rsa \
      tls_client_ttl=24h

    vault write -format=json kmip/scope/my-service/role/admin/credential/generate \
      format=pem > /vault/certs/credential.json

    jq -r '.data.certificate' /vault/certs/credential.json > /vault/certs/client_certificate.pem
    jq -r '.data.private_key' /vault/certs/credential.json > /vault/certs/client_key.pem
    "
}

verify_kmip_connection() {
  echo "[INFO] Verifying KMIP connection..."
  local output
  local timeout=10  # seconds

  # Add timeout and better error handling
  output=$(timeout $timeout openssl s_client -connect 127.0.0.1:5696 \
    -CAfile "${CERTS_DIR}/root_certificate.pem" \
    -cert "${CERTS_DIR}/client_certificate.pem" \
    -key "${CERTS_DIR}/client_key.pem" \
    -showcerts \
    -status \
    < /dev/null 2>&1)

  if ! grep -q -e "Verification: OK" -e "Verify return code: 0" <<< "${output}"; then
    echo "[ERROR] KMIP connection verification failed"
    return 1
  fi
  echo "[INFO] KMIP connection verified successfully"
}

main() {
  create_vault_hcl
  start_vault_container
  initialize_vault
  configure_kmip
  verify_kmip_connection

  echo "[INFO] Vault Enterprise deployment successful"
  if [ "$VERBOSE" = true ]; then
    echo "[INFO] KMIP setup completed successfully!"
    echo "[INFO] Files created within $CERTS_DIR:"
    echo "[INFO]  - Private key: $CERTS_DIR/client_key.pem"
    echo "[INFO]  - Certificate: $CERTS_DIR/client_certificate.pem"
    echo "[INFO]  - CA certificate: $CERTS_DIR/root_certificate.pem"
  fi
}

main "$@"

