#!/usr/bin/env bash
# Run KMIP revalidation after PR #595 (libkmip C++ client).
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   ./scripts/run_kmip_revalidation.sh
#
#   KMIP_REVALIDATE_PROFILES=fortanix ./scripts/run_kmip_revalidation.sh
#   KMIP_REVALIDATE_PROFILES=all ./scripts/run_kmip_revalidation.sh -x
#
# For pykmip_docker (default): uses Docker when available, otherwise an
# existing KMIP_* environment (lab server or certs under /tmp/certs).
#
# Note: offline change_key_provider tests require keys on the KMIP server already;
# they do not migrate file → kmip (see pg_tde architecture docs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

PROFILES="${KMIP_REVALIDATE_PROFILES:-pykmip_docker}"
need_pykmip=false
case ",${PROFILES}," in
    *,pykmip_docker,*|*,pykmip,*|*,all,*)
        need_pykmip=true
        ;;
esac

if [[ "${need_pykmip}" == true ]]; then
    if kmip_pytest_env_ready; then
        kmip_export_standard_env
        echo "Using existing KMIP server at $(kmip_connect_host):${KMIP_SERVER_PORT} (Docker skipped)"
    elif command -v docker >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/setup_kmip_for_pytest.sh"
    else
        kmip_docker_missing_message >&2
        exit 1
    fi
fi

echo "KMIP revalidation profiles: ${PROFILES}"
echo "  docs: docs/kmip_revalidation.md"
echo ""

exec pytest \
    tests/test_kmip_server_revalidation.py \
    tests/test_kmip.py \
    "tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression" \
    -v \
    "$@"
