#! /bin/bash

set -e

COSMIAN_IMAGE="mohitpercona/cosmian-kms:5.16.2"
COSMIAN_CONTAINER="cosmian-kms"

COSMIAN_CERTS_DIR="$RUN_DIR/cosmian_certs"
COSMIAN_DATA_DIR="$RUN_DIR/cosmian_data"
COSMIAN_CONFIG="$RUN_DIR/cosmian_kms.toml"
COSMIAN_LOG="$RUN_DIR/cosmian_kms.log"

_gen_cosmian_certs() {
    local DIR="$COSMIAN_CERTS_DIR"

    mkdir -p "$DIR"

    # CA
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$DIR/ca.key" \
        -out "$DIR/ca.pem" \
        -subj "/CN=pg_tde-test-ca"

    # Server certificate
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$DIR/server.key" \
        -out "$DIR/server.csr" \
        -subj "/CN=127.0.0.1" \
        -addext "subjectAltName=IP:127.0.0.1"

    openssl x509 -req \
        -in "$DIR/server.csr" \
        -CA "$DIR/ca.pem" \
        -CAkey "$DIR/ca.key" \
        -CAcreateserial \
        -days 1 \
        -out "$DIR/server.pem" \
        -copy_extensions copy

    openssl pkcs12 -export \
        -out "$DIR/server.p12" \
        -inkey "$DIR/server.key" \
        -in "$DIR/server.pem" \
        -password pass:test

    # Client certificate
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$DIR/client.key" \
        -out "$DIR/client.csr" \
        -subj "/CN=pg_tde-client"

    openssl x509 -req \
        -in "$DIR/client.csr" \
        -CA "$DIR/ca.pem" \
        -CAkey "$DIR/ca.key" \
        -CAcreateserial \
        -days 1 \
        -out "$DIR/client.pem"
}

start_cosmian_kmip_server() {

    if ! command -v docker >/dev/null 2>&1; then
        echo "[ERROR] Docker is not installed"
        return 1
    fi

    echo "[INFO] Pulling Cosmian image..."
    docker pull "$COSMIAN_IMAGE"

    echo "[INFO] Cleaning up previous Cosmian container..."
    docker rm -f "$COSMIAN_CONTAINER" >/dev/null 2>&1 || true
    sudo pkill -9 -f '[c]osmian_kms' 2>/dev/null || true

    sudo rm -rf "$COSMIAN_CERTS_DIR"
    sudo rm -rf "$COSMIAN_DATA_DIR"

    mkdir -p "$COSMIAN_DATA_DIR"

    echo "[INFO] Generating certificates..."
    _gen_cosmian_certs

    cat >"$COSMIAN_CONFIG" <<EOF
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
socket_server_hostname = "127.0.0.1"
socket_server_port     = 5556

[http]
hostname = "127.0.0.1"
port = 9998

[logging]
rust_log = "info,cosmian_kms=info"
EOF

    echo "[INFO] Starting Cosmian container..."

    docker run -d \
        --name "$COSMIAN_CONTAINER" \
        --network host \
        -v "$RUN_DIR:$RUN_DIR" \
        "$COSMIAN_IMAGE" \
        -c "$COSMIAN_CONFIG"

    echo "[INFO] Waiting for KMIP server..."

    _kmip_port_open() {
        (echo >/dev/tcp/127.0.0.1/5556) 2>/dev/null
    }

    local deadline=$(( $(date +%s) + 30 ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if _kmip_port_open; then
            echo "[INFO] Cosmian KMIP server is ready"
            break
        fi
        sleep 1
    done

    if ! _kmip_port_open; then
        echo "[ERROR] Cosmian failed to start."

        docker logs "$COSMIAN_CONTAINER"

        return 1
    fi

    kmip_server_address="127.0.0.1"
    kmip_server_port=5556
    kmip_client_ca="${COSMIAN_CERTS_DIR}/client.pem"
    kmip_client_key="${COSMIAN_CERTS_DIR}/client.key"
    kmip_server_ca="${COSMIAN_CERTS_DIR}/ca.pem"
}

stop_cosmian_kmip_server() {

    sudo docker rm -f "$COSMIAN_CONTAINER" >/dev/null 2>&1 || true
}
