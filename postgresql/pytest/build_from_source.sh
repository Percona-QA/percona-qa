#!/usr/bin/env bash
# build_from_source.sh
# Clone (or update) Percona PostgreSQL, then build and install PostgreSQL
# and pg_tde from source. Optionally install pg_stat_monitor (opt-in).
#
# Supports Ubuntu/Debian (apt) and RHEL/OL/Rocky (dnf/yum).
# Default WORKDIR is $HOME/pgwork (override with WORKDIR=...).
# Default install is PG 18 (INSTALL_DIR=$WORKDIR/pginst/18, PG_BRANCH=PSP_REL_18_STABLE).
# For PG 16.15 + pg_tde:
#   INSTALL_DIR=$HOME/pgwork/pginst/16 PG_BRANCH=PSP_REL_16_STABLE bash build_from_source.sh
# See docs/pg16.md.
#
# Usage:
#   bash build_from_source.sh [BUILD_TYPE] [OPTIONS]
#
# Build types: debug (default), debugoptimized, release, coverage, sanitize
#
# Options:
#   --clean      Wipe pg_tde meson build dir (and clean pg_stat_monitor) then rebuild
#   --pg-only    Build/install PostgreSQL only
#   --tde-only   Build/install pg_tde only (skips PostgreSQL clone/build;
#                use with packaged or previously built INSTALL_DIR)
#   --psm        Also build/install pg_stat_monitor (off by default)
#   --psm-only   Build/install pg_stat_monitor only (PostgreSQL already installed)
#   --deps       Install system dependencies and exit
#
# Directory layout:
#   WORKDIR/
#   ├── postgres/                  Percona PostgreSQL source
#   ├── pg_tde/                    pg_tde source (fallback if not in contrib/)
#   ├── pg_stat_monitor/           pg_stat_monitor source (when --psm / --psm-only)
#   ├── pginst/                    install prefix
#   └── tde_build/                 pg_tde meson build directory
#
# Rebuild after source changes:
#   bash build_from_source.sh --tde-only          # pg_tde changes only
#   bash build_from_source.sh --psm-only          # pg_stat_monitor only
#   bash build_from_source.sh --psm               # PG + pg_tde + pg_stat_monitor
#   bash build_from_source.sh                     # PG + pg_tde (incremental)

set -euo pipefail

# ── CONFIG ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pg_os_env.sh
source "${SCRIPT_DIR}/scripts/pg_os_env.sh"
pg_os_detect

WORKDIR="${WORKDIR:-$(pg_default_workdir)}"
INSTALL_DIR="${INSTALL_DIR:-${WORKDIR}/pginst/18}"
PG_SRC="${PG_SRC:-${WORKDIR}/postgres}"
TDE_SRC="${TDE_SRC:-${PG_SRC}/contrib/pg_tde}"
TDE_FALLBACK_SRC="${TDE_FALLBACK_SRC:-${WORKDIR}/pg_tde}"
TDE_BUILD="${TDE_BUILD:-${WORKDIR}/tde_build}"
PSM_SRC="${PSM_SRC:-${WORKDIR}/pg_stat_monitor}"

PG_REPO="${PG_REPO:-https://github.com/percona/postgres.git}"
PG_BRANCH="${PG_BRANCH:-PSP_REL_18_STABLE}"
TDE_REPO="${TDE_REPO:-https://github.com/percona/pg_tde.git}"
TDE_BRANCH="${TDE_BRANCH:-main}"
PSM_REPO="${PSM_REPO:-https://github.com/percona/pg_stat_monitor.git}"
PSM_BRANCH="${PSM_BRANCH:-main}"

JOBS="${JOBS:-$(nproc)}"

# ── parse args ─────────────────────────────────────────────────────────────────

BUILD_TYPE="debug"
DO_CLEAN=0; DO_PG=1; DO_TDE=1; DO_PSM=0; DO_DEPS_ONLY=0

for arg in "$@"; do
    case $arg in
        debug|debugoptimized|release|sanitize|coverage) BUILD_TYPE="$arg" ;;
        --clean)     DO_CLEAN=1 ;;
        --pg-only)   DO_TDE=0 ;;
        --tde-only)  DO_PG=0 ;;
        --psm)       DO_PSM=1 ;;
        --psm-only)  DO_PG=0; DO_TDE=0; DO_PSM=1 ;;
        --deps)      DO_DEPS_ONLY=1 ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── colours ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
