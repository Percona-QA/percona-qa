#!/usr/bin/env bash
# build_from_source.sh
# Clone (or update) Percona PostgreSQL, initialise the pg_tde submodule
# (libkmip), then build and install both from source.
#
# Usage:
#   bash build_from_source.sh [BUILD_TYPE] [OPTIONS]
#
# Build types: debug (default), debugoptimized, release, coverage, sanitize
#
# Options:
#   --clean      Wipe pg_tde meson build dir and rebuild from scratch
#   --pg-only    Build/install PostgreSQL only
#   --tde-only   Build/install pg_tde only (PostgreSQL already installed)
#   --deps       Install system dependencies and exit
#
# Directory layout:
#   WORKDIR/
#   ├── postgres/                  Percona PostgreSQL source
#   │   └── contrib/pg_tde/        pg_tde source (part of postgres repo)
#   │       └── src/libkmip/       libkmip submodule (init'd automatically)
#   ├── pginst/                    install prefix
#   └── tde_build/                 pg_tde meson build directory
#
# Rebuild after source changes:
#   bash build_from_source.sh --tde-only          # pg_tde changes only
#   bash build_from_source.sh                     # both (incremental)

set -euo pipefail

# ── CONFIG ─────────────────────────────────────────────────────────────────────

WORKDIR="${WORKDIR:-/home/ubuntu/pgwork}"
INSTALL_DIR="${WORKDIR}/pginst/18"
PG_SRC="${WORKDIR}/postgres"
TDE_SRC="${PG_SRC}/contrib/pg_tde"
TDE_BUILD="${WORKDIR}/tde_build"

PG_REPO="${PG_REPO:-https://github.com/percona/postgres.git}"
PG_BRANCH="${PG_BRANCH:-PSP_REL_18_STABLE}"

JOBS="${JOBS:-$(nproc)}"

# ── parse args ─────────────────────────────────────────────────────────────────

BUILD_TYPE="debug"
DO_CLEAN=0; DO_PG=1; DO_TDE=1; DO_DEPS_ONLY=0

for arg in "$@"; do
    case $arg in
        debug|debugoptimized|release|sanitize|coverage) BUILD_TYPE="$arg" ;;
        --clean)     DO_CLEAN=1 ;;
        --pg-only)   DO_TDE=0 ;;
        --tde-only)  DO_PG=0 ;;
        --deps)      DO_DEPS_ONLY=1 ;;
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

# Package list from pg_tde/ci_scripts/ubuntu-deps.sh
DEPS=(
    bison docbook-xml docbook-xsl flex gettext
    libcurl4-openssl-dev libicu-dev libipc-run-perl libkrb5-dev
    libldap2-dev liblz4-dev libnuma-dev libpam0g-dev libperl-dev
    libreadline-dev libselinux1-dev libssl-dev libsystemd-dev
    liburing-dev libxml2-dev libxml2-utils libxslt1-dev libzstd-dev
    lz4 mawk perl pkgconf python3-dev python3-pip python3-venv
    systemtap-sdt-dev tcl-dev uuid-dev xsltproc zlib1g-dev zstd
    meson ninja-build
    lcov perltidy
)

sudo apt-get update -qq
sudo apt-get install -y "${DEPS[@]}"
ok "System packages installed"

pip3 install --quiet pykmip 2>/dev/null \
    || warn "pykmip install failed (optional — needed for KMIP tests)"

if ! command -v bao &>/dev/null; then
    ARCH=$(dpkg --print-architecture)
    BAO_DEB="bao_2.4.3_linux_${ARCH}.deb"
    wget -q "https://github.com/openbao/openbao/releases/download/v2.4.3/${BAO_DEB}"
    sudo dpkg -i "$BAO_DEB" && rm -f "$BAO_DEB"
    ok "OpenBao installed"
else
    ok "OpenBao already present"
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

# ── 3. clone / update postgres ─────────────────────────────────────────────────

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

# Initialise the libkmip submodule (and any others) inside pg_tde
info "Initialising submodules (libkmip)"
git -C "$PG_SRC" submodule update --init --recursive
ok "Submodules ready"

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
    step "4-5. PostgreSQL — skipped (--tde-only)"
    [[ -x "$INSTALL_DIR/bin/pg_config" ]] \
        || fail "pg_config not found at $INSTALL_DIR/bin — build PostgreSQL first"
fi

# ── 5. build pg_tde ────────────────────────────────────────────────────────────

if [[ "$DO_TDE" -eq 1 ]]; then
    [[ -d "$TDE_SRC" ]] \
        || fail "pg_tde not found at $TDE_SRC — run 'git submodule update --init --recursive' in $PG_SRC"

    step "6. Build pg_tde (meson) — type: $BUILD_TYPE"

    PG_CONFIG="$INSTALL_DIR/bin/pg_config"

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

    cd "$TDE_SRC"
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
    ok "pg_tde installed"

    CTRL=$("$PG_CONFIG" --sharedir)/extension/pg_tde.control
    [[ -f "$CTRL" ]] && ok "pg_tde.control: $CTRL" \
        || warn "pg_tde.control not found — check meson install output"
fi

# ── 6. env file ────────────────────────────────────────────────────────────────

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

# ── 7. summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Build complete!  (type: ${BUILD_TYPE})${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
[[ "$DO_PG" -eq 1 ]] && echo "  PostgreSQL : $("$INSTALL_DIR/bin/postgres" --version 2>&1 | head -1)"
echo "  Binaries   : $INSTALL_DIR/bin"
echo "  Env file   : $ENV_FILE"
echo ""
echo "  Quick start:"
echo "    source $ENV_FILE"
echo "    initdb --no-data-checksums -D \$PGDATA"
echo "    echo \"shared_preload_libraries = 'pg_tde'\" >> \$PGDATA/postgresql.conf"
echo "    pg_ctl start -D \$PGDATA -l \$PGDATA/server.log"
echo "    psql -c \"CREATE EXTENSION pg_tde;\""
echo ""
echo "  Rebuild after source changes:"
echo "    bash $(realpath "$0") --tde-only      # pg_tde only"
echo "    bash $(realpath "$0")                 # both (incremental)"
echo ""
