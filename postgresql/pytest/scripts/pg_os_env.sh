#!/usr/bin/env bash
# Shared OS / PostgreSQL install-dir helpers for Ubuntu/Debian and RHEL/OL.
#
# Source from other scripts (do not execute):
#   # shellcheck source=pg_os_env.sh
#   source "$(dirname "$0")/scripts/pg_os_env.sh"
#   pg_os_detect
#   INSTALL_DIR="$(pg_detect_install_dir 18)"
#
# Exports after ``pg_os_detect``:
#   PG_OS_FAMILY   debian | rhel | unknown
#   PG_OS_ID       ID from /etc/os-release (ubuntu, rhel, rocky, almalinux, …)
#   PG_PKG_CMD     apt-get | dnf | yum | ""
#   PG_ARCH        amd64 | arm64 (Debian naming) / used for package downloads
#   PG_ARCH_RPM    x86_64 | aarch64
#
# Intentionally no ``set -euo pipefail`` — this file is meant to be sourced.

pg_os_detect() {
    PG_OS_FAMILY="${PG_OS_FAMILY:-}"
    PG_OS_ID="${PG_OS_ID:-}"
    PG_PKG_CMD="${PG_PKG_CMD:-}"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        PG_OS_ID="${ID:-unknown}"
        case "${ID_LIKE:-}${ID:-}" in
            *debian*|*ubuntu*) PG_OS_FAMILY=debian ;;
            *rhel*|*fedora*|*centos*|*rocky*|*alma*) PG_OS_FAMILY=rhel ;;
        esac
        # Explicit IDs that ID_LIKE may omit on some images.
        case "${ID:-}" in
            ubuntu|debian) PG_OS_FAMILY=debian ;;
            rhel|centos|rocky|almalinux|ol|oracle) PG_OS_FAMILY=rhel ;;
        esac
    fi

    if [[ -z "${PG_OS_FAMILY}" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            PG_OS_FAMILY=debian
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            PG_OS_FAMILY=rhel
        else
            PG_OS_FAMILY=unknown
        fi
    fi

    if [[ "${PG_OS_FAMILY}" == "debian" ]]; then
        PG_PKG_CMD="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        PG_PKG_CMD="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PG_PKG_CMD="yum"
    else
        PG_PKG_CMD=""
    fi

    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64)
            PG_ARCH=amd64
            PG_ARCH_RPM=x86_64
            ;;
        aarch64|arm64)
            PG_ARCH=arm64
            PG_ARCH_RPM=aarch64
            ;;
        *)
            PG_ARCH="${machine}"
            PG_ARCH_RPM="${machine}"
            ;;
    esac

    export PG_OS_FAMILY PG_OS_ID PG_PKG_CMD PG_ARCH PG_ARCH_RPM
}

# Majors validated with pg_tde in the pytest suite (newest first for fallback).
pg_supported_majors() {
    echo "18 17 16"
}

