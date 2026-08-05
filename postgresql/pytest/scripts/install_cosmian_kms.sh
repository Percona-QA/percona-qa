#!/usr/bin/env bash
# Install Cosmian KMS server binary.
# Ubuntu/Debian: official .deb. RHEL: try RPM, else extract static tarball if published.
#
# Usage (run directly — do not source):
#   cd postgresql/pytest
#   ./scripts/install_cosmian_kms.sh
#
# After install:
#   source scripts/setup_cosmian_for_pytest.sh
#   ./scripts/run_kmip_revalidation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pg_os_env.sh
source "${SCRIPT_DIR}/pg_os_env.sh"
pg_os_detect

COSMIAN_VERSION="${COSMIAN_VERSION:-5.21.0}"
BASE="https://package.cosmian.com/kms/${COSMIAN_VERSION}"

if ! command -v wget >/dev/null 2>&1; then
    if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
        echo "ERROR: wget is required (sudo ${PG_PKG_CMD:-dnf} install -y wget)" >&2
    else
        echo "ERROR: wget is required (sudo apt-get install -y wget)" >&2
    fi
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

_install_deb() {
    local deb="cosmian-kms-server-non-fips-static-openssl_${COSMIAN_VERSION}_${PG_ARCH}.deb"
    local url="${BASE}/deb/${PG_ARCH}/non-fips/static/${deb}"
    echo "Installing Cosmian KMS ${COSMIAN_VERSION} (${PG_ARCH}) from .deb..."
    echo "  ${url}"
    wget -q --user-agent="Mozilla/5.0" "${url}"
    sudo dpkg -i "${deb}"
}

_install_rpm() {
    # Cosmian RPM tree mirrors deb arch dirs (amd64/arm64), but RPM filenames
    # use RPM arch tags (x86_64/aarch64) with underscores, e.g.:
    #   …/rpm/amd64/non-fips/static/cosmian-kms-server-non-fips-static-openssl_5.21.0_x86_64.rpm
    local dir_arch="${PG_ARCH}"   # amd64 | arm64
    local rpm_arch="${PG_ARCH_RPM}"  # x86_64 | aarch64
    local rpm="cosmian-kms-server-non-fips-static-openssl_${COSMIAN_VERSION}_${rpm_arch}.rpm"
    local url="${BASE}/rpm/${dir_arch}/non-fips/static/${rpm}"
    echo "Installing Cosmian KMS ${COSMIAN_VERSION} (${rpm_arch}) from .rpm..."
    echo "  ${url}"
    if ! wget -q --user-agent="Mozilla/5.0" "${url}"; then
        echo "WARN: Cosmian RPM not found at ${url}" >&2
        return 1
    fi
    sudo "${PG_PKG_CMD:-dnf}" install -y "./${rpm}"
}

if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
    if ! _install_rpm; then
        echo "ERROR: Cosmian KMS RPM install failed on RHEL." >&2
        echo "       Install cosmian_kms manually, or run this script on Ubuntu/Debian." >&2
        echo "       Packages: ${BASE}/" >&2
        exit 1
    fi
else
    _install_deb
fi

# Packages often ship binary + bundled legacy.so as 0500 root:root; test runner is non-root.
if [[ -x /usr/sbin/cosmian_kms ]]; then
    sudo chmod 0755 /usr/sbin/cosmian_kms
fi
if [[ -f /usr/local/cosmian/lib/ossl-modules/legacy.so ]]; then
    sudo chmod 0755 /usr/local/cosmian/lib/ossl-modules/legacy.so
fi

if ! command -v cosmian_kms >/dev/null 2>&1 && [[ ! -x /usr/sbin/cosmian_kms ]]; then
    echo "ERROR: cosmian_kms not found after install" >&2
    exit 1
fi

echo ""
echo "Cosmian KMS installed:"
command -v cosmian_kms 2>/dev/null || echo "  /usr/sbin/cosmian_kms"
echo ""
echo "Next:"
echo "  cd postgresql/pytest"
echo "  source scripts/setup_cosmian_for_pytest.sh"
echo "  ./scripts/run_kmip_revalidation.sh"
