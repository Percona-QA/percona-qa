#!/usr/bin/env bash
# Shared KMIP env checks for pytest helper scripts.
# Sourced by setup_kmip_for_pytest.sh and run_kmip_revalidation.sh (do not execute).

# Default paths from mohitpercona/kmip Docker image (setup_kmip.sh).
KMIP_DEFAULT_CERT_DIR="${KMIP_DEFAULT_CERT_DIR:-/tmp/certs}"
KMIP_DEFAULT_CLIENT_CERT="${KMIP_DEFAULT_CERT_DIR}/client_certificate_jane_doe.pem"
KMIP_DEFAULT_CLIENT_KEY="${KMIP_DEFAULT_CERT_DIR}/client_key_jane_doe.pem"
KMIP_DEFAULT_SERVER_CA="${KMIP_DEFAULT_CERT_DIR}/root_certificate.pem"

kmip_connect_host() {
    local h="${KMIP_SERVER_ADDRESS:-127.0.0.1}"
    if [[ "$h" == "0.0.0.0" || -z "$h" ]]; then
        h="127.0.0.1"
    fi
    echo "$h"
}

kmip_certs_present() {
    [[ -n "${KMIP_CLIENT_CA:-}" && -n "${KMIP_CLIENT_KEY:-}" ]] \
        && [[ -f "${KMIP_CLIENT_CA}" && -f "${KMIP_CLIENT_KEY}" ]]
}

kmip_server_reachable() {
    local host="${1:-$(kmip_connect_host)}"
    local port="${2:-${KMIP_SERVER_PORT:-5696}}"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$host" "$port" 2>/dev/null
        return
    fi
    timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# Run docker with passwordless sudo when the user is not in the docker group.
kmip_docker() {
    if [[ -n "${KMIP_DOCKER:-}" ]]; then
        # shellcheck disable=SC2086
        ${KMIP_DOCKER} "$@"
        return $?
    fi
    if docker info >/dev/null 2>&1; then
        docker "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        sudo docker "$@"
        return $?
    fi
    echo "ERROR: cannot access Docker (try: sudo usermod -aG docker \$USER)" >&2
    return 1
}

kmip_container_running() {
    kmip_docker ps -q -f name=^kmip$ --filter status=running 2>/dev/null | grep -q .
}

kmip_refresh_certs_from_container() {
    local cert_dir="${KMIP_DEFAULT_CERT_DIR}"
    mkdir -p "${cert_dir}"
    kmip_docker cp kmip:/opt/certs/root_certificate.pem "${cert_dir}/" 2>/dev/null || true
    kmip_docker cp kmip:/opt/certs/client_key_jane_doe.pem "${cert_dir}/" 2>/dev/null || true
    kmip_docker cp kmip:/opt/certs/client_certificate_jane_doe.pem "${cert_dir}/" 2>/dev/null || true
}

kmip_export_docker_pytest_env() {
    export KMIP_SERVER_ADDRESS="${KMIP_SERVER_ADDRESS:-127.0.0.1}"
    export KMIP_SERVER_PORT="${KMIP_SERVER_PORT:-5696}"
    export KMIP_CLIENT_CA="${KMIP_CLIENT_CA:-${KMIP_DEFAULT_CLIENT_CERT}}"
    export KMIP_CLIENT_KEY="${KMIP_CLIENT_KEY:-${KMIP_DEFAULT_CLIENT_KEY}}"
    export KMIP_SERVER_CA="${KMIP_SERVER_CA:-${KMIP_DEFAULT_SERVER_CA}}"
}

# Reuse running container + default cert paths under /tmp/certs.
kmip_try_bootstrap_from_running_container() {
    if ! kmip_container_running; then
        return 1
    fi
    kmip_refresh_certs_from_container
    kmip_export_docker_pytest_env
    if ! kmip_certs_present; then
        return 1
    fi
    if ! kmip_server_reachable "$(kmip_connect_host)" "${KMIP_SERVER_PORT}"; then
        return 1
    fi
    return 0
}

# True when KMIP_* is set, cert files exist, and the server accepts TCP.
kmip_pytest_env_ready() {
    [[ -n "${KMIP_SERVER_ADDRESS:-}" ]] \
        && kmip_certs_present \
        && kmip_server_reachable "$(kmip_connect_host)" "${KMIP_SERVER_PORT:-5696}"
}

kmip_export_standard_env() {
    kmip_export_docker_pytest_env
}

kmip_print_pytest_env() {
    local label="${1:-KMIP pytest environment}"
    echo "${label}:"
    echo "  KMIP_SERVER_ADDRESS=${KMIP_SERVER_ADDRESS}"
    echo "  KMIP_SERVER_PORT=${KMIP_SERVER_PORT}"
    echo "  KMIP_CLIENT_CA=${KMIP_CLIENT_CA}"
    echo "  KMIP_CLIENT_KEY=${KMIP_CLIENT_KEY}"
    echo "  KMIP_SERVER_CA=${KMIP_SERVER_CA}"
    echo ""
    echo "Run: pytest tests/test_kmip.py -v"
}

kmip_docker_missing_message() {
    cat <<'EOF'
ERROR: Docker is not installed (or not on PATH), and no reachable KMIP server
       is configured via KMIP_* environment variables.

Options:
  1) Install Docker and allow access, then re-run:
       sudo usermod -aG docker $USER   # re-login afterwards
       source scripts/setup_kmip_for_pytest.sh
     Or without re-login:
       export KMIP_DOCKER='sudo docker'
       source scripts/setup_kmip_for_pytest.sh

  2) If container 'kmip' is already running:
       sudo docker ps -f name=kmip
       source scripts/setup_kmip_for_pytest.sh   # reuses container + /tmp/certs

  3) Point pytest at an existing KMIP server (lab PyKMIP, Fortanix, etc.):
       export KMIP_SERVER_ADDRESS=127.0.0.1
       export KMIP_SERVER_PORT=5696
       export KMIP_CLIENT_CA=/path/to/client.pem
       export KMIP_CLIENT_KEY=/path/to/client-key.pem
       export KMIP_SERVER_CA=/path/to/ca.pem
       ./scripts/run_kmip_revalidation.sh

  4) Skip the Docker profile and test a lab server only:
       export KMIP_REVALIDATE_PROFILES=fortanix

See docs/kmip.md and docs/kmip_revalidation.md
EOF
}
