#!/usr/bin/env bash
# Run KMIP revalidation after PR #595 (libkmip C++ client).
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   source scripts/setup_cosmian_for_pytest.sh
#   ./scripts/run_kmip_revalidation.sh
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

if [[ -z "${KMIP_REVALIDATE_PROFILES:-}" ]]; then
    export KMIP_REVALIDATE_PROFILES=cosmian
fi
PROFILES="${KMIP_REVALIDATE_PROFILES}"

need_cosmian=false
case ",${PROFILES}," in
    *,cosmian,*|*,all,*)
        need_cosmian=true
        ;;
esac

if [[ "${need_cosmian}" == true ]] && ! kmip_pytest_env_ready; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_cosmian_for_pytest.sh"
fi

if ! kmip_pytest_env_ready; then
    kmip_not_configured_message >&2
    exit 1
fi

echo "KMIP revalidation profiles: ${PROFILES}"
echo "  docs: docs/kmip_revalidation.md"
echo ""

exec pytest \
    tests/test_kmip_server_revalidation.py \
    tests/test_kmip.py \
    tests/test_kmip_advanced.py \
    "tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression" \
    -v \
    "$@"