# Normalize PG_MAJOR-style values to an integer major (16.15 / ppg-16 → 16).
pg_normalize_major() {
    local raw="${1:-}"
    local default="${2:-18}"
    raw="${raw#ppg-}"
    raw="${raw#PPG-}"
    if [[ -z "${raw}" ]]; then
        echo "${default}"
        return 0
    fi
    if [[ "${raw}" =~ ^[0-9]+$ ]]; then
        echo "${raw}"
        return 0
    fi
    if [[ "${raw}" =~ ^([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "${default}"
}

# Preferred Percona package install prefixes for a major version.
pg_install_dir_candidates() {
    local major="${1:?major version required}"
    major="$(pg_normalize_major "${major}")"
    if [[ "${PG_OS_FAMILY:-}" == "rhel" ]]; then
        cat <<EOF
/usr/pgsql-${major}
/usr/lib/postgresql/${major}
/opt/postgresql/${major}
/opt/percona/pg${major}
EOF
    else
        cat <<EOF
/usr/lib/postgresql/${major}
/usr/pgsql-${major}
/opt/postgresql/${major}
/opt/percona/pg${major}
EOF
    fi
}

# Echo the first existing install root that has bin/initdb, or empty.
pg_detect_install_dir() {
    local major
    major="$(pg_normalize_major "${1:-${PG_MAJOR:-18}}")"
    local candidate
    if [[ -n "${INSTALL_DIR:-}" && -x "${INSTALL_DIR}/bin/initdb" ]]; then
        echo "${INSTALL_DIR}"
        return 0
    fi
    pg_os_detect
    while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        if [[ -x "${candidate}/bin/initdb" ]]; then
            echo "${candidate}"
            return 0
        fi
    done < <(pg_install_dir_candidates "${major}")
    # Fall back: other supported majors (18, 17, 16).
    local m
    for m in $(pg_supported_majors); do
        [[ "${m}" == "${major}" ]] && continue
        while IFS= read -r candidate; do
            [[ -z "${candidate}" ]] && continue
            if [[ -x "${candidate}/bin/initdb" ]]; then
                echo "${candidate}"
                return 0
            fi
        done < <(pg_install_dir_candidates "${m}")
    done
    return 1
}

# Default install dir string for documentation / script defaults (may not exist).
pg_default_install_dir() {
    local major
    major="$(pg_normalize_major "${1:-${PG_MAJOR:-18}}")"
    pg_os_detect
    if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
        echo "/usr/pgsql-${major}"
    else
        echo "/usr/lib/postgresql/${major}"
    fi
}

# Resolve install dir: existing tree for major (or nearby majors), else OS default path.
# Always prints a path (may not exist yet — use when setting script defaults).
pg_resolve_install_dir() {
    local major
    major="$(pg_normalize_major "${1:-${PG_MAJOR:-18}}")"
    local found=""
    found="$(pg_detect_install_dir "${major}" 2>/dev/null || true)"
    if [[ -n "${found}" ]]; then
        echo "${found}"
        return 0
    fi
    pg_default_install_dir "${major}"
}

# If INSTALL_DIR is unset/empty, set and export it from pg_resolve_install_dir.
# Optional arg: major (default PG_MAJOR or 18). Supported majors: 16, 17, 18.
pg_set_default_install_dir() {
    local major
    major="$(pg_normalize_major "${1:-${PG_MAJOR:-18}}")"
    if [[ -z "${INSTALL_DIR:-}" ]]; then
        INSTALL_DIR="$(pg_resolve_install_dir "${major}")"
    fi
    export INSTALL_DIR
}

# Same for OLD_INSTALL_DIR / NEW_INSTALL_DIR (upgrade scripts).
# Defaults remain 17→18; pass 16 17 for a PG16→PG17 major-upgrade pair.
pg_set_default_upgrade_install_dirs() {
    local old_major
    local new_major
    old_major="$(pg_normalize_major "${1:-17}")"
    new_major="$(pg_normalize_major "${2:-18}")"
    if [[ -z "${OLD_INSTALL_DIR:-}" ]]; then
        OLD_INSTALL_DIR="$(pg_resolve_install_dir "${old_major}")"
    fi
    if [[ -z "${NEW_INSTALL_DIR:-}" ]]; then
        NEW_INSTALL_DIR="$(pg_resolve_install_dir "${new_major}")"
    fi
    if [[ -z "${INSTALL_DIR:-}" ]]; then
        INSTALL_DIR="${NEW_INSTALL_DIR}"
    fi
    export OLD_INSTALL_DIR NEW_INSTALL_DIR INSTALL_DIR
}

# Default source build workdir (not /home/ubuntu-specific).
pg_default_workdir() {
    echo "${HOME:-/tmp}/pgwork"
}

# Install packages needed to build Percona PostgreSQL + pg_tde from source.
# Optional arg: "quiet" suppresses package manager chatter where supported.
pg_install_build_deps() {
    pg_os_detect
    local -a deps
    if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
        # Rough mapping of pg_tde ubuntu-deps.sh → RHEL/OL packages.
        # EPEL may be required for meson/ninja/lcov on some releases.
        deps=(
            gcc gcc-c++ make git wget curl
            bison cmake flex gettext
            libcurl-devel libicu-devel perl-IPC-Run krb5-devel
            openldap-devel lz4-devel numactl-devel pam-devel perl-devel
            readline-devel libselinux-devel openssl-devel systemd-devel
            liburing-devel libxml2-devel libxml2 libxslt-devel libzstd-devel
            lz4 zstd gawk perl pkgconf python3-devel python3-pip
            systemtap-sdt-devel tcl-devel libuuid-devel libxslt zlib-devel
            meson ninja-build
            diffutils patch tar bzip2
        )
        # Optional quality-of-life packages (ignore failures if missing).
        local -a optional=(lcov perltidy docbook-style-xsl docbook-dtds)
        echo "Installing build deps via ${PG_PKG_CMD} (${#deps[@]} packages)..."
        sudo "${PG_PKG_CMD}" -y install "${deps[@]}"
        sudo "${PG_PKG_CMD}" -y install "${optional[@]}" 2>/dev/null || true
    else
        deps=(
            bison cmake docbook-xml docbook-xsl flex gettext
            libcurl4-openssl-dev libicu-dev libipc-run-perl libkrb5-dev
            libldap2-dev liblz4-dev libnuma-dev libpam0g-dev libperl-dev
            libreadline-dev libselinux1-dev libssl-dev libsystemd-dev
            liburing-dev libxml2-dev libxml2-utils libxslt1-dev libzstd-dev
            lz4 mawk perl pkgconf python3-dev python3-pip python3-venv
            systemtap-sdt-dev tcl-dev uuid-dev xsltproc zlib1g-dev zstd
            meson ninja-build
            lcov perltidy
            build-essential git wget curl
        )
        echo "Installing build deps via apt-get (${#deps[@]} packages)..."
        sudo apt-get update -qq
        sudo apt-get install -y "${deps[@]}"
    fi
}

# Install OpenBao (``bao``) from GitHub release .deb / .rpm when missing.
# Returns 0 if bao is available afterward, 1 on download/install failure.
pg_install_openbao_if_missing() {
    if command -v bao >/dev/null 2>&1; then
        return 0
    fi
    pg_os_detect
    local ver="${OPENBAO_VERSION:-2.5.4}"
    local base="https://github.com/openbao/openbao/releases/download/v${ver}"
    local pkg url
    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN
    if [[ "${PG_OS_FAMILY}" == "rhel" ]]; then
        pkg="openbao_${ver}_linux_${PG_ARCH}.rpm"
        url="${base}/${pkg}"
        if ! wget -q -O "${tmp}/${pkg}" "${url}"; then
            pkg="openbao_${ver}_linux_${PG_ARCH_RPM}.rpm"
            url="${base}/${pkg}"
            if ! wget -q -O "${tmp}/${pkg}" "${url}"; then
                return 1
            fi
        fi
        if ! sudo "${PG_PKG_CMD:-dnf}" install -y "${tmp}/${pkg}"; then
            return 1
        fi
    else
        pkg="openbao_${ver}_linux_${PG_ARCH}.deb"
        url="${base}/${pkg}"
        if ! wget -q -O "${tmp}/${pkg}" "${url}"; then
            return 1
        fi
        if ! sudo dpkg -i "${tmp}/${pkg}"; then
            return 1
        fi
    fi
    command -v bao >/dev/null 2>&1
}
