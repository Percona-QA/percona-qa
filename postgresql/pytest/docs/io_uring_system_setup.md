# io_uring system setup (PostgreSQL 18+)

Percona/PostgreSQL 18 packages may be **built with io_uring support** (`--with-liburing`).
That is only half of the story: `io_method = io_uring` also requires **OS-level**
settings for the user that runs `initdb` / `postgres`.

Works the same on **Ubuntu/Debian** and **RHEL/OL/Rocky**. Only the install
prefix differs:

| OS | Typical `INSTALL_DIR` |
|----|------------------------|
| Ubuntu / Debian | `/usr/lib/postgresql/18` |
| RHEL / OL / Rocky | `/usr/pgsql-18` |

Quick check (auto-detects OS default install dir):

```bash
cd postgresql/pytest
./scripts/check_io_uring_ready.sh
# or: INSTALL_DIR=/usr/lib/postgresql/18 USER_NAME=ubuntu ./scripts/check_io_uring_ready.sh
```

If `initdb --set io_method=io_uring` fails, or the server exits on start, check
**build** vs **system** below.

## 1. Verify the PostgreSQL build accepts io_uring

```bash
# Ubuntu/Debian:
export INSTALL_DIR=/usr/lib/postgresql/18
# RHEL/OL:
# export INSTALL_DIR=/usr/pgsql-18
export PATH="$INSTALL_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"

PROBE=$(mktemp -d)
if initdb -D "$PROBE" --set io_method=io_uring; then
  echo "BUILD OK: initdb accepts io_method=io_uring"
else
  echo "BUILD FAIL: binaries not compiled with io_uring / liburing"
fi
rm -rf "$PROBE"
```

If this fails, you need a different PostgreSQL build (source with `--with-liburing`),
not sysctl/limits changes.

## 2. Memory lock limit (`memlock`) for the test user

io_uring needs **locked, unswappable memory**. Default limits on cloud images
(Ubuntu `ubuntu`, RHEL/AWS `ec2-user`) are often too low for non-root users
(e.g. `ulimit -l` shows `2020520` instead of `unlimited`).

**Preferred:** let the check script raise it for this shell and persist PAM limits:

```bash
./scripts/check_io_uring_ready.sh
# uses: sudo prlimit --pid $$ --memlock=unlimited:unlimited
# and writes /etc/security/limits.d/99-io-uring-memlock.conf
```

Manual equivalent (same session, no re-login):

```bash
sudo prlimit --pid $$ --memlock=unlimited:unlimited
ulimit -l unlimited
ulimit -l   # expect: unlimited
```

Persistent (new SSH logins) — `/etc/security/limits.d/99-io-uring-memlock.conf`:

```text
ubuntu      soft    memlock    unlimited
ubuntu      hard    memlock    unlimited
# or: ec2-user …
```

`limits.conf` alone does **not** change an already-open SSH session; use `prlimit`
or log out and back in.

In Python/pytest the same check uses `resource.RLIMIT_MEMLOCK`.

## 3. Kernel `io_uring_disabled`

```bash
cat /proc/sys/kernel/io_uring_disabled
```

| Value | Meaning |
|-------|---------|
| `0` | io_uring allowed for all users |
| `1` | io_uring disabled completely |
| `2` | io_uring only for privileged users (blocks normal users) |

If you see `2` (or `1`), allow normal users:

```bash
sudo sysctl -w kernel.io_uring_disabled=0
```

To persist across reboot (optional):

```bash
echo 'kernel.io_uring_disabled = 0' | sudo tee /etc/sysctl.d/99-io-uring.conf
sudo sysctl --system
```

## 4. Full manual smoke test

After steps 2–3 and a **new login**:

```bash
export PGDATA=/tmp/pg_io_uring_test
rm -rf "$PGDATA"

initdb -D "$PGDATA" --set io_method=io_uring
echo "io_method = 'io_uring'" >> "$PGDATA/postgresql.conf"

pg_ctl -D "$PGDATA" -l /tmp/pg_io_uring.log start
sleep 2
psql -d postgres -c "SHOW io_method;"
pg_ctl -D "$PGDATA" stop
```

Expected: `SHOW io_method` → `io_uring`.

## 5. Automated check script

From `postgresql/pytest`. By default it **checks and applies** memlock + sysctl
(needs sudo). Use `--check-only` to report without changing the system.

```bash
./scripts/check_io_uring_ready.sh

# Ubuntu:
INSTALL_DIR=/usr/lib/postgresql/18 USER_NAME=ubuntu ./scripts/check_io_uring_ready.sh

# RHEL:
INSTALL_DIR=/usr/pgsql-18 USER_NAME=ec2-user ./scripts/check_io_uring_ready.sh

# Report only:
./scripts/check_io_uring_ready.sh --check-only
```

## 6. Pytest harness

The harness probes **build** (`initdb --set io_method=io_uring`) and **system**
(memlock + `/proc/sys/kernel/io_uring_disabled`) before including `io_uring` in
`--io-method-matrix`.

Session header examples:

```text
io-method-matrix uses worker, sync only; io_uring build OK but system not ready: memlock soft limit is ...
```

```text
io-method-matrix uses worker, sync, io_uring
```

Run only io_uring tests:

```bash
pytest tests/ --io-method=io_uring -v
```

See also `docs/test_sections.md`.
