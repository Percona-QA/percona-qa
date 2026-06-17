#! /bin/bash

set -e

COSMIAN_CERTS_DIR="/tmp/cosmian_certs"
COSMIAN_DATA_DIR="/tmp/cosmian_data"
COSMIAN_CONFIG="/tmp/cosmian_kms.toml"
COSMIAN_LOG="/tmp/cosmian_kms.log"

_gen_cosmian_certs() {
  local DIR="$COSMIAN_CERTS_DIR"
  mkdir -p "$DIR"

  # CA
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$DIR/ca.key" -out "$DIR/ca.pem" \
    -subj '/CN=pg_tde-test-ca'

  # Server CSR + cert (SAN required by cosmian_kms TLS)
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$DIR/server.key" -out "$DIR/server.csr" \
    -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1'
  openssl x509 -req -in "$DIR/server.csr" \
    -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" -CAcreateserial \
    -days 1 -out "$DIR/server.pem" -copy_extensions copy

  # Server PKCS#12 bundle (password: test)
  openssl pkcs12 -export \
    -out "$DIR/server.p12" -inkey "$DIR/server.key" -in "$DIR/server.pem" \
    -password pass:test

  # Client CSR + cert
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$DIR/client.key" -out "$DIR/client.csr" \
    -subj '/CN=pg_tde-client'
  openssl x509 -req -in "$DIR/client.csr" \
    -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" -CAcreateserial \
    -days 1 -out "$DIR/client.pem"
}

start_kmip_server() {
  # On old-glibc platforms (RHEL/Rocky/OL 8, Debian 11) the cosmian_kms binary is
  # not available; Ansible pre-starts it inside a Docker container and writes certs
  # to /tmp/cosmian_certs/ via a volume mount.  Use binary availability as the
  # authoritative check — never rely on the certs directory, which may be left over
  # from a previous native run and would cause a false Docker detection.
  if ! command -v cosmian_kms >/dev/null 2>&1; then
    echo "[INFO] cosmian_kms binary not found — assuming Docker container (old-glibc platform)"
    if [ ! -f "$COSMIAN_CERTS_DIR/ca.pem" ]; then
      echo "[ERROR] Expected Docker certs at $COSMIAN_CERTS_DIR but ca.pem not found"
      exit 1
    fi
    kmip_server_address="127.0.0.1"
    kmip_server_port=5556
    kmip_client_ca="${COSMIAN_CERTS_DIR}/client.pem"
    kmip_client_key="${COSMIAN_CERTS_DIR}/client.key"
    kmip_server_ca="${COSMIAN_CERTS_DIR}/ca.pem"
    return
  fi

  # Native binary available — always do a full restart so each test gets a clean DB.
  pkill -9 -f cosmian_kms 2>/dev/null || true
  sleep 1

  echo "[INFO] Generating Cosmian KMS certificates..."
  rm -rf "$COSMIAN_CERTS_DIR"
  _gen_cosmian_certs

  mkdir -p "$COSMIAN_DATA_DIR"

  cat > "$COSMIAN_CONFIG" <<EOF
default_username = "admin"

[db]
database_type = "sqlite"
sqlite_path = "${COSMIAN_DATA_DIR}/db"
clear_database = true

[tls]
tls_p12_file         = "${COSMIAN_CERTS_DIR}/server.p12"
tls_p12_password     = "test"
clients_ca_cert_file = "${COSMIAN_CERTS_DIR}/ca.pem"

[socket_server]
socket_server_start    = true
socket_server_port     = 5556
socket_server_hostname = "127.0.0.1"

[http]
port     = 9998
hostname = "127.0.0.1"

[logging]
rust_log = "info,cosmian_kms=info"
EOF

  echo "[INFO] Starting Cosmian KMS server..."
  cosmian_kms -c "$COSMIAN_CONFIG" > "$COSMIAN_LOG" 2>&1 &

  # Wait until the KMIP port is ready (up to 30 s).
  # Use bash /dev/tcp instead of nc — nc/netcat is not reliably present across distros.
  _kmip_port_open() { (echo > /dev/tcp/127.0.0.1/5556) 2>/dev/null; }
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if _kmip_port_open; then
      echo "[INFO] Cosmian KMS is ready on port 5556"
      break
    fi
    sleep 1
  done

  if ! _kmip_port_open; then
    echo "[ERROR] Cosmian KMS did not start within 30 seconds"
    cat "$COSMIAN_LOG"
    exit 1
  fi

  kmip_server_address="127.0.0.1"
  kmip_server_port=5556
  kmip_client_ca="${COSMIAN_CERTS_DIR}/client.pem"
  kmip_client_key="${COSMIAN_CERTS_DIR}/client.key"
  kmip_server_ca="${COSMIAN_CERTS_DIR}/ca.pem"
}
