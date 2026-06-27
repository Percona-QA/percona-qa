#!/usr/bin/env bash
# Run shared KMIP matrix tests against configured server profile(s).
#
# Same core scenarios for Cosmian, Vault KMIP, Fortanix, Thales, Akeyless, …
# Server-specific tests stay in separate modules (see docs/key_provider_matrix.md).
# KMIP docs index: docs/kmip/README.md
#
# Usage:
#   cd postgresql/pytest && source .env.sh
#
#   # Cosmian (CI default)
#   source scripts/setup_cosmian_for_pytest.sh
#   ./scripts/run_kmip_matrix.sh
#
#   # HashiCorp Vault KMIP engine (your Enterprise lab)
#   source /tmp/vault_kmip_pytest.env
#   KMIP_REVALIDATE_PROFILES=vault_kmip ./scripts/run_kmip_matrix.sh
#
#   # Multiple profiles (skip unconfigured)
#   KMIP_REVALIDATE_PROFILES=cosmian,vault_kmip ./scripts/run_kmip_matrix.sh
#
#   # Full checklist only
#   KMIP_MATRIX_SUITE=checklist ./scripts/run_kmip_matrix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

# shellcheck source=kmip_env.sh
source "${SCRIPT_DIR}/kmip_env.sh"
# shellcheck source=hashicorp_vault_env.sh
source "${SCRIPT_DIR}/hashicorp_vault_env.sh"

if [[ -f .env.sh ]]; then
    # shellcheck source=/dev/null
    source .env.sh
fi

hc_vault_apply_defaults

export KMIP_REVALIDATE_PROFILES="${KMIP_REVALIDATE_PROFILES:-${KMIP_PROFILE:-cosmian}}"
PROFILES="${KMIP_REVALIDATE_PROFILES}"

echo "KMIP default profile: cosmian (no license). Override: KMIP_PROFILE=vault_kmip $0"

need_cosmian=false
case ",${PROFILES}," in
    *,cosmian,*|*,all,*)
        need_cosmian=true
        ;;
esac

if [[ "${need_cosmian}" == true ]] && ! kmip_pytest_env_ready; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/setup_cosmian_for_pytest.sh" 2>/dev/null || true
fi

if [[ ",${PROFILES}," == *",vault_kmip,"* ]] || [[ ",${PROFILES}," == *",all,"* ]]; then
    if [[ ! -f "${KMIP_VAULT_CLIENT_CERT:-}" ]]; then
        echo "WARN: vault_kmip profile requested but KMIP_VAULT_* not set" >&2
        echo "  source /tmp/vault_kmip_pytest.env or scripts/export_vault_kmip_certs_for_pytest.sh" >&2
    fi
fi

echo "KMIP matrix profiles: ${PROFILES}"
echo "  docs: docs/key_provider_matrix.md"
echo ""

KMIP_MATRIX_SUITE="${KMIP_MATRIX_SUITE:-all}"
TARGETS=()

case "${KMIP_MATRIX_SUITE}" in
    all)
        TARGETS+=(
            tests/test_kmip_common_matrix.py
            tests/test_kmip_server_revalidation.py
        )
        ;;
    common)
        TARGETS+=(tests/test_kmip_common_matrix.py)
        ;;
    checklist)
        TARGETS+=(tests/test_kmip_server_revalidation.py)
        ;;
    *)
        echo "ERROR: KMIP_MATRIX_SUITE must be all, common, or checklist" >&2
        exit 2
        ;;
esac

# Cosmian-only extended suite (bash parity, advanced)
if [[ "${need_cosmian}" == true ]] && kmip_pytest_env_ready \
    && [[ "${KMIP_MATRIX_INCLUDE_COSMIAN_EXTENDED:-0}" == "1" ]]; then
    TARGETS+=(tests/test_kmip.py)
fi

# Vault KMIP engine — server-specific regressions
if [[ ",${PROFILES}," == *",vault_kmip,"* ]] || [[ ",${PROFILES}," == *",all,"* ]]; then
    if [[ -f "${KMIP_VAULT_CLIENT_CERT:-}" ]]; then
        TARGETS+=(tests/test_vault_kmip.py)
    fi
fi

exec pytest "${TARGETS[@]}" -v "$@"
