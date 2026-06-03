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
# For pykmip_docker (default), starts the Docker KMIP test server automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

PROFILES="${KMIP_REVALIDATE_PROFILES:-pykmip_docker}"
need_docker=false
case ",${PROFILES}," in
    *,pykmip_docker,*|*,pykmip,*|*,all,*)
        need_docker=true
        ;;
esac

if [[ "${need_docker}" == true ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_kmip_for_pytest.sh"
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
