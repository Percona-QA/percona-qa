#!/usr/bin/env bash
# Export KMIP_* from KMIP_COSMIAN_* for pytest (Percona CI uses Cosmian, not PyKMIP).
#
# Usage (CI injects KMIP_COSMIAN_* as Jenkins secrets, or export manually):
#   cd postgresql/pytest
#   source .env.sh
#   source scripts/setup_cosmian_for_pytest.sh
#   ./scripts/run_kmip_revalidation.sh
#
# If CI already exports KMIP_* pointing at Cosmian, this script is a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

kmip_export_vendor_to_standard() {
    local prefix="$1"   # e.g. KMIP_COSMIAN_
    local host_var="${prefix}HOST"
    local port_var="${prefix}PORT"

    if [[ -z "${!host_var:-}" ]]; then
        return 1
    fi
    export KMIP_SERVER_ADDRESS="${!host_var}"
    export KMIP_SERVER_PORT="${!port_var:-5696}"
    export KMIP_CLIENT_CA="${!prefix}CLIENT_CERT"
    export KMIP_CLIENT_KEY="${!prefix}CLIENT_KEY"
    export KMIP_SERVER_CA="${!prefix}SERVER_CA"
    return 0
}

if kmip_pytest_env_ready; then
    kmip_print_pytest_env "KMIP pytest environment (KMIP_* already set — Cosmian or other)"
    export KMIP_REVALIDATE_PROFILES="${KMIP_REVALIDATE_PROFILES:-cosmian}"
    return 0 2>/dev/null || exit 0
fi

if [[ -z "${KMIP_COSMIAN_HOST:-}" ]]; then
    # pg_tde CI spawns local cosmian_kms (t/CosmianKms.pm) — same path for pytest.
    if command -v cosmian_kms >/dev/null 2>&1 \
        || [[ -x /usr/sbin/cosmian_kms ]] \
        || [[ -n "${COSMIAN_KMS_BIN:-}" ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/setup_cosmian_local_for_pytest.sh"
        return 0 2>/dev/null || exit 0
    fi
fi

if ! kmip_export_vendor_to_standard "KMIP_COSMIAN_"; then
    echo "ERROR: no Cosmian KMIP available." >&2
    echo "  Option A (pg_tde CI parity): install cosmian_kms — see pg_tde/ci_scripts/ubuntu-deps.sh" >&2
    echo "  Option B (remote lab): set KMIP_COSMIAN_HOST + cert paths (config/kmip_profiles.example.env)" >&2
    return 1 2>/dev/null || exit 1
fi

if ! kmip_pytest_env_ready; then
    echo "ERROR: Cosmian KMIP not reachable at $(kmip_connect_host):${KMIP_SERVER_PORT}" >&2
    echo "  Check host, port (often 9998), firewall, and cert paths." >&2
    return 1 2>/dev/null || exit 1
fi

export KMIP_REVALIDATE_PROFILES="${KMIP_REVALIDATE_PROFILES:-cosmian}"
kmip_print_pytest_env "Cosmian KMIP pytest environment"
echo "  KMIP_REVALIDATE_PROFILES=${KMIP_REVALIDATE_PROFILES}"
echo ""
echo "Run: ./scripts/run_kmip_revalidation.sh"
