#!/usr/bin/env bash
# Install OpenBao server CLI (``bao``) from release packages.
# Supports Ubuntu/Debian (.deb) and RHEL/OL/Rocky (.rpm).
#
# Usage (run directly — do not source):
#   cd postgresql/pytest
#   ./scripts/install_openbao.sh
#
# After install:
#   source scripts/setup_openbao_for_pytest.sh
#   ./scripts/run_openbao_revalidation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pg_os_env.sh
source "${SCRIPT_DIR}/pg_os_env.sh"
pg_os_detect

OPENBAO_VERSION="${OPENBAO_VERSION:-2.5.4}"
BASE="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}"

if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
    # Upstream assets are typically ``…_linux_amd64.rpm`` (Debian arch name).
    PKG="openbao_${OPENBAO_VERSION}_linux_${PG_ARCH}.rpm"
    INSTALL_HINT="sudo ${PG_PKG_CMD:-dnf} install -y wget"
else
    PKG="openbao_${OPENBAO_VERSION}_linux_${PG_ARCH}.deb"
    INSTALL_HINT="sudo apt-get install -y wget"
fi
URL="${BASE}/${PKG}"

echo "Installing OpenBao ${OPENBAO_VERSION} (${PG_OS_FAMILY}/${PG_ARCH})..."
echo "  ${URL}"

if ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: wget is required (${INSTALL_HINT})" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

if ! wget -q "${URL}"; then
    # Some releases use RPM arch naming (x86_64 / aarch64).
    if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
        PKG="openbao_${OPENBAO_VERSION}_linux_${PG_ARCH_RPM}.rpm"
        URL="${BASE}/${PKG}"
        echo "Retrying: ${URL}"
        wget -q "${URL}"
    else
        exit 1
    fi
fi
if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
    sudo "${PG_PKG_CMD:-dnf}" install -y "./${PKG}"
else
    sudo dpkg -i "${PKG}"
fi

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