step() { echo ""; echo -e "${CYAN}══════════════════════════════════════════${NC}"; echo -e "  $*"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ── 1. system dependencies ─────────────────────────────────────────────────────

step "1. System dependencies"

info "OS family=${PG_OS_FAMILY} id=${PG_OS_ID:-?} pkg=${PG_PKG_CMD:-n/a}"
pg_install_build_deps
ok "System packages installed"

if pg_install_openbao_if_missing; then
    if command -v bao &>/dev/null; then
        ok "OpenBao present ($(bao version 2>/dev/null | head -1 || bao --version 2>/dev/null | head -1))"
    fi
else
    warn "OpenBao install skipped/failed — vault/OpenBao pytest tests may skip"
fi

if [[ "$DO_DEPS_ONLY" -eq 1 ]]; then
    ok "Dependencies done. Re-run without --deps to build."
    exit 0
fi

# ── 2. directories ─────────────────────────────────────────────────────────────

step "2. Workspace"
mkdir -p "$WORKDIR" "$INSTALL_DIR"
ok "WORKDIR     : $WORKDIR"
ok "INSTALL_DIR : $INSTALL_DIR"

# ── 3. clone / update postgres (only when building PostgreSQL) ─────────────────

if [[ "$DO_PG" -eq 1 ]]; then
    step "3. Percona PostgreSQL source ($PG_BRANCH)"

    if [[ ! -d "$PG_SRC/.git" ]]; then
        info "Cloning $PG_REPO (branch: $PG_BRANCH)"
        git clone --branch "$PG_BRANCH" "$PG_REPO" "$PG_SRC"
        ok "Cloned"
    else
        info "Updating $PG_SRC"
        git -C "$PG_SRC" fetch origin "$PG_BRANCH"
        git -C "$PG_SRC" checkout "$PG_BRANCH"
        git -C "$PG_SRC" merge --ff-only "origin/$PG_BRANCH" \
            || warn "Fast-forward failed — local changes present, skipping pull"
        ok "$(git -C "$PG_SRC" log -1 --oneline)"
    fi

    # Initialise submodules if the selected PostgreSQL tree uses them.
    info "Initialising submodules (if present)"
    git -C "$PG_SRC" submodule update --init --recursive
    ok "Submodules ready"
else
    step "3. Percona PostgreSQL source — skipped (--tde-only / --psm-only)"
    info "Using existing install at $INSTALL_DIR (no PG clone)"
fi

# ── 4. build PostgreSQL ────────────────────────────────────────────────────────

if [[ "$DO_PG" -eq 1 ]]; then
    step "4. Configure PostgreSQL (./configure)"

    CONFIGURE_ARGS="--prefix=$INSTALL_DIR --enable-debug --enable-tap-tests"
    INSTALL_INJECTION_POINTS=0

    case "$BUILD_TYPE" in
        debug)
            CONFIGURE_ARGS+=" --enable-cassert --enable-injection-points"
            INSTALL_INJECTION_POINTS=1
            ;;
        debugoptimized)
            export CFLAGS="-O2"
            CONFIGURE_ARGS+=" --enable-cassert --enable-injection-points"
            INSTALL_INJECTION_POINTS=1
            ;;
        release)
            ;;
        coverage)
            CONFIGURE_ARGS+=" --enable-injection-points --enable-coverage"
            INSTALL_INJECTION_POINTS=1
            ;;
        sanitize)
            export CFLAGS="-fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer -fno-inline-functions"
            ;;
    esac

    [[ "$(uname -s)" == "Linux" ]] && CONFIGURE_ARGS+=" --with-liburing"

    cd "$PG_SRC"
    # shellcheck disable=SC2086
    ./configure $CONFIGURE_ARGS
    ok "configure done"

    step "5. Build and install PostgreSQL (make install-world)"
    make install-world -s -j"$JOBS"
    ok "make install-world done"

    if [[ "$INSTALL_INJECTION_POINTS" -eq 1 ]]; then
        make install -j"$JOBS" -s -C src/test/modules/injection_points
        ok "injection_points installed"
    fi

    ok "Installed: $("$INSTALL_DIR/bin/postgres" --version 2>&1 | head -1)"
