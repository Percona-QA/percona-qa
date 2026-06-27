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
#
# NOTE: This script is meant to be *sourced*. It does not use ``set -e`` so a
# setup failure returns to your shell instead of closing an SSH session.
set -uo pipefail

_SCRIPT_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _SCRIPT_SOURCED=1
fi

_cosmian_setup_fail() {
    echo "ERROR: no Cosmian KMIP available." >&2
    echo "" >&2
    echo "Option A — install local cosmian_kms (pg_tde CI parity):" >&2
    echo "  cd postgresql/pytest" >&2
    echo "  ./scripts/install_cosmian_kms.sh" >&2
    echo "  source scripts/setup_cosmian_for_pytest.sh" >&2
    echo "" >&2
    echo "  Manual install (same as pg_tde/ci_scripts/ubuntu-deps.sh):" >&2
    echo "    COSMIAN_VERSION=5.21.0" >&2
    echo "    ARCH=\$(dpkg --print-architecture)" >&2
    echo "    wget https://package.cosmian.com/kms/\$COSMIAN_VERSION/deb/\$ARCH/non-fips/static/cosmian-kms-server-non-fips-static-openssl_\${COSMIAN_VERSION}_\${ARCH}.deb" >&2
    echo "    sudo dpkg -i cosmian-kms-server-non-fips-static-openssl_\${COSMIAN_VERSION}_\${ARCH}.deb" >&2
    echo "    sudo chmod 0755 /usr/sbin/cosmian_kms" >&2
    echo "    sudo chmod 0755 /usr/local/cosmian/lib/ossl-modules/legacy.so" >&2
    echo "" >&2
    echo "Option B — remote Cosmian lab:" >&2
    echo "  export KMIP_COSMIAN_HOST=..." >&2
    echo "  export KMIP_COSMIAN_PORT=9998" >&2
    echo "  export KMIP_COSMIAN_CLIENT_CERT=/path/to/client.pem" >&2
    echo "  export KMIP_COSMIAN_CLIENT_KEY=/path/to/client-key.pem" >&2
    echo "  export KMIP_COSMIAN_SERVER_CA=/path/to/ca.pem" >&2
    echo "  source scripts/setup_cosmian_for_pytest.sh" >&2
    echo "" >&2
    echo "See docs/kmip/quickstart.md § Install Cosmian KMS" >&2
    if [[ "${_SCRIPT_SOURCED}" -eq 1 ]]; then
        return 1
    fi
    exit 1
}

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
        if ! source "${SCRIPT_DIR}/setup_cosmian_local_for_pytest.sh"; then
            _cosmian_setup_fail
        fi
        return 0 2>/dev/null || exit 0
    fi
fi

if ! kmip_export_vendor_to_standard "KMIP_COSMIAN_"; then
    _cosmian_setup_fail
fi

if ! kmip_pytest_env_ready; then
    echo "ERROR: Cosmian KMIP not reachable at $(kmip_connect_host):${KMIP_SERVER_PORT}" >&2
    echo "  Check host, port (often 9998), firewall, and cert paths." >&2
    if [[ "${_SCRIPT_SOURCED}" -eq 1 ]]; then
        return 1
    fi
    exit 1
fi

export KMIP_REVALIDATE_PROFILES="${KMIP_REVALIDATE_PROFILES:-cosmian}"
kmip_print_pytest_env "Cosmian KMIP pytest environment"
echo "  KMIP_REVALIDATE_PROFILES=${KMIP_REVALIDATE_PROFILES}"
echo ""
echo "Run: ./scripts/run_kmip_revalidation.sh"
