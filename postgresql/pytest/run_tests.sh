#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# run_tests.sh — Build the Docker image and run pg_tde QA tests.
#
# USAGE
#   bash run_tests.sh [options] [-- pytest-args...]
#
# OPTIONS
#   --source              Use source-build mode (compile PG + pg_tde from GitHub)
#   --pg-major VERSION    PostgreSQL major version      (default: 17)
#   --old-pg-major VER    Old PG for upgrade tests      (default: 16)
#   --tde-ref REF         pg_tde git branch/tag/sha     (default: main)
#   --tde-repo URL        pg_tde git remote URL         (source mode only)
#   --pg-ref REF          PostgreSQL git branch/tag     (source mode only)
#   --pg-repo URL         PostgreSQL git remote URL     (source mode only)
#   --no-debug            Omit --enable-debug --enable-cassert (source mode)
#   --rebuild             Force docker build (--no-cache)
#   --shell               Start an interactive bash session instead of pytest
#   --report DIR          Write HTML report to DIR      (default: ./reports)
#   --vault               Start a Vault dev container for vault tests
#   --workers N           Run pytest with -n N parallel workers
#   -h, --help            Show this help and exit
#
# EXAMPLES
#   # All non-slow tests, package mode (PG 17)
#   bash run_tests.sh
#
#   # Encryption tests only
#   bash run_tests.sh -- pytest tests/test_encryption.py -v
#
#   # Recovery tests, source mode, pg_tde from a feature branch
#   bash run_tests.sh --source --tde-ref feat/my-fix \
#       -- pytest tests/test_recovery.py -v
#
#   # Upgrade tests (needs OLD_PG_MAJOR installed)
#   bash run_tests.sh --pg-major 17 --old-pg-major 16 \
#       -- pytest tests/test_upgrade.py -v
#
#   # Full suite (parallel, skip vault)
#   bash run_tests.sh --workers 4 \
#       -- pytest tests/ -v -m "not vault" --timeout=600
#
#   # Interactive shell for debugging
#   bash run_tests.sh --shell
#
#   # Vault tests (starts a vault dev server automatically)
#   bash run_tests.sh --vault \
#       -- pytest tests/ -v -m vault
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
BUILD_MODE=package
PG_MAJOR=17
OLD_PG_MAJOR=16
PG_TDE_REF=main
PG_TDE_REPO="https://github.com/Percona-Lab/pg_tde.git"
PG_REF=""          # auto-set from PG_MAJOR if empty
PG_REPO="https://github.com/postgres/postgres.git"
DEBUG_BUILD=true
REBUILD=false
SHELL_MODE=false
VAULT_MODE=false
WORKERS=""
REPORT_DIR="${SCRIPT_DIR}/reports"

# pytest args collected after --
PYTEST_ARGS=()
EXTRA_COMPOSE_ENV=()

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --source)          BUILD_MODE=source; shift ;;
        --pg-major)        PG_MAJOR="$2"; shift 2 ;;
        --old-pg-major)    OLD_PG_MAJOR="$2"; shift 2 ;;
        --tde-ref)         PG_TDE_REF="$2"; shift 2 ;;
        --tde-repo)        PG_TDE_REPO="$2"; shift 2 ;;
        --pg-ref)          PG_REF="$2"; shift 2 ;;
        --pg-repo)         PG_REPO="$2"; shift 2 ;;
        --no-debug)        DEBUG_BUILD=false; shift ;;
        --rebuild)         REBUILD=true; shift ;;
        --shell)           SHELL_MODE=true; shift ;;
        --vault)           VAULT_MODE=true; shift ;;
        --workers)         WORKERS="$2"; shift 2 ;;
        --report)          REPORT_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,60p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        --)                shift; PYTEST_ARGS+=("$@"); break ;;
        *)                 PYTEST_ARGS+=("$1"); shift ;;
    esac
done

# ── Derived values ────────────────────────────────────────────────────────────
[[ -z "$PG_REF" ]] && PG_REF="REL_${PG_MAJOR}_STABLE"

