#!/usr/bin/env bash
# Shared INSTALL_DIR defaults for bug repro scripts (Ubuntu/Debian + RHEL/OL).
#
# Source near the top of a script (after set -euo pipefail is fine):
#   # shellcheck source=pg_install_env.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_install_env.sh"
#
# Honours existing INSTALL_DIR / OLD_INSTALL_DIR / NEW_INSTALL_DIR / OLD / NEW.
# Defaults: PG_MAJOR=18; upgrade pairs 17→18 unless PG_OLD_MAJOR / PG_NEW_MAJOR set.

_BUGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pytest/scripts/pg_os_env.sh
source "${_BUGS_DIR}/../pytest/scripts/pg_os_env.sh"
pg_os_detect

PG_MAJOR="${PG_MAJOR:-18}"
PG_OLD_MAJOR="${PG_OLD_MAJOR:-17}"
PG_NEW_MAJOR="${PG_NEW_MAJOR:-${PG_MAJOR}}"

pg_set_default_install_dir "${PG_MAJOR}"

# Upgrade-style aliases used by several repros.
if [[ -z "${OLD:-}" ]]; then
    OLD="$(pg_resolve_install_dir "${PG_OLD_MAJOR}")"
fi
if [[ -z "${NEW:-}" ]]; then
    NEW="$(pg_resolve_install_dir "${PG_NEW_MAJOR}")"
fi
export OLD NEW

if [[ -z "${OLD_INSTALL_DIR:-}" ]]; then
    OLD_INSTALL_DIR="${OLD}"
fi
if [[ -z "${NEW_INSTALL_DIR:-}" ]]; then
    NEW_INSTALL_DIR="${NEW}"
fi
export OLD_INSTALL_DIR NEW_INSTALL_DIR
