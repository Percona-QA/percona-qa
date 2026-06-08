#!/usr/bin/env bash
# Shared KMIP env helpers for pytest scripts.
# Sourced by setup_cosmian_* and run_kmip_revalidation.sh (do not execute).

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
    export KMIP_SERVER_PORT="${KMIP_SERVER_PORT:-5696}"
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

kmip_not_configured_message() {
    cat <<'EOF'
ERROR: No reachable KMIP server configured via KMIP_*.

Options:
  1) Local Cosmian (pg_tde CI parity):
       source scripts/setup_cosmian_for_pytest.sh
     Install cosmian_kms: pg_tde/ci_scripts/ubuntu-deps.sh

  2) Remote Cosmian lab:
       export KMIP_COSMIAN_HOST=...
       export KMIP_COSMIAN_CLIENT_CERT=...
       source scripts/setup_cosmian_for_pytest.sh

  3) Other vendor (Fortanix, Thales, etc.):
       export KMIP_SERVER_ADDRESS=...
       export KMIP_CLIENT_CA=...
       export KMIP_CLIENT_KEY=...
       export KMIP_SERVER_CA=...
       export KMIP_REVALIDATE_PROFILES=fortanix

See docs/kmip.md and docs/kmip_revalidation.md
EOF
}
