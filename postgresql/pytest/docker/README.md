# Docker setup-and-run guide — pg_tde pytest framework

The `pytest/` directory ships a complete Docker setup
(`Dockerfile`, `docker-compose.yml`, `docker/entrypoint.sh`) that runs
the pg_tde pytest framework in an isolated container — no host install
of PostgreSQL or pg_tde required.

The setup has **two parallel images**:

| Target | What it tests | When to use |
|---|---|---|
| `package-env` | Percona apt packages (`percona-postgresql-17`, `percona-pg-tde-17`) | Releases / customer parity |
| `source-env` | PostgreSQL + pg_tde built from GitHub at given refs | New features / pre-release / debugging |

Plus an optional `vault` service (HashiCorp Vault dev server) for
vault-keyed encryption tests.

---

## Prerequisites

```bash
# Docker Engine 20.10+ and Docker Compose v2
docker --version
docker compose version

# At least 4 GB free disk for the source-env image
df -h /var/lib/docker
```

Repository checked out at the standard place:

```bash
cd ~/Percona/percona-qa/postgresql/pytest
ls Dockerfile docker-compose.yml docker/entrypoint.sh   # all three must exist
```

---

## Quick reference of files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build with two targets: `package-env`, `source-env` |
| `docker-compose.yml` | Three services: `pg-tde-tests-pkg`, `pg-tde-tests-src`, `vault` |
| `docker/entrypoint.sh` | Sanity checks + env export + `exec "$@"` |
| `conftest.py` | Pytest fixtures — read by the container at `/workspace/conftest.py` |
| `tests/` | Test files — bind-mounted into `/workspace/tests/` |

---

## Build the images

### Package mode (fastest)

```bash
cd ~/Percona/percona-qa/postgresql/pytest

# Default: PG 17 + PG 16 for upgrade tests
docker compose build pg-tde-tests-pkg

# Different PG majors
PG_MAJOR=17 OLD_PG_MAJOR=16 docker compose build pg-tde-tests-pkg
```

### Source mode (slower; builds PG + pg_tde from source)

```bash
# Default: REL_17_STABLE + pg_tde main
docker compose build pg-tde-tests-src

# Override branches/repos via build args
PG_REF=PSP_REL_18_STABLE \
PG_REPO=https://github.com/percona/postgres.git \
PG_TDE_REF=main \
PG_TDE_REPO=https://github.com/percona/pg_tde.git \
PG_MAJOR=18 \
DEBUG_BUILD=true \
docker compose build pg-tde-tests-src

# Rebuild from scratch (no layer cache)
docker compose build --no-cache pg-tde-tests-src
```

Build arguments and their defaults (declared in `Dockerfile`):

| ARG | Default | Notes |
|---|---|---|
| `UBUNTU_VER` | `22.04` | Ubuntu base image tag |
| `PG_MAJOR` | `17` | Primary PostgreSQL major version |
| `OLD_PG_MAJOR` | `16` | Old PG for upgrade tests (package mode only) |
| `PG_TDE_REF` | `main` | pg_tde branch / tag / commit |
| `PG_TDE_REPO` | `https://github.com/Percona-Lab/pg_tde.git` | pg_tde git URL |
| `PG_REF` | `REL_17_STABLE` | PostgreSQL branch (source mode) |
| `PG_REPO` | `https://github.com/postgres/postgres.git` | PostgreSQL git URL |
| `DEBUG_BUILD` | `true` | Adds `--enable-debug --enable-cassert` to PG configure |
| `PGQA_UID` | `1001` | UID of the non-root `pgqa` user |

---

## Run the tests

### Default — everything except slow / vault / upgrade

```bash
docker compose run --rm pg-tde-tests-pkg
# CMD baked into the image is:
#   pytest tests/ -v --timeout=120 -m "not slow and not vault and not upgrade"
```

### Override the pytest command line

```bash
# A single test file
docker compose run --rm pg-tde-tests-pkg pytest tests/test_encryption.py -v

# A single test method
docker compose run --rm pg-tde-tests-pkg \
    pytest tests/test_pgbackrest.py::TestPgBackRest::test_full_backup_and_restore -v

# Different marker selection
docker compose run --rm pg-tde-tests-pkg \
    pytest tests/ -v -m "backup and not slow"

# HTML report dropped into the persistent volume
docker compose run --rm pg-tde-tests-pkg \
    pytest tests/ -v --html=/reports/report.html --self-contained-html
```

### Source-mode runner

Same commands; just swap the service name:

```bash
docker compose run --rm pg-tde-tests-src pytest tests/test_replication.py -v
```

### Enable Vault tests

```bash
# 1. Start the vault dev service (background)
docker compose up -d vault

# 2. Run the tests pointing at it
docker compose run --rm \
    -e VAULT_ADDR=http://vault:8200 \
    -e VAULT_TOKEN=root \
    pg-tde-tests-pkg \
    pytest tests/ -v -m vault

# 3. Stop vault when done
docker compose down
```

### Open a shell inside the container

For debugging the environment, inspecting binaries, or running ad-hoc psql:

```bash
docker compose run --rm pg-tde-tests-pkg bash
# Inside the container:
which pgbackrest
postgres --version
ls $INSTALL_DIR/bin
ls $INSTALL_DIR/share/postgresql/extension/pg_tde.control
exit
```

---

## Volumes and persistence

