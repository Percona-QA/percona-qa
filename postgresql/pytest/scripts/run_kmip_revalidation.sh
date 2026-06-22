#!/usr/bin/env bash
# Run KMIP revalidation (wrapper for run_kmip_matrix.sh).
#
# Backward-compatible entry point; prefer ./scripts/run_kmip_matrix.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KMIP_MATRIX_SUITE="${KMIP_MATRIX_SUITE:-all}"
export KMIP_MATRIX_INCLUDE_COSMIAN_EXTENDED="${KMIP_MATRIX_INCLUDE_COSMIAN_EXTENDED:-1}"
exec "${SCRIPT_DIR}/run_kmip_matrix.sh" "$@"
