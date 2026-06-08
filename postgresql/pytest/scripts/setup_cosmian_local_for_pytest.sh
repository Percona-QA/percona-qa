#!/usr/bin/env bash
# Start local cosmian_kms for pytest — mirrors pg_tde t/CosmianKms.pm + t/kmip.pl.
#
# Requires cosmian_kms on PATH (pg_tde ci_scripts/ubuntu-deps.sh installs v5.21.0).
#
# Usage:
#   cd postgresql/pytest
#   source scripts/setup_cosmian_local_for_pytest.sh
#   ./scripts/run_kmip_revalidation.sh
#
# Override binary: export COSMIAN_KMS_BIN=/usr/sbin/cosmian_kms
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

_find_cosmian_kms() {
    if [[ -n "${COSMIAN_KMS_BIN:-}" && -x "${COSMIAN_KMS_BIN}" ]]; then
        echo "${COSMIAN_KMS_BIN}"
        return 0
    fi
    local candidate
    for candidate in /usr/sbin/cosmian_kms /usr/local/bin/cosmian_kms cosmian_kms; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

_cosmian_cleanup() {
    if [[ -n "${COSMIAN_KMS_PID:-}" ]] && kill -0 "${COSMIAN_KMS_PID}" 2>/dev/null; then
        kill "${COSMIAN_KMS_PID}" 2>/dev/null || true
        wait "${COSMIAN_KMS_PID}" 2>/dev/null || true
    fi
}

COSMIAN_BIN="$(_find_cosmian_kms)" || {
    echo "ERROR: cosmian_kms not found. Install like pg_tde CI:" >&2
    echo "  see pg_tde/ci_scripts/ubuntu-deps.sh (Cosmian KMS section)" >&2
    echo "  or: export COSMIAN_KMS_BIN=/path/to/cosmian_kms" >&2
    return 1 2>/dev/null || exit 1
}

RUN_DIR="${COSMIAN_PYTEST_RUN_DIR:-/tmp/pg_tde_pytest_cosmian_local}"
mkdir -p "${RUN_DIR}"
trap _cosmian_cleanup EXIT INT TERM

KMIP_PORT="$(_free_port)"
HTTP_PORT="$(_free_port)"

# TLS material — same layout as t/CosmianKms.pm::gen_certs
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "${RUN_DIR}/ca.key" -out "${RUN_DIR}/ca.pem" \
    -subj '/CN=pg_tde-test-ca' 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
    -keyout "${RUN_DIR}/server.key" -out "${RUN_DIR}/server.csr" \
    -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' 2>/dev/null
openssl x509 -req -in "${RUN_DIR}/server.csr" -CA "${RUN_DIR}/ca.pem" \
    -CAkey "${RUN_DIR}/ca.key" -CAcreateserial -days 1 \
    -out "${RUN_DIR}/server.pem" -copy_extensions copy 2>/dev/null
openssl pkcs12 -export -out "${RUN_DIR}/server.p12" \
    -inkey "${RUN_DIR}/server.key" -in "${RUN_DIR}/server.pem" \
    -password pass:test 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
    -keyout "${RUN_DIR}/client.key" -out "${RUN_DIR}/client.csr" \
    -subj '/CN=pg_tde-client' 2>/dev/null
openssl x509 -req -in "${RUN_DIR}/client.csr" -CA "${RUN_DIR}/ca.pem" \
    -CAkey "${RUN_DIR}/ca.key" -CAcreateserial -days 1 \
    -out "${RUN_DIR}/client.pem" 2>/dev/null

cat > "${RUN_DIR}/kms.toml" <<EOF
default_username = "admin"

[db]
database_type = "sqlite"
sqlite_path   = "${RUN_DIR}/db"
clear_database = true

[tls]
tls_p12_file         = "${RUN_DIR}/server.p12"
tls_p12_password     = "test"
clients_ca_cert_file = "${RUN_DIR}/ca.pem"

[socket_server]
socket_server_start    = true
socket_server_port     = ${KMIP_PORT}
socket_server_hostname = "127.0.0.1"

[http]
port     = ${HTTP_PORT}
hostname = "127.0.0.1"

[logging]
rust_log = "info,cosmian_kms=info"
EOF

if [[ -z "${OPENSSL_MODULES:-}" ]]; then
    for d in /usr/local/cosmian/lib/ossl-modules \
             /usr/lib64/ossl-modules \
             /usr/lib/x86_64-linux-gnu/ossl-modules \
             /usr/lib/aarch64-linux-gnu/ossl-modules; do
        if [[ -d "${d}" ]]; then
            export OPENSSL_MODULES="${d}"
            break
        fi
    done
fi

"${COSMIAN_BIN}" -c "${RUN_DIR}/kms.toml" >/dev/null 2>"${RUN_DIR}/kms.stderr" &
COSMIAN_KMS_PID=$!

deadline=$((SECONDS + 15))
while (( SECONDS < deadline )); do
    if curl -fsSk -m 1 "https://127.0.0.1:${HTTP_PORT}/version" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${COSMIAN_KMS_PID}" 2>/dev/null; then
        echo "ERROR: cosmian_kms exited early. stderr:" >&2
        cat "${RUN_DIR}/kms.stderr" >&2
        return 1 2>/dev/null || exit 1
    fi
    sleep 0.2
done

if ! curl -fsSk -m 1 "https://127.0.0.1:${HTTP_PORT}/version" >/dev/null 2>&1; then
    echo "ERROR: cosmian_kms readiness timed out (kmip=${KMIP_PORT} http=${HTTP_PORT})" >&2
    cat "${RUN_DIR}/kms.stderr" >&2
    return 1 2>/dev/null || exit 1
fi

export KMIP_SERVER_ADDRESS=127.0.0.1
export KMIP_SERVER_PORT="${KMIP_PORT}"
export KMIP_CLIENT_CA="${RUN_DIR}/client.pem"
export KMIP_CLIENT_KEY="${RUN_DIR}/client.key"
export KMIP_SERVER_CA="${RUN_DIR}/ca.pem"

export KMIP_COSMIAN_HOST="${KMIP_SERVER_ADDRESS}"
export KMIP_COSMIAN_PORT="${KMIP_SERVER_PORT}"
export KMIP_COSMIAN_CLIENT_CERT="${KMIP_CLIENT_CA}"
export KMIP_COSMIAN_CLIENT_KEY="${KMIP_CLIENT_KEY}"
export KMIP_COSMIAN_SERVER_CA="${KMIP_SERVER_CA}"

export KMIP_REVALIDATE_PROFILES="${KMIP_REVALIDATE_PROFILES:-cosmian}"
export COSMIAN_PYTEST_RUN_DIR="${RUN_DIR}"

echo "Local Cosmian KMS (pg_tde t/kmip.pl parity):"
echo "  cosmian_kms=${COSMIAN_BIN} pid=${COSMIAN_KMS_PID}"
echo "  KMIP_SERVER_ADDRESS=${KMIP_SERVER_ADDRESS}"
echo "  KMIP_SERVER_PORT=${KMIP_SERVER_PORT}"
echo "  certs under ${RUN_DIR}"
echo "  KMIP_REVALIDATE_PROFILES=${KMIP_REVALIDATE_PROFILES}"
echo ""
echo "Run: ./scripts/run_kmip_revalidation.sh"
echo "Note: cosmian_kms stops when this shell exits (trap cleanup)."
