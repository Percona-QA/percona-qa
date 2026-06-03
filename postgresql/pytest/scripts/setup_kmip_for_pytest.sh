#!/usr/bin/env bash
# Start the Docker KMIP test server and export env vars for pytest.
#
# Usage:
#   cd postgresql/pytest
#   source scripts/setup_kmip_for_pytest.sh
#   pytest tests/test_kmip.py -v
#
# Mirrors postgresql/automation/helper_scripts/setup_kmip.sh (bash suite).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATION_KMIP="${SCRIPT_DIR}/../../automation/helper_scripts/setup_kmip.sh"

if [[ ! -f "${AUTOMATION_KMIP}" ]]; then
    echo "ERROR: ${AUTOMATION_KMIP} not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${AUTOMATION_KMIP}"
start_kmip_server

export KMIP_SERVER_ADDRESS="${kmip_server_address:-127.0.0.1}"
export KMIP_SERVER_PORT="${kmip_server_port:-5696}"
export KMIP_CLIENT_CA="${kmip_client_ca}"
export KMIP_CLIENT_KEY="${kmip_client_key}"
export KMIP_SERVER_CA="${kmip_server_ca:-}"

echo "KMIP pytest environment:"
echo "  KMIP_SERVER_ADDRESS=${KMIP_SERVER_ADDRESS}"
echo "  KMIP_SERVER_PORT=${KMIP_SERVER_PORT}"
echo "  KMIP_CLIENT_CA=${KMIP_CLIENT_CA}"
echo "  KMIP_CLIENT_KEY=${KMIP_CLIENT_KEY}"
echo "  KMIP_SERVER_CA=${KMIP_SERVER_CA}"
echo ""
echo "Run: pytest tests/test_kmip.py -v"
