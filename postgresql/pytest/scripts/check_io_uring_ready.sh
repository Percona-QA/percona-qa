#!/usr/bin/env bash
# Quick io_uring readiness check (build + system) with fix suggestions.
# Full runbook: postgresql/pytest/docs/io_uring_system_setup.md
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/pgsql-18}"
USER_NAME="${USER_NAME:-$(whoami)}"
LIMITS_FILE="${LIMITS_FILE:-/etc/security/limits.conf}"
SYSCTL_DROPIN="${SYSCTL_DROPIN:-/etc/sysctl.d/99-io-uring.conf}"

BUILD_OK=0
MEMLOCK_OK=0
KERN_OK=0
NEED_RELOGIN=0

echo "=== io_uring readiness ==="
echo "INSTALL_DIR=$INSTALL_DIR"
echo "USER=$USER_NAME"
echo "Doc: postgresql/pytest/docs/io_uring_system_setup.md"
echo

if [[ ! -x "$INSTALL_DIR/bin/initdb" ]]; then
  echo "FAIL: $INSTALL_DIR/bin/initdb not found"
  echo
  echo "Set INSTALL_DIR to your PostgreSQL prefix, e.g.:"
  echo "  export INSTALL_DIR=/usr/pgsql-18"
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

echo
echo "--- 2. memlock (ulimit -l) ---"
ML=$(ulimit -l)
echo "ulimit -l = $ML"
if [[ "$ML" == "unlimited" ]]; then
  echo "PASS: memlock unlimited for current shell"
  MEMLOCK_OK=1
else
  echo "FAIL: memlock is not unlimited (io_uring needs locked memory)"
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
    1)
      echo "FAIL: io_uring disabled globally (value 1)"
      ;;
    2)
      echo "FAIL: io_uring restricted to privileged users only (value 2)"
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
  echo "  pytest:  pytest tests/ --io-method=io_uring -v"
  echo "           pytest tests/ --io-method-matrix -v"
  exit 0
fi

echo "RESULT: io_uring is NOT ready"
echo
echo "Suggested steps to enable io_uring on this system:"
echo "----------------------------------------------"

if [[ "$BUILD_OK" != 1 ]]; then
  cat <<'EOF'

[A] PostgreSQL build (only if initdb failed above)
    Use a PG 18+ build compiled with liburing, for example from source:

      ./configure --prefix=/opt/pgsql --with-liburing ...other flags...
      make install

    Or install a Percona/package build that documents io_uring support.
    Re-run this script after switching INSTALL_DIR.

EOF
fi

if [[ "$MEMLOCK_OK" != 1 ]]; then
  NEED_RELOGIN=1
  cat <<EOF

[B] Raise memlock for user '$USER_NAME' (required on RHEL/AWS for ec2-user)
    1) Append to $LIMITS_FILE (sudo):

       sudo tee -a "$LIMITS_FILE" <<LIMITS

# io_uring: allow locked memory for PostgreSQL (percona-qa check_io_uring_ready.sh)
$USER_NAME    soft    memlock    unlimited
$USER_NAME    hard    memlock    unlimited
LIMITS

    2) Log out of SSH completely and log back in (PAM reads limits.conf at login).

    3) Verify in a NEW shell:

       ulimit -l
       # must print: unlimited

EOF
fi

if [[ "$KERN_OK" != 1 ]] && [[ -r /proc/sys/kernel/io_uring_disabled ]]; then
  VAL=$(cat /proc/sys/kernel/io_uring_disabled)
  cat <<EOF

[C] Allow io_uring for non-root users (kernel restriction)
    Current kernel.io_uring_disabled=$VAL
    (0=all users, 1=disabled, 2=admin-only)

    Temporary (until reboot):

      sudo sysctl -w kernel.io_uring_disabled=0

    Persistent:

      echo 'kernel.io_uring_disabled = 0' | sudo tee $SYSCTL_DROPIN
      sudo sysctl --system

    Verify:

      cat /proc/sys/kernel/io_uring_disabled
      # must print: 0

EOF
fi

cat <<'EOF'
[D] Re-test after changes
    # New SSH session if you changed limits.conf
    export INSTALL_DIR=/usr/pgsql-18   # adjust
    export PATH="$INSTALL_DIR/bin:$PATH"

    ulimit -l
    cat /proc/sys/kernel/io_uring_disabled

    PROBE=$(mktemp -d)
    initdb -D "$PROBE" --set io_method=io_uring && echo "initdb OK"
    rm -rf "$PROBE"

    # Or re-run this script:
    ./scripts/check_io_uring_ready.sh

EOF

if [[ "$NEED_RELOGIN" == 1 ]]; then
  echo "NOTE: memlock changes apply only after you log out and back in."
fi

exit 1
