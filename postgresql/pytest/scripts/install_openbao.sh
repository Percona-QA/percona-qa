#!/usr/bin/env bash
# Install OpenBao server CLI (``bao``) from release .deb — same approach as
# pg_tde ci_scripts/ubuntu-deps.sh (v2.5.4).
#
# Usage (run directly — do not source):
#   cd postgresql/pytest
#   ./scripts/install_openbao.sh
#
# After install:
#   source scripts/setup_openbao_for_pytest.sh
#   ./scripts/run_openbao_revalidation.sh
set -euo pipefail

OPENBAO_VERSION="${OPENBAO_VERSION:-2.5.4}"
ARCH="$(dpkg --print-architecture)"
DEB="openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb"
URL="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/${DEB}"

echo "Installing OpenBao ${OPENBAO_VERSION} (${ARCH})..."
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

if ! command -v bao >/dev/null 2>&1; then
    echo "ERROR: bao not found after install" >&2
    exit 1
fi

echo ""
echo "OpenBao installed:"
bao version 2>/dev/null || bao --version
echo ""
echo "Next:"
echo "  cd postgresql/pytest"
echo "  source scripts/setup_openbao_for_pytest.sh"
echo "  ./scripts/run_openbao_revalidation.sh"
