#!/usr/bin/env bash
# Start the Docker KMIP test server and export env vars for pytest.
#
# Usage:
#   cd postgresql/pytest
#   source scripts/setup_kmip_for_pytest.sh
#   pytest tests/test_kmip.py -v
#
# If KMIP_* is already set and the server is reachable, Docker is not used.
# Mirrors postgresql/automation/helper_scripts/setup_kmip.sh (bash suite).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

AUTOMATION_KMIP="${SCRIPT_DIR}/../../automation/helper_scripts/setup_kmip.sh"

if kmip_pytest_env_ready; then
    kmip_export_standard_env
    echo "KMIP pytest environment (existing server; Docker not used):"
    echo "  KMIP_SERVER_ADDRESS=${KMIP_SERVER_ADDRESS}"
    echo "  KMIP_SERVER_PORT=${KMIP_SERVER_PORT}"
    echo "  KMIP_CLIENT_CA=${KMIP_CLIENT_CA}"
    echo "  KMIP_CLIENT_KEY=${KMIP_CLIENT_KEY}"
    echo "  KMIP_SERVER_CA=${KMIP_SERVER_CA}"
    echo ""
    echo "Run: pytest tests/test_kmip.py -v"
    return 0 2>/dev/null || exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    kmip_docker_missing_message >&2
    return 1 2>/dev/null || exit 1
fi

if [[ ! -f "${AUTOMATION_KMIP}" ]]; then
    echo "ERROR: ${AUTOMATION_KMIP} not found" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck source=/dev/null
source "${AUTOMATION_KMIP}"
start_kmip_server

export KMIP_SERVER_ADDRESS="${kmip_server_address:-127.0.0.1}"
export KMIP_SERVER_PORT="${kmip_server_port:-5696}"
export KMIP_CLIENT_CA="${kmip_client_ca}"
export KMIP_CLIENT_KEY="${kmip_client_key}"
export KMIP_SERVER_CA="${kmip_server_ca:-}"

echo "KMIP pytest environment (Docker mohitpercona/kmip):"
echo "  KMIP_SERVER_ADDRESS=${KMIP_SERVER_ADDRESS}"
echo "  KMIP_SERVER_PORT=${KMIP_SERVER_PORT}"
echo "  KMIP_CLIENT_CA=${KMIP_CLIENT_CA}"
echo "  KMIP_CLIENT_KEY=${KMIP_CLIENT_KEY}"
echo "  KMIP_SERVER_CA=${KMIP_SERVER_CA}"
echo ""
echo "Run: pytest tests/test_kmip.py -v"
