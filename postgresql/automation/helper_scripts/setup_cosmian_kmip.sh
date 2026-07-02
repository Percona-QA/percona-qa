#! /bin/bash

set -e

COSMIAN_CERTS_DIR="$RUN_DIR/cosmian_certs"
COSMIAN_DATA_DIR="$RUN_DIR/cosmian_data"
COSMIAN_CONFIG="$RUN_DIR/cosmian_kms.toml"
COSMIAN_LOG="$RUN_DIR/cosmian_kms.log"

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

detect_arch() {
  local uname_arch
  uname_arch=$(uname -m)

  case "$uname_arch" in
      x86_64|amd64)
          COSMIAN_DEB_ARCH="amd64"
          COSMIAN_RPM_DIR="amd64"
          COSMIAN_RPM_FILE_ARCH="x86_64"
          ;;
      aarch64|arm64)
          COSMIAN_DEB_ARCH="arm64"
          COSMIAN_RPM_DIR="arm64"
          COSMIAN_RPM_FILE_ARCH="aarch64"
          ;;
      *)
          echo "[ERROR] Unsupported architecture: $uname_arch"
          return 1
          ;;
  esac
}

install_cosmian_kms() {
  local VERSION=$1

  echo "[INFO] Installing Cosmian KMS ${VERSION}"
  detect_arch

  if command -v apt >/dev/null 2>&1; then
    # Debian / Ubuntu
    local PKG="cosmian-kms-server-non-fips-static-openssl_${VERSION}_${COSMIAN_DEB_ARCH}.deb"
    local URL="https://package.cosmian.com/kms/${VERSION}/deb/${COSMIAN_DEB_ARCH}/non-fips/static/${PKG}"

    echo "[INFO] Downloading Cosmian package:"
    echo "       $URL"
    wget -q -O "$RUN_DIR/${PKG}" "${URL}" || {
      echo "[ERROR] Failed to download ${URL}"
      return 1
    }

    sudo apt-get update -qq
    sudo apt-get install -y "$RUN_DIR/${PKG}" || return 1

  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # RHEL / Rocky / Alma / Oracle Linux
    local PKG="cosmian-kms-server-non-fips-static-openssl_${VERSION}_${COSMIAN_RPM_FILE_ARCH}.rpm"
    local URL="https://package.cosmian.com/kms/${VERSION}/rpm/${COSMIAN_RPM_DIR}/non-fips/static/${PKG}"

    echo "[INFO] Downloading Cosmian package:"
    echo "       $URL"

    wget -q -O "$RUN_DIR/${PKG}" "${URL}" || {
      echo "[ERROR] Failed to download ${URL}"
      return 1
    }

    if command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y "${RUN_DIR}/${PKG}" || return 1
    else
      sudo yum install -y "${RUN_DIR}/${PKG}" || return 1
    fi

  else
    echo "[ERROR] Unsupported package manager"
    return 1
  fi

  # Cosmian packages install some files with root-only permissions.
  # Fix permissions so tests can launch cosmian_kms as a regular user.
  [ -f /usr/sbin/cosmian_kms ] && \
    sudo chmod 755 /usr/sbin/cosmian_kms

  [ -f /usr/local/cosmian/lib/ossl-modules/legacy.so ] && \
    sudo chmod 755 /usr/local/cosmian/lib/ossl-modules/legacy.so

  echo "[INFO] Cosmian KMS installed successfully"
  verify_cosmian_kms
}

verify_cosmian_kms() {
  local output
  if ! output=$(cosmian_kms --version 2>&1); then
    echo "$output"
    if echo "$output" | grep -q "GLIBC_"; then
        echo "[ERROR] Cosmian KMS requires a newer glibc version."
    else
        echo "[ERROR] cosmian_kms failed to execute."
    fi

    return 1
  fi
}

start_cosmian_kmip_server() {
  if command -v cosmian_kms >/dev/null 2>&1; then
    verify_cosmian_kms
    echo "[INFO] Found Cosmian KMS: $(cosmian_kms --version)"
  else
    install_cosmian_kms 5.16.2
  fi

  # Kill any previously running cosmian KMIP server
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
    return 1
  fi

  kmip_server_address="127.0.0.1"
  kmip_server_port=5556
  kmip_client_ca="${COSMIAN_CERTS_DIR}/client.pem"
  kmip_client_key="${COSMIAN_CERTS_DIR}/client.key"
  kmip_server_ca="${COSMIAN_CERTS_DIR}/ca.pem"
}
