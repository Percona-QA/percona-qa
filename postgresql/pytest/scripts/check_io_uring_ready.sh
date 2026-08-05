#!/usr/bin/env bash
# Quick io_uring readiness check (build + system) with optional auto-fix.
# Works on Ubuntu/Debian and RHEL/OL/Rocky (same checks; OS-aware INSTALL_DIR).
# Full runbook: postgresql/pytest/docs/io_uring_system_setup.md
#
# Usage:
#   ./scripts/check_io_uring_ready.sh              # check + apply memlock/sysctl
#   ./scripts/check_io_uring_ready.sh --check-only # report only, do not change system
#   INSTALL_DIR=/usr/lib/postgresql/18 USER_NAME=ubuntu ./scripts/check_io_uring_ready.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pg_os_env.sh
source "${SCRIPT_DIR}/pg_os_env.sh"
pg_os_detect
pg_set_default_install_dir "${PG_MAJOR:-18}"

USER_NAME="${USER_NAME:-$(whoami)}"
LIMITS_FILE="${LIMITS_FILE:-/etc/security/limits.conf}"
LIMITS_DROPIN="${LIMITS_DROPIN:-/etc/security/limits.d/99-io-uring-memlock.conf}"
SYSCTL_DROPIN="${SYSCTL_DROPIN:-/etc/sysctl.d/99-io-uring.conf}"
EXAMPLE_INSTALL="$(pg_default_install_dir "${PG_MAJOR:-18}")"
CHECK_ONLY=0
APPLY="${APPLY:-1}"

for arg in "$@"; do
  case "$arg" in
    --check-only|-n) CHECK_ONLY=1; APPLY=0 ;;
    --apply|-f)      APPLY=1; CHECK_ONLY=0 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

BUILD_OK=0
MEMLOCK_OK=0
KERN_OK=0

echo "=== io_uring readiness ==="
echo "OS family  : ${PG_OS_FAMILY} (${PG_OS_ID:-unknown})"
echo "INSTALL_DIR: ${INSTALL_DIR}"
echo "USER       : ${USER_NAME}"
echo "Mode       : $([[ "$APPLY" == 1 ]] && echo 'check + apply' || echo 'check-only')"
echo "Doc        : postgresql/pytest/docs/io_uring_system_setup.md"
echo

if [[ ! -x "$INSTALL_DIR/bin/initdb" ]]; then
  echo "FAIL: $INSTALL_DIR/bin/initdb not found"
  echo
  echo "Set INSTALL_DIR to your PostgreSQL prefix for this OS, e.g.:"
  echo "  # Ubuntu/Debian:  export INSTALL_DIR=/usr/lib/postgresql/18"
  echo "  # RHEL/OL:        export INSTALL_DIR=/usr/pgsql-18"
  echo "  # Auto for this host: export INSTALL_DIR=${EXAMPLE_INSTALL}"
  exit 1
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

echo "--- 1. PostgreSQL build (initdb) ---"
if "$INSTALL_DIR/bin/initdb" -D "$PROBE" --set io_method=io_uring >/dev/null 2>&1; then
  echo "PASS: initdb accepts io_method=io_uring"
  BUILD_OK=1
else
  echo "FAIL: initdb rejects io_method=io_uring"
  echo "  This install may not be built with liburing (--with-liburing)."
  echo "  initdb output:"
  rm -rf "$PROBE" 2>/dev/null || true
  mkdir -p "$PROBE"
  "$INSTALL_DIR/bin/initdb" -D "$PROBE" --set io_method=io_uring 2>&1 | head -8 | sed 's/^/    /' || true
fi
rm -rf "$PROBE" 2>/dev/null || true

_memlock_is_unlimited() {
  local soft hard
  soft="$(ulimit -l)"
  hard="$(ulimit -Hl 2>/dev/null || ulimit -l)"
  [[ "$soft" == "unlimited" && "$hard" == "unlimited" ]]
}

_persist_memlock_limits() {
  local marker="# io_uring: allow locked memory for PostgreSQL (percona-qa check_io_uring_ready.sh)"
  local body
  body=$(cat <<LIMITS
${marker}
${USER_NAME}    soft    memlock    unlimited
${USER_NAME}    hard    memlock    unlimited
LIMITS
)
  if [[ -f "${LIMITS_DROPIN}" ]] && grep -q "memlock.*unlimited" "${LIMITS_DROPIN}" 2>/dev/null; then
    echo "  Persistent limits already present in ${LIMITS_DROPIN}"
    return 0
  fi
  if grep -qE "^[[:space:]]*${USER_NAME}[[:space:]]+.*memlock" "${LIMITS_FILE}" 2>/dev/null; then
    echo "  Persistent limits already present in ${LIMITS_FILE}"
    return 0
  fi
  echo "  Writing persistent memlock limits to ${LIMITS_DROPIN}"
  echo "${body}" | sudo tee "${LIMITS_DROPIN}" >/dev/null
}

