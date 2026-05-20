#!/usr/bin/env bash
# Quick io_uring readiness check (build + system). See docs/io_uring_system_setup.md.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/pgsql-18}"
USER_NAME="${USER_NAME:-$(whoami)}"

echo "=== io_uring readiness ==="
echo "INSTALL_DIR=$INSTALL_DIR"
echo "USER=$USER_NAME"
echo

if [[ ! -x "$INSTALL_DIR/bin/initdb" ]]; then
  echo "FAIL: $INSTALL_DIR/bin/initdb not found"
  exit 1
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

echo "--- 1. PostgreSQL build (initdb) ---"
if "$INSTALL_DIR/bin/initdb" -D "$PROBE" --set io_method=io_uring >/dev/null 2>&1; then
  echo "PASS: initdb accepts io_method=io_uring"
  BUILD_OK=1
else
  echo "FAIL: initdb rejects io_method=io_uring (build without liburing?)"
  BUILD_OK=0
fi
rm -rf "$PROBE" && mkdir -p "$PROBE"

echo
echo "--- 2. memlock (ulimit -l) ---"
ML=$(ulimit -l)
echo "ulimit -l = $ML"
if [[ "$ML" == "unlimited" ]]; then
  echo "PASS: memlock unlimited"
  MEMLOCK_OK=1
else
  echo "FAIL: need unlimited memlock for $USER_NAME in /etc/security/limits.conf"
  echo "      then log out and back in"
  MEMLOCK_OK=0
fi

echo
echo "--- 3. kernel.io_uring_disabled ---"
if [[ -r /proc/sys/kernel/io_uring_disabled ]]; then
  VAL=$(cat /proc/sys/kernel/io_uring_disabled)
  echo "kernel.io_uring_disabled = $VAL"
  case "$VAL" in
    0) echo "PASS: io_uring allowed for all users"; KERN_OK=1 ;;
    1) echo "FAIL: io_uring disabled globally"; KERN_OK=0 ;;
    2) echo "FAIL: io_uring admin-only; run: sudo sysctl -w kernel.io_uring_disabled=0"; KERN_OK=0 ;;
    *) echo "WARN: unknown value"; KERN_OK=0 ;;
  esac
else
  echo "SKIP: not Linux or proc not available"
  KERN_OK=1
fi

echo
if [[ "$BUILD_OK" == 1 && "$MEMLOCK_OK" == 1 && "$KERN_OK" == 1 ]]; then
  echo "RESULT: io_uring ready for pytest (--io-method=io_uring / matrix)"
  exit 0
fi
echo "RESULT: io_uring NOT ready — fix items above, then re-login if you changed limits.conf"
exit 1
