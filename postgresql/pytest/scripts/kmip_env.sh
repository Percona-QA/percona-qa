#!/usr/bin/env bash
# Shared KMIP env checks for pytest helper scripts.
# Sourced by setup_kmip_for_pytest.sh and run_kmip_revalidation.sh (do not execute).

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

# True when KMIP_* is set, cert files exist, and the server accepts TCP.
kmip_pytest_env_ready() {
    [[ -n "${KMIP_SERVER_ADDRESS:-}" ]] \
        && kmip_certs_present \
        && kmip_server_reachable "$(kmip_connect_host)" "${KMIP_SERVER_PORT:-5696}"
}

kmip_export_standard_env() {
    export KMIP_SERVER_ADDRESS="${KMIP_SERVER_ADDRESS:-127.0.0.1}"
    export KMIP_SERVER_PORT="${KMIP_SERVER_PORT:-5696}"
    export KMIP_CLIENT_CA="${KMIP_CLIENT_CA:-}"
    export KMIP_CLIENT_KEY="${KMIP_CLIENT_KEY:-}"
    export KMIP_SERVER_CA="${KMIP_SERVER_CA:-}"
}

kmip_docker_missing_message() {
    cat <<'EOF'
ERROR: Docker is not installed (or not on PATH), and no reachable KMIP server
       is configured via KMIP_* environment variables.

Options:
  1) Install Docker, then re-run:
       source scripts/setup_kmip_for_pytest.sh

  2) Point pytest at an existing KMIP server (lab PyKMIP, Fortanix, etc.):
       export KMIP_SERVER_ADDRESS=127.0.0.1
       export KMIP_SERVER_PORT=5696
       export KMIP_CLIENT_CA=/path/to/client.pem
       export KMIP_CLIENT_KEY=/path/to/client-key.pem
       export KMIP_SERVER_CA=/path/to/ca.pem
       ./scripts/run_kmip_revalidation.sh

  3) Skip the Docker profile and test a lab server only:
       export KMIP_REVALIDATE_PROFILES=fortanix
       # plus KMIP_FORTANIX_* (see config/kmip_profiles.example.env)

See docs/kmip.md and docs/kmip_revalidation.md
EOF
}