_raise_memlock_now() {
  # 1) Soft raise if hard already allows it.
  if ulimit -l unlimited 2>/dev/null && _memlock_is_unlimited; then
    echo "  Raised memlock via ulimit -l unlimited"
    return 0
  fi
  # 2) Raise hard+soft for *this* process without re-login (needs sudo).
  if command -v prlimit >/dev/null 2>&1; then
    if sudo prlimit --pid "$$" --memlock=unlimited:unlimited 2>/dev/null; then
      # Refresh shell soft limit to match.
      ulimit -l unlimited 2>/dev/null || true
      if _memlock_is_unlimited || [[ "$(ulimit -l)" == "unlimited" ]]; then
        echo "  Raised memlock for this shell via sudo prlimit"
        return 0
      fi
    fi
  fi
  # 3) Last resort: root shell ulimit cannot change parent; advise re-login
  #    after persistent limits are written.
  return 1
}

echo
echo "--- 2. memlock (ulimit -l) ---"
echo "ulimit -l (soft) = $(ulimit -l)"
echo "ulimit -Hl (hard) = $(ulimit -Hl 2>/dev/null || echo '?')"
if _memlock_is_unlimited || [[ "$(ulimit -l)" == "unlimited" ]]; then
  echo "PASS: memlock unlimited for current shell"
  MEMLOCK_OK=1
else
  echo "FAIL: memlock is not unlimited (io_uring needs locked memory)"
  if [[ "$APPLY" == 1 ]]; then
    echo "Applying memlock fix..."
    _persist_memlock_limits || true
    if _raise_memlock_now; then
      echo "ulimit -l after fix = $(ulimit -l)"
      if [[ "$(ulimit -l)" == "unlimited" ]]; then
        echo "PASS: memlock unlimited for current shell"
        MEMLOCK_OK=1
      fi
    else
      echo "WARN: could not raise memlock for this process."
      echo "  Persistent limits were written (if sudo worked); log out and back in,"
      echo "  or re-run:  sudo prlimit --pid \$\$ --memlock=unlimited:unlimited"
      echo "  then:       ulimit -l unlimited"
    fi
  else
    echo "  Re-run without --check-only to apply (sudo prlimit + limits.d)."
  fi
fi

echo
echo "--- 3. kernel.io_uring_disabled ---"
if [[ -r /proc/sys/kernel/io_uring_disabled ]]; then
  VAL=$(cat /proc/sys/kernel/io_uring_disabled)
  echo "kernel.io_uring_disabled = $VAL"
  case "$VAL" in
    0)
      echo "PASS: io_uring allowed for all users"
      KERN_OK=1
      ;;
    1|2)
      echo "FAIL: io_uring restricted (value ${VAL}; 0=all, 1=off, 2=admin-only)"
      if [[ "$APPLY" == 1 ]]; then
        echo "Applying kernel.io_uring_disabled=0..."
        if sudo sysctl -w kernel.io_uring_disabled=0 >/dev/null \
          && echo 'kernel.io_uring_disabled = 0' | sudo tee "${SYSCTL_DROPIN}" >/dev/null; then
          VAL=$(cat /proc/sys/kernel/io_uring_disabled)
          echo "kernel.io_uring_disabled after fix = $VAL"
          if [[ "$VAL" == "0" ]]; then
            echo "PASS: io_uring allowed for all users"
            KERN_OK=1
          fi
        else
          echo "WARN: sudo sysctl failed"
        fi
      else
        echo "  Re-run without --check-only to apply (sudo sysctl)."
      fi
      ;;
    *)
      echo "FAIL: unexpected value $VAL"
      ;;
  esac
else
  echo "SKIP: /proc/sys/kernel/io_uring_disabled not available (non-Linux?)"
  KERN_OK=1
fi

echo
echo "=========================================="
if [[ "$BUILD_OK" == 1 && "$MEMLOCK_OK" == 1 && "$KERN_OK" == 1 ]]; then
  echo "RESULT: io_uring is READY"
  echo "  Note: child shells inherit this session's raised memlock."
  echo "  New SSH logins use ${LIMITS_DROPIN} after PAM applies it."
  echo "  pytest:  pytest tests/ --io-method=io_uring -v"
  echo "           pytest tests/ --io-method-matrix -v"
  exit 0
fi

echo "RESULT: io_uring is NOT ready"
if [[ "$BUILD_OK" != 1 ]]; then
  echo "  - Build: need PG 18+ with liburing (INSTALL_DIR=${INSTALL_DIR})"
fi
if [[ "$MEMLOCK_OK" != 1 ]]; then
  echo "  - memlock: still $(ulimit -l); try:"
  echo "      sudo prlimit --pid \$\$ --memlock=unlimited:unlimited"
  echo "      ulimit -l unlimited"
  echo "    or log out/in after limits.d write"
fi
if [[ "$KERN_OK" != 1 ]]; then
  echo "  - kernel: sudo sysctl -w kernel.io_uring_disabled=0"
fi
echo "Doc: postgresql/pytest/docs/io_uring_system_setup.md"
exit 1