else
    step "4-5. PostgreSQL — skipped"
    [[ -x "$INSTALL_DIR/bin/pg_config" ]] \
        || fail "pg_config not found at $INSTALL_DIR/bin — build PostgreSQL first"
fi

# ── 5. resolve + build pg_tde ──────────────────────────────────────────────────

if [[ "$DO_TDE" -eq 1 ]]; then
    if [[ ! -d "$TDE_SRC" ]]; then
        warn "pg_tde not found at $TDE_SRC"
        warn "Falling back to standalone pg_tde repo: $TDE_REPO ($TDE_BRANCH)"
        TDE_SRC="$TDE_FALLBACK_SRC"
    fi

    if [[ ! -d "$TDE_SRC/.git" && ! -f "$TDE_SRC/meson.build" ]]; then
        info "Cloning pg_tde into $TDE_SRC"
        git clone --branch "$TDE_BRANCH" "$TDE_REPO" "$TDE_SRC"
        ok "pg_tde cloned"
    elif [[ -d "$TDE_SRC/.git" ]]; then
        info "Updating pg_tde source at $TDE_SRC"
        git -C "$TDE_SRC" fetch origin "$TDE_BRANCH" || true
        git -C "$TDE_SRC" checkout "$TDE_BRANCH" || true
        git -C "$TDE_SRC" merge --ff-only "origin/$TDE_BRANCH" \
            || warn "pg_tde fast-forward skipped (local changes or detached HEAD)"
        ok "$(git -C "$TDE_SRC" log -1 --oneline)"
    fi

    PG_CONFIG="$INSTALL_DIR/bin/pg_config"
    if [[ ! -f "$TDE_SRC/meson.build" && ! -f "$TDE_SRC/Makefile" ]]; then
        warn "Existing pg_tde tree does not look buildable: $TDE_SRC"
        warn "Re-cloning from $TDE_REPO ($TDE_BRANCH)"
        rm -rf "$TDE_SRC"
        git clone --branch "$TDE_BRANCH" "$TDE_REPO" "$TDE_SRC"
        ok "pg_tde re-cloned"
    fi

    # Ensure pg_tde nested deps (for example libkmip) are present.
    if [[ -d "$TDE_SRC/.git" ]]; then
        info "Initialising pg_tde submodules (libkmip)"
        git -C "$TDE_SRC" submodule update --init --recursive
        ok "pg_tde submodules ready"
    fi

    if [[ -f "$TDE_SRC/meson.build" ]]; then
        step "6. Build pg_tde (meson) — type: $BUILD_TYPE"

        MESON_ARGS="--buildtype=$BUILD_TYPE -Dpg_config=$PG_CONFIG -Dwerror=true"
        case "$BUILD_TYPE" in
            coverage)
                MESON_ARGS="--buildtype=debug -Dpg_config=$PG_CONFIG -Dwerror=true -Db_coverage=true"
                ;;
            sanitize)
                MESON_ARGS="--buildtype=debug -Dpg_config=$PG_CONFIG -Dwerror=true"
                MESON_ARGS+=" -Dc_args=['-fsanitize=address','-fsanitize=undefined','-fno-omit-frame-pointer','-fno-inline-functions']"
                MESON_ARGS+=" -Dc_link_args=['-fsanitize=address','-fsanitize=undefined']"
                ;;
        esac

        if [[ "$DO_CLEAN" -eq 1 && -d "$TDE_BUILD" ]]; then
            info "Wiping pg_tde build dir: $TDE_BUILD"
            rm -rf "$TDE_BUILD"
        fi

        command -v cmake >/dev/null \
            || fail "cmake not found — required for subproject libkmip (apt install cmake)"

        cd "$TDE_SRC"
        # Incomplete dirs (e.g. partial rm, failed setup) break meson configure.
        if [[ -d "$TDE_BUILD" && ! -f "$TDE_BUILD/meson-private/build.dat" ]]; then
            warn "Stale pg_tde meson dir (missing meson-private/build.dat) — removing"
            rm -rf "$TDE_BUILD"
        fi

        if [[ ! -d "$TDE_BUILD" ]]; then
            # shellcheck disable=SC2086
            meson setup $MESON_ARGS "$TDE_BUILD"
            ok "meson setup done"
        else
            info "Build dir exists — reconfiguring"
            # shellcheck disable=SC2086
            meson configure $MESON_ARGS "$TDE_BUILD"
            ok "meson reconfigure done"
        fi

        meson install -C "$TDE_BUILD"
        ok "pg_tde installed (meson)"
    elif [[ -f "$TDE_SRC/Makefile" ]]; then
        step "6. Build pg_tde (PGXS make) — type: $BUILD_TYPE"
        cd "$TDE_SRC"
        if [[ "$DO_CLEAN" -eq 1 ]]; then
            make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" clean || true
        fi
        make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" -j"$JOBS"
        make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" install
        ok "pg_tde installed (PGXS)"
    else
        fail "pg_tde source invalid at $TDE_SRC (neither meson.build nor Makefile found)"
    fi

    CTRL=$("$PG_CONFIG" --sharedir)/extension/pg_tde.control
    [[ -f "$CTRL" ]] && ok "pg_tde.control: $CTRL" \
        || warn "pg_tde.control not found — check meson install output"

    # Metadata for pytest session header (branch + commit of this install).
    # Packaged PG sharedirs under /usr are often only root-writable; never abort
    # the build if we cannot place the file there.
    _SHAREDIR=$("$PG_CONFIG" --sharedir)
    _build_info_body() {
        echo "# Written by build_from_source.sh — used by pytest report header"
        echo "source=${TDE_SRC}"
        if [[ -d "${TDE_SRC}/.git" || -f "${TDE_SRC}/.git" ]]; then
            echo "branch=$(git -C "$TDE_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo DETACHED)"
            echo "commit=$(git -C "$TDE_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
            if [[ -n "$(git -C "$TDE_SRC" status --porcelain 2>/dev/null || true)" ]]; then
                echo "dirty=1"
            else
                echo "dirty=0"
            fi
        else
            echo "branch=${TDE_BRANCH:-unknown}"
            echo "commit=unknown"
            echo "dirty=0"
        fi
        echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
    _write_build_info() {
        local dest="$1"
        local parent
        parent=$(dirname "$dest")
        if [[ -w "$parent" ]] || [[ -e "$dest" && -w "$dest" ]]; then
            _build_info_body > "$dest"
            return 0
        fi
        # Non-interactive sudo (common on CI / passwordless lab VMs).
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            _build_info_body | sudo -n tee "$dest" >/dev/null
            return 0
        fi
        return 1
    }

    _BUILD_INFO=""
    for _cand in \
        "${_SHAREDIR}/pg_tde_build_info" \
        "${INSTALL_DIR}/pg_tde_build_info" \
        "${WORKDIR}/pg_tde_build_info"
    do
        if _write_build_info "$_cand"; then
            _BUILD_INFO="$_cand"
            break
        fi
    done

    if [[ -n "$_BUILD_INFO" ]]; then
        for _mirror in \
            "${_SHAREDIR}/pg_tde_build_info" \
            "${INSTALL_DIR}/pg_tde_build_info" \
            "${WORKDIR}/pg_tde_build_info"
        do
            [[ "$_mirror" == "$_BUILD_INFO" ]] && continue
            _write_build_info "$_mirror" 2>/dev/null || \
                cp -f "$_BUILD_INFO" "$_mirror" 2>/dev/null || true
        done
        ok "pg_tde build info: $_BUILD_INFO"
    else
        warn "could not write pg_tde_build_info under ${_SHAREDIR}, ${INSTALL_DIR}, or ${WORKDIR}"
        warn "pytest session header will omit pg_tde git metadata (install is fine)"
        warn "to record it:  sudo tee ${_SHAREDIR}/pg_tde_build_info >/dev/null <<'EOF'"
        warn "  (re-run with write access to sharedir, or export WORKDIR to a writable tree)"
    fi
