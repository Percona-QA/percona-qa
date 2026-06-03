#!/usr/bin/env bash
# Start the Docker KMIP test server and export env vars for pytest.
#
# Usage:
#   cd postgresql/pytest
#   source scripts/setup_kmip_for_pytest.sh
#   pytest tests/test_kmip.py -v
#
# If KMIP_* is already set and the server is reachable, Docker is not used.
# If container 'kmip' is already running, certs are copied and env is exported.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

_kmip_setup_finish() {
    kmip_export_docker_pytest_env
    if ! kmip_pytest_env_ready; then
        echo "ERROR: KMIP server not reachable after setup" >&2
        echo "  host=$(kmip_connect_host) port=${KMIP_SERVER_PORT}" >&2
        return 1 2>/dev/null || exit 1
    fi
    kmip_print_pytest_env "${1:-KMIP pytest environment}"
    return 0 2>/dev/null || exit 0
}

if kmip_pytest_env_ready; then
    kmip_export_standard_env
    kmip_print_pytest_env "KMIP pytest environment (existing; Docker not used)"
    return 0 2>/dev/null || exit 0
fi

if kmip_try_bootstrap_from_running_container; then
    kmip_print_pytest_env "KMIP pytest environment (reusing running container 'kmip')"
    return 0 2>/dev/null || exit 0
fi

if ! command -v docker >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
    kmip_docker_missing_message >&2
    return 1 2>/dev/null || exit 1
fi

if ! kmip_docker info >/dev/null 2>&1; then
    kmip_docker_missing_message >&2
    return 1 2>/dev/null || exit 1
fi

# Remove stale stopped container so 'docker run --name kmip' succeeds.
while kmip_docker ps -aq -f name=^kmip$ 2>/dev/null | grep -q .; do
    echo "Removing existing container 'kmip'..."
    kmip_docker rm -f kmip >/dev/null 2>&1 || true
    sleep 1
done

if pgrep -f '[k]mip' >/dev/null 2>&1; then
    sudo pkill -9 -f kmip 2>/dev/null || true
fi

echo "Starting KMIP Docker image (mohitpercona/kmip:latest)..."
kmip_docker run -d \
    --security-opt seccomp=unconfined \
    --cap-add=NET_ADMIN \
    --rm \
    -p 5696:5696 \
    --name kmip \
    mohitpercona/kmip:latest

mkdir -p "${KMIP_DEFAULT_CERT_DIR}"
kmip_refresh_certs_from_container

export KMIP_SERVER_ADDRESS="127.0.0.1"
export KMIP_SERVER_PORT="5696"
export KMIP_CLIENT_CA="${KMIP_DEFAULT_CLIENT_CERT}"
export KMIP_CLIENT_KEY="${KMIP_DEFAULT_CLIENT_KEY}"
export KMIP_SERVER_CA="${KMIP_DEFAULT_SERVER_CA}"

echo "Waiting for KMIP server (30s)..."
sleep 30

_kmip_setup_finish "KMIP pytest environment (Docker mohitpercona/kmip)"
