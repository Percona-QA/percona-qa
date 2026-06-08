#!/usr/bin/env bash
# Install Cosmian KMS server binary (same as pg_tde ci_scripts/ubuntu-deps.sh).
#
# Usage (run directly — do not source):
#   cd postgresql/pytest
#   ./scripts/install_cosmian_kms.sh
#
# After install:
#   source scripts/setup_cosmian_for_pytest.sh
#   ./scripts/run_kmip_revalidation.sh
set -euo pipefail

COSMIAN_VERSION="${COSMIAN_VERSION:-5.21.0}"
ARCH="$(dpkg --print-architecture)"
DEB="cosmian-kms-server-non-fips-static-openssl_${COSMIAN_VERSION}_${ARCH}.deb"
URL="https://package.cosmian.com/kms/${COSMIAN_VERSION}/deb/${ARCH}/non-fips/static/${DEB}"

echo "Installing Cosmian KMS ${COSMIAN_VERSION} (${ARCH})..."
echo "  ${URL}"

if ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: wget is required (sudo apt-get install -y wget)" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

wget -q "${URL}"
sudo dpkg -i "${DEB}"

# .deb ships binary + bundled legacy.so as 0500 root:root; test runner is non-root.
sudo chmod 0755 /usr/sbin/cosmian_kms
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