| Path on host | Path in container | Purpose |
|---|---|---|
| `./` (the pytest/ dir) | `/workspace` | Test code — edits on host are visible immediately |
| Named volume `test-reports` | `/reports` | Output artifacts (HTML reports, dumps) |
| `tmpfs` | `/tmp` (exec, 1777) | Sockets, temp clusters, fast IO |

Inspect the reports volume:

```bash
docker volume inspect pytest_test-reports
# To extract HTML report:
docker run --rm -v pytest_test-reports:/r -v "$PWD":/out alpine \
    cp /r/report.html /out/report.html
```

---

## Environment variables consumed by the tests

Set on the host before `docker compose run` (or in `.env`) to change behavior:

| Variable | Default | Effect |
|---|---|---|
| `PG_MAJOR` | `17` | Picks the PG major (pkg mode) |
| `OLD_PG_MAJOR` | `16` | Old PG for pg_upgrade (pkg mode) |
| `IO_METHOD` | `worker` | **PG 18+ only:** `worker` / `sync` / `io_uring` (`io_uring` needs `--with-liburing`). Ignored on PG 17 installs. |
| `VAULT_ADDR` | empty | Vault endpoint (`http://vault:8200` if using the compose service) |
| `VAULT_TOKEN` | empty | Vault token (`root` for the dev service) |
| `PGQA_UID` | `1001` | UID of the container user — set to host UID to avoid permission churn on the bind mount |

Example `.env` file alongside `docker-compose.yml`:

```sh
PG_MAJOR=18
OLD_PG_MAJOR=17
PG_REF=PSP_REL_18_STABLE
PG_TDE_REF=main
DEBUG_BUILD=true
PGQA_UID=1000          # match your host user
```

---

## Verification

Run this sequence after making changes to confirm the setup is healthy:

```bash
# 1. Build refreshes
docker compose build pg-tde-tests-pkg

# 2. The entrypoint prints a diagnostic header BEFORE running pytest.
docker compose run --rm pg-tde-tests-pkg bash -c 'true'
# Expect lines like:
#   user: pgqa (uid=1001)
#   INSTALL_DIR=/usr/lib/postgresql/17
#   PostgreSQL: postgres (PostgreSQL) 17.x ...
#   pg_tde.control: ...

# 3. Smoke test
docker compose run --rm pg-tde-tests-pkg \
    pytest tests/test_encryption.py::TestTdeSetup -v

# 4. Reports
docker compose run --rm pg-tde-tests-pkg \
    pytest tests/test_encryption.py -v \
    --html=/reports/encryption.html --self-contained-html
docker run --rm -v pytest_test-reports:/r -v "$PWD":/out alpine \
    cp /r/encryption.html /out/encryption.html
open encryption.html      # macOS — or xdg-open on Linux
```

---

## Common operations

### Reset everything

```bash
docker compose down -v               # stops services + removes named volumes
docker rmi percona-pg-tde-qa:pkg-17  # remove the cached image
docker compose build --no-cache pg-tde-tests-pkg
```

### Iterate on test code

The `pytest/` directory is **bind-mounted** at `/workspace`. You don't need
to rebuild the image when you edit `tests/*.py`, `lib/*.py`, or `conftest.py`.
Just re-run `docker compose run --rm pg-tde-tests-pkg pytest ...`.

You *do* need to rebuild when:
- You change `Dockerfile`, `docker-compose.yml`, or `docker/entrypoint.sh`
- You change pg_tde / PostgreSQL versions (rebuild `source-env`)
- You change apt package selection

### Run with the source build pointed at a local pg_tde checkout

The current Dockerfile clones pg_tde inside the build. To debug against a
*local* pg_tde tree, mount it and rebuild from inside the running container:

```bash
docker compose run --rm \
    -v ~/Percona/pg_tde:/src/pg_tde \
    pg-tde-tests-src bash
# Inside:
cd /src/pg_tde
make USE_PGXS=1 -j$(nproc) PG_CONFIG=$INSTALL_DIR/bin/pg_config install
exit
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `pg_tde.control not found` in entrypoint header | Wrong `PG_MAJOR` for the pkg target, or pg_tde install failed | Check `Dockerfile` log; rebuild with explicit `PG_MAJOR` |
| `psql: connection refused` inside container | `/tmp` not exec / sockets blocked | Confirm `tmpfs: /tmp:exec,mode=1777` in compose; some hosts disable it |
| Permission denied on bind mount | Container user UID != host UID | Set `PGQA_UID` to match `id -u` on host and rebuild |
| Vault tests skipped | `VAULT_ADDR` empty | Start `vault` service and pass `-e VAULT_ADDR=http://vault:8200` |
| Upgrade tests skipped | `OLD_INSTALL_DIR` empty (source mode by design) | Use `pg-tde-tests-pkg` for upgrade scenarios |
| pgbackrest tests skipped | Image doesn't have pgbackrest | Check Dockerfile `apt install pgbackrest` step succeeded |

---

## Files referenced

- `Dockerfile` — multi-stage image definition
- `docker-compose.yml` — services + volume layout
- `docker/entrypoint.sh` — startup diagnostics + env export
- `conftest.py` — pytest fixtures consumed inside the container
- `setup_test_env.sh` — host-side equivalent (no Docker)
- `../build_from_source.sh` — host-side source build (no Docker)