else
    info "pg_tde — skipped (use default build or --tde-only; not requested with --pg-only / --psm-only)"
fi

# ── 6. resolve + build pg_stat_monitor (opt-in) ─────────────────────────────────

if [[ "$DO_PSM" -eq 1 ]]; then
    PG_CONFIG="$INSTALL_DIR/bin/pg_config"
    [[ -x "$PG_CONFIG" ]] \
        || fail "pg_config not found at $INSTALL_DIR/bin — build PostgreSQL first"

    step "6b. pg_stat_monitor (PGXS) — branch: $PSM_BRANCH"

    if [[ ! -d "$PSM_SRC/.git" && ! -f "$PSM_SRC/Makefile" ]]; then
        info "Cloning $PSM_REPO (branch: $PSM_BRANCH) → $PSM_SRC"
        git clone --branch "$PSM_BRANCH" "$PSM_REPO" "$PSM_SRC"
        ok "pg_stat_monitor cloned"
    elif [[ -d "$PSM_SRC/.git" ]]; then
        info "Updating pg_stat_monitor source at $PSM_SRC"
        git -C "$PSM_SRC" fetch origin "$PSM_BRANCH" || true
        git -C "$PSM_SRC" checkout "$PSM_BRANCH" || true
        git -C "$PSM_SRC" merge --ff-only "origin/$PSM_BRANCH" \
            || warn "pg_stat_monitor fast-forward skipped (local changes or detached HEAD)"
        ok "$(git -C "$PSM_SRC" log -1 --oneline)"
    fi

    if [[ ! -f "$PSM_SRC/Makefile" ]]; then
        fail "pg_stat_monitor Makefile not found at $PSM_SRC (need PGXS build)"
    fi

    # meson.build is in-tree contrib style; standalone install uses Makefile + PGXS.
    cd "$PSM_SRC"
    if [[ "$DO_CLEAN" -eq 1 ]]; then
        make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" clean || true
    fi
    make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" -j"$JOBS"
    make USE_PGXS=1 PG_CONFIG="$PG_CONFIG" install
    ok "pg_stat_monitor installed (PGXS)"

    PSM_CTRL=$("$PG_CONFIG" --sharedir)/extension/pg_stat_monitor.control
    [[ -f "$PSM_CTRL" ]] && ok "pg_stat_monitor.control: $PSM_CTRL" \
        || warn "pg_stat_monitor.control not found — check make install output"