SERVICE="pg-tde-tests-${BUILD_MODE/package/pkg}"
CACHE_FLAG=""
[[ "$REBUILD" = true ]] && CACHE_FLAG="--no-cache"

# ── Requirement checks ────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
(docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1) \
    || die "docker compose (v2) not found"

# Detect compose command
COMPOSE="docker compose"
docker compose version >/dev/null 2>&1 || COMPOSE="docker-compose"

# ── Build ─────────────────────────────────────────────────────────────────────
info "Build mode  : ${BUILD_MODE}"
info "PG major    : ${PG_MAJOR}  (old: ${OLD_PG_MAJOR})"
if [[ "$BUILD_MODE" = "source" ]]; then
    info "PG ref      : ${PG_REF}  (${PG_REPO})"
    info "pg_tde ref  : ${PG_TDE_REF}  (${PG_TDE_REPO})"
    info "Debug build : ${DEBUG_BUILD}"
fi
echo ""

BUILD_ARGS=(
    "PG_MAJOR=${PG_MAJOR}"
    "OLD_PG_MAJOR=${OLD_PG_MAJOR}"
    "PG_TDE_REF=${PG_TDE_REF}"
    "PG_TDE_REPO=${PG_TDE_REPO}"
    "PG_REF=${PG_REF}"
    "PG_REPO=${PG_REPO}"
    "DEBUG_BUILD=${DEBUG_BUILD}"
)

BUILD_ARG_FLAGS=()
for arg in "${BUILD_ARGS[@]}"; do
    BUILD_ARG_FLAGS+=(--build-arg "$arg")
done

info "Building image for service: ${SERVICE}  ..."
cd "$SCRIPT_DIR"

$COMPOSE build ${CACHE_FLAG} \
    "${BUILD_ARG_FLAGS[@]}" \
    "$SERVICE"
ok "Image built"

# ── Start Vault if requested ──────────────────────────────────────────────────
if [[ "$VAULT_MODE" = true ]]; then
    info "Starting Vault dev server ..."
    $COMPOSE up -d vault
    sleep 3   # give vault time to initialise
    EXTRA_COMPOSE_ENV+=(-e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root)
    ok "Vault running on http://localhost:8200  (token: root)"
fi

# ── Prepare report directory ──────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
REPORT_MOUNT=(-v "${REPORT_DIR}:/reports")

# ── Build pytest command ──────────────────────────────────────────────────────
if [[ "$SHELL_MODE" = true ]]; then
    CMD=(bash)
elif [[ ${#PYTEST_ARGS[@]} -gt 0 ]]; then
    CMD=("${PYTEST_ARGS[@]}")
else
    # Default: all non-slow, non-vault tests; HTML report to /reports/results.html
    MARKS="not slow and not vault"
    [[ -z "${OLD_PG_MAJOR:-}" ]] && MARKS="${MARKS} and not upgrade"
    CMD=(pytest tests/ -v --timeout=120 -m "${MARKS}"
         --html=/reports/results.html --self-contained-html)
    [[ -n "$WORKERS" ]] && CMD+=(-n "$WORKERS")
fi

# ── Run ───────────────────────────────────────────────────────────────────────
info "Running: ${CMD[*]}"
echo ""

$COMPOSE run --rm \
    -e "PG_MAJOR=${PG_MAJOR}" \
    -e "OLD_PG_MAJOR=${OLD_PG_MAJOR}" \
    "${EXTRA_COMPOSE_ENV[@]}" \
    "${REPORT_MOUNT[@]}" \
    "$SERVICE" \
    "${CMD[@]}"

EXIT_CODE=$?

# ── Cleanup Vault ─────────────────────────────────────────────────────────────
if [[ "$VAULT_MODE" = true ]]; then
    $COMPOSE stop vault 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    ok "Tests passed"
    [[ -f "${REPORT_DIR}/results.html" ]] && \
        info "HTML report: ${REPORT_DIR}/results.html"
else
    warn "Tests finished with exit code ${EXIT_CODE}"
    [[ -f "${REPORT_DIR}/results.html" ]] && \
        info "HTML report: ${REPORT_DIR}/results.html"
fi

exit $EXIT_CODE
