#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Container entrypoint for Percona pg_tde QA tests.
#
# Sets up the runtime environment and then exec's whatever command was passed
# (defaults to: pytest tests/ -v ...).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Diagnostics ────────────────────────────────────────────────────────────
echo "=========================================="
echo "  Percona pg_tde QA test environment"
echo "=========================================="
echo "  User       : $(whoami)  (uid=$(id -u))"
echo "  PGUSER     : ${PGUSER:-<unset — will default to $(whoami)>}"
echo "  INSTALL_DIR: ${INSTALL_DIR:-<unset>}"
echo "  OLD_INSTALL: ${OLD_INSTALL_DIR:-<unset — upgrade tests skipped>}"
echo "  VAULT_ADDR : ${VAULT_ADDR:-<unset — vault tests skipped>}"

# ── Verify PostgreSQL binary ────────────────────────────────────────────────
if [[ -n "${INSTALL_DIR:-}" ]]; then
    PG_BIN="${INSTALL_DIR}/bin/postgres"
    if [[ -x "$PG_BIN" ]]; then
        PG_VER=$("$PG_BIN" --version 2>&1 || echo "unknown")
        echo "  PostgreSQL : $PG_VER"
    else
        echo "  WARNING: postgres binary not found at ${PG_BIN}"
    fi
fi

# ── Verify pg_tde extension ─────────────────────────────────────────────────
TDE_FOUND=false
for share_dir in \
    "${INSTALL_DIR:-}/share/postgresql/extension" \
    "${INSTALL_DIR:-}/share/extension"; do
    if [[ -f "${share_dir}/pg_tde.control" ]]; then
        TDE_VER=$(grep '^default_version' "${share_dir}/pg_tde.control" | cut -d= -f2 | tr -d "' ")
        echo "  pg_tde     : ${TDE_VER:-found} (${share_dir})"
        TDE_FOUND=true
        break
    fi
done
if [[ "$TDE_FOUND" = false ]]; then
    echo "  WARNING: pg_tde.control not found — encryption tests will fail"
fi

# ── Verify old PostgreSQL for upgrade tests ─────────────────────────────────
if [[ -n "${OLD_INSTALL_DIR:-}" && -x "${OLD_INSTALL_DIR}/bin/postgres" ]]; then
    OLD_VER=$("${OLD_INSTALL_DIR}/bin/postgres" --version 2>&1 || echo "unknown")
    echo "  Old PG     : $OLD_VER  (upgrade tests enabled)"
else
    echo "  Old PG     : not available (upgrade tests will be skipped)"
fi

echo "=========================================="
echo ""

# ── Workspace ───────────────────────────────────────────────────────────────
# docker-compose mounts the host pytest/ directory here at runtime.
# Verify we have the test code before starting.
if [[ ! -f /workspace/conftest.py ]]; then
    echo "ERROR: /workspace/conftest.py not found."
    echo "  Mount the pytest/ directory: -v \$(pwd):/workspace"
    exit 1
fi

cd /workspace

# ── Export env vars read by conftest.py ────────────────────────────────────
# conftest.py reads INSTALL_DIR, OLD_INSTALL_DIR, VAULT_ADDR, VAULT_TOKEN,
# IO_METHOD, and PGUSER from the environment as defaults for CLI options.
export INSTALL_DIR="${INSTALL_DIR:-}"
export OLD_INSTALL_DIR="${OLD_INSTALL_DIR:-}"
export VAULT_ADDR="${VAULT_ADDR:-}"
export VAULT_TOKEN="${VAULT_TOKEN:-}"
export IO_METHOD="${IO_METHOD:-worker}"
# PGUSER tells libpq_superuser() which superuser owns the initdb clusters.
# Inside the container this is always "pgqa".
export PGUSER="${PGUSER:-$(whoami)}"

# ── Execute ─────────────────────────────────────────────────────────────────
exec "$@"