else
    info "pg_stat_monitor — skipped (pass --psm or --psm-only to install)"
fi

# ── 7. env file ────────────────────────────────────────────────────────────────

step "7. Environment file"
ENV_FILE="$WORKDIR/pg_env.sh"
cat > "$ENV_FILE" <<EOF
# Source this before using the custom PostgreSQL build.
export INSTALL_DIR="$INSTALL_DIR"
export PATH="$INSTALL_DIR/bin:\$PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export PGDATA="$INSTALL_DIR/data"
EOF
ok "Written: $ENV_FILE"
info "Activate with:  source $ENV_FILE"

# ── 8. summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Build complete!  (type: ${BUILD_TYPE})${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
[[ "$DO_PG" -eq 1 ]] && echo "  PostgreSQL : $("$INSTALL_DIR/bin/postgres" --version 2>&1 | head -1)"
[[ "$DO_TDE" -eq 1 ]] && echo "  pg_tde     : installed"
[[ "$DO_PSM" -eq 1 ]] && echo "  pg_stat_monitor : installed" \
    || echo "  pg_stat_monitor : not installed (use --psm / --psm-only)"
echo "  Binaries   : $INSTALL_DIR/bin"
echo "  Env file   : $ENV_FILE"
echo ""
echo "  Quick start:"
echo "    source $ENV_FILE"
echo "    initdb --no-data-checksums -D \$PGDATA"
if [[ "$DO_PSM" -eq 1 ]]; then
    echo "    echo \"shared_preload_libraries = 'pg_tde,pg_stat_monitor'\" >> \$PGDATA/postgresql.conf"
else
    echo "    echo \"shared_preload_libraries = 'pg_tde'\" >> \$PGDATA/postgresql.conf"
fi
echo "    pg_ctl start -D \$PGDATA -l \$PGDATA/server.log"
echo "    psql -c \"CREATE EXTENSION pg_tde;\""
[[ "$DO_PSM" -eq 1 ]] && echo "    psql -c \"CREATE EXTENSION pg_stat_monitor;\""
echo ""
echo "  Rebuild after source changes:"
echo "    bash $(realpath "$0") --tde-only      # pg_tde only"
echo "    bash $(realpath "$0") --psm-only      # pg_stat_monitor only"
echo "    bash $(realpath "$0") --psm           # PG + pg_tde + pg_stat_monitor"
echo "    bash $(realpath "$0")                 # PG + pg_tde (incremental)"
echo ""
