#!/usr/bin/env bash
# Run KMIP revalidation after PR #595 (libkmip C++ client).
#
# Usage:
#   cd postgresql/pytest
#   source .env.sh
#   ./scripts/run_kmip_revalidation.sh
#
# Must be sourced or run in a shell that keeps exports from setup_kmip_for_pytest.sh.
# For two specific tests only:
#   source scripts/setup_kmip_for_pytest.sh
#   pytest tests/test_kmip.py::TestKmipChangeKeyProviderCLI::... -v
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

# Default: cosmian on CI (KMIP_COSMIAN_* or mapped KMIP_*); pykmip_docker for local dev.
if [[ -z "${KMIP_REVALIDATE_PROFILES:-}" ]]; then
    if [[ -n "${KMIP_COSMIAN_HOST:-}" ]]; then
        export KMIP_REVALIDATE_PROFILES=cosmian
    elif kmip_pytest_env_ready 2>/dev/null; then
        export KMIP_REVALIDATE_PROFILES=pykmip_docker
    else
        export KMIP_REVALIDATE_PROFILES=pykmip_docker
    fi
fi
PROFILES="${KMIP_REVALIDATE_PROFILES}"

need_pykmip_docker=false
need_cosmian=false
case ",${PROFILES}," in
    *,pykmip_docker,*|*,pykmip,*|*,all,*)
        need_pykmip_docker=true
        ;;
esac
case ",${PROFILES}," in
    *,cosmian,*|*,all,*)
        need_cosmian=true
        ;;
esac

if [[ "${need_cosmian}" == true ]] && ! kmip_pytest_env_ready; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_cosmian_for_pytest.sh"
fi

if [[ "${need_pykmip_docker}" == true ]] && ! kmip_pytest_env_ready; then
    if kmip_try_bootstrap_from_running_container; then
        echo "Using running Docker container 'kmip' at $(kmip_connect_host):${KMIP_SERVER_PORT}"
    elif command -v docker >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/setup_kmip_for_pytest.sh"
    elif [[ "${need_cosmian}" != true ]]; then
        kmip_docker_missing_message >&2
        exit 1
    fi
fi

if ! kmip_pytest_env_ready; then
    if [[ "${need_cosmian}" == true ]]; then
        echo "ERROR: Cosmian KMIP not configured — source scripts/setup_cosmian_for_pytest.sh" >&2
        exit 1
    fi
    echo "ERROR: KMIP not configured — export KMIP_* or fix Docker, then re-run." >&2
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
