#!/usr/bin/env bash
# Run all shared key-provider matrix tests (KMIP + Vault KV + file keyring).
#
# Usage:
#   cd postgresql/pytest && source .env.sh
#   ./scripts/run_key_provider_matrix.sh
#
# Subsets:
#   KEY_PROVIDER_MATRIX=kmip   ./scripts/run_key_provider_matrix.sh
#   KEY_PROVIDER_MATRIX=vault  ./scripts/run_key_provider_matrix.sh
#   KEY_PROVIDER_MATRIX=file ./scripts/run_key_provider_matrix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PYTEST_ROOT}"

KEY_PROVIDER_MATRIX="${KEY_PROVIDER_MATRIX:-all}"

run_kmip=false
run_vault=false
run_file=true

case "${KEY_PROVIDER_MATRIX}" in
    all) run_kmip=true; run_vault=true ;;
    kmip) run_kmip=true; run_file=false ;;
    vault) run_vault=true; run_file=false ;;
    file) ;;
    *)
        echo "ERROR: KEY_PROVIDER_MATRIX must be all, kmip, vault, or file" >&2
        exit 2
        ;;
esac

if [[ "${run_file}" == true ]]; then
    echo "=== File keyring matrix ==="
    pytest tests/test_file_keyring_common_matrix.py -v "$@" || exit 1
fi

if [[ "${run_kmip}" == true ]]; then
    echo "=== KMIP matrix ==="
    "${SCRIPT_DIR}/run_kmip_matrix.sh" "$@" || exit 1
fi

if [[ "${run_vault}" == true ]]; then
    echo "=== Vault KV matrix ==="
    "${SCRIPT_DIR}/run_vault_kv_matrix.sh" "$@" || exit 1
fi
