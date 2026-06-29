# pg_tde minor (in-place) upgrade — pytest guide

This document describes how to run **pg_tde extension minor-version upgrades** with the pytest suite in `tests/test_tde_minor_upgrade.py`.

For **PostgreSQL major upgrades** (e.g. PG 17 → 18 via `pg_tde_upgrade`), see
[`major_upgrade.md`](major_upgrade.md) and `run_major_upgrade_workflow.sh`.
For **in-place pg_tde minor bumps** on the same PG major (e.g. 18.3 → 18.4), this
document applies. Do **not** use `tests/test_upgrade.py` for in-place PG 18.3→18.4 —
that module runs `pg_upgrade` into a **new** data directory.

Coverage: [`coverage_reports/coverage_2026-05-19.md`](../coverage_reports/coverage_2026-05-19.md).

---

## What “minor upgrade” means here

| | Minor (this doc) | Major (`test_tde_pg_upgrade.py`) |
|--|------------------|----------------------------------|
| PostgreSQL | **Same** major (e.g. both 17) | Different major (17 → 18) |
| Data directory | **Same** `$PGDATA` | New cluster via `pg_upgrade` |
| Operator action | Replace **packages** on the host | Install new PG major + run `pg_tde_upgrade` / `pg_upgrade` |
| Typical pg_tde path | 2.1.x → 2.2.0 on same `/usr/lib/postgresql/17` | 2.1 on PG17 → 2.2 on PG18 |
| Pytest persistence | `--upgrade-data-dir` | `--old-install-dir` + `--install-dir` |

After the package swap, the catalog migration is:

```sql
ALTER EXTENSION pg_tde UPDATE;
```

(run per database when you have multiple DBs with the extension).

---

## Why staged tests exist

Major-upgrade tests keep **two install trees** on disk (`OLD_INSTALL_DIR` and `INSTALL_DIR`). A real **in-place** minor upgrade usually has **one** install path: you run apt/yum, the `.so` files change, but `$PGDATA` stays put.

Staged tests split work across **two pytest invocations**:

1. **Setup** — old pg_tde packages, populate data, write checksums to disk, stop.
2. **Operator** — upgrade OS packages (pytest does not do this).
3. **Verify** — new pg_tde packages, same `$PGDATA`, run `ALTER EXTENSION` and assert data.

---

## Configuration

### CLI flags

| Flag | Env var | Purpose |
|------|---------|---------|
| `--install-dir` | `INSTALL_DIR` | PostgreSQL install prefix (binaries, `share/extension`). **Setup:** old pg_tde. **Verify:** new pg_tde. Often the **same path** after apt upgrade. |
| `--upgrade-data-dir` | `PG_TDE_UPGRADE_DATA_DIR` | Parent directory for persistent scenario trees (see below). Required for staged Setup/Verify tests. |
| `--io-method` | (see `conftest.py`) | I/O method passed to `PgCluster` (default from conftest). |

Staged tests **skip** if `--upgrade-data-dir` / `PG_TDE_UPGRADE_DATA_DIR` is not set.

### Working directory

Run pytest from the framework root:

```bash
cd postgresql/pytest
```

---

## Directory layout

`--upgrade-data-dir` is only a **parent**. Each scenario uses its own subdirectory:

```text
/var/lib/pg_tde_minor_upgrade/          # PG_TDE_UPGRADE_DATA_DIR
├── single/                             # default single-node + WAL encryption
│   ├── pgdata/                         # PGDATA (must survive package upgrade)
│   ├── sock/                           # Unix socket directory
│   ├── keyfile.per                     # TDE principal key file
│   └── upgrade_state.json              # checksums, paths, ext version snapshot
├── single_pg2381/                      # PG-2381 churn (drop/recreate + VACUUM FULL)
│   ├── pgdata/
│   ├── sock/
│   ├── keyfile.per
│   └── upgrade_state.json
└── ha/                                 # primary + standby replication
    ├── nodeA/                          # primary PGDATA (copy of temp cluster)
    ├── nodeB/                          # replica PGDATA
    ├── sock/
    ├── keyfile.per
    └── upgrade_state.json
```

`upgrade_state.json` is written by Setup and read by Verify. It records row counts, MD5 digests, extension version, key provider state, and paths (`data_dir`, `socket_dir`, etc.).

Re-running a **Setup** test calls `_reset_scenario_root()` and **deletes only that scenario’s subtree** (e.g. only `single/`, not `ha/`).

---

## Automated script (recommended on CI / fresh VM)

From `postgresql/pytest`:

```bash
sudo mkdir -p /var/lib/pg_tde_minor_upgrade
sudo chown "$USER" /var/lib/pg_tde_minor_upgrade

bash run_minor_upgrade_workflow.sh
# optional: bash run_minor_upgrade_workflow.sh --with-pg2381
```

The script:

1. `setup_test_env.sh --install-pkgs --pg-major 18.3 --repo-component release`
2. `TestPgTdeMinorUpgradeSetup` + `TestPgTdeMinorUpgradeSetupHA`
3. `setup_test_env.sh --install-pkgs --pg-major 18.4 --repo-component testing`
4. `TestPgTdeMinorUpgradeVerify` + `TestPgTdeMinorUpgradeVerifyHA`

Options: `--help`, `--skip-install`, `--setup-only`, `--verify-only`, `--upgrade-only`,
`--upgrade-data-dir PATH`, `--with-pg2381`.

---

## Staged workflow (manual)

### Phase 1 — Setup (old packages)

Install **pg_tde 2.1.x** (or whatever you treat as “source”) on the target PostgreSQL major. Point `--install-dir` at that tree.

```bash
export PG_TDE_UPGRADE_DATA_DIR=/var/lib/pg_tde_minor_upgrade
export INSTALL_DIR=/usr/lib/postgresql/17   # example: PG 17 + pg_tde 2.1

cd postgresql/pytest

# Single node: 500-row tde_heap table, WAL encryption on
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup::test_prepare_persistent_state_for_minor_upgrade \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v

# PG-2381 churn scenario (requires pg_tde with PR 582 / fix for empty key files)
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup::test_prepare_pg2381_churn_for_minor_upgrade \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v

# HA: primary + streaming standby
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetupHA::test_prepare_persistent_ha_state_for_minor_upgrade \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v
```

Or run all Setup tests in one go:

```bash
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup \
  tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetupHA \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v
```

Setup stops the server cleanly. **Do not delete** `pgdata/` (or `nodeA/` / `nodeB/` for HA).

### Phase 2 — Operator (outside pytest)

1. Ensure PostgreSQL using that PGDATA is **stopped**.
2. Upgrade packages on the **same** PostgreSQL major (e.g. pg_tde 2.1 → 2.2 on PG 17).
3. **Do not** run `pg_upgrade`, `initdb`, or `rm -rf` on the staged data directories.

Example (Debian/Ubuntu-style; adjust for your distro):

```bash
sudo systemctl stop postgresql@17-main   # if anything still uses the host cluster

sudo apt update
sudo apt install percona-postgresql-17 percona-postgresql-17-pg-tde
```

### Phase 3 — Verify (new packages)

Use the **same** `--upgrade-data-dir`. `--install-dir` must resolve to the **new** pg_tde binaries (often the same path as Phase 1 after apt).

```bash
export INSTALL_DIR=/usr/lib/postgresql/17   # now pg_tde 2.2.x on disk

pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerify::test_minor_upgrade_verification_flow \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v

pytest tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeVerify::test_verify_pg2381_churn_after_minor_upgrade \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v

pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerifyHA::test_ha_minor_upgrade_verification_flow \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v
```

Verify tests:

- Reattach to saved `pgdata/` and `sock/`
- Start with binaries from `--install-dir`
- Confirm data **before** `ALTER EXTENSION pg_tde UPDATE`
- Run `ALTER EXTENSION pg_tde UPDATE`
- Confirm data, keys, and WAL encryption settings **after** migration
- Insert new rows to prove writes still work

### End-to-end example (all staged scenarios)

```bash
export BASE=/var/lib/pg_tde_minor_upgrade
export PGDIR=/usr/lib/postgresql/17

# Phase 1 — old pg_tde
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup \
  tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetupHA \
  --install-dir="$PGDIR" --upgrade-data-dir="$BASE" -v

# Phase 2 — operator upgrades packages (stop clusters first)

# Phase 3 — new pg_tde, same BASE
pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerify \
  tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeVerify \
  tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerifyHA \
  --install-dir="$PGDIR" --upgrade-data-dir="$BASE" -v
```

---

## Test map

### Staged (need `--upgrade-data-dir`)

| Scenario dir | Setup | Verify |
|--------------|-------|--------|
| `single/` | `TestPgTdeMinorUpgradeSetup::test_prepare_persistent_state_for_minor_upgrade` | `TestPgTdeMinorUpgradeVerify::test_minor_upgrade_verification_flow` |
| `single_pg2381/` | `TestPg2381MinorUpgradeSetup::test_prepare_pg2381_churn_for_minor_upgrade` (opt-in) | `TestPg2381MinorUpgradeVerify::test_verify_pg2381_churn_after_minor_upgrade` |
| `ha/` | `TestPgTdeMinorUpgradeSetupHA::test_prepare_persistent_ha_state_for_minor_upgrade` | `TestPgTdeMinorUpgradeVerifyHA::test_ha_minor_upgrade_verification_flow` |

### Non-staged (single pytest run, `tmp_path`, one `--install-dir`)

These assume you are **already** on the target pg_tde build. They exercise behavior **after** catalog and binary already match (or idempotent `ALTER EXTENSION`), not the OS package-swap workflow:

| Class | Purpose |
|-------|---------|
| `TestTdeMinorUpgradePreConditions` | Catalog vs binary version; WAL encryption on HA pair |
| `TestAlterExtensionUpdate` | `ALTER EXTENSION` safety and idempotency on HA |
| `TestRollingRestart` | Patroni-style restart order with encrypted data |
| `TestWalArchivingContinuity` | PITR from archive after rolling restart |

Markers: `minor_upgrade` (staged Setup/Verify only), `encryption`, `slow`. Do **not** tag this file with `upgrade` — that marker is for major `pg_upgrade` tests and requires `--old-install-dir`.

---

## One-shot minor upgrade (two install paths, one pytest run)

If **both** pg_tde versions are installed as **different directories** on the **same** PostgreSQL major (common on dev machines, uncommon after a single apt upgrade), you can run everything in one invocation **without** `--upgrade-data-dir`:

```bash
pytest tests/test_tde_pg_upgrade.py::TestPg2379MultiDbKeyMigration::test_in_place_package_upgrade_multidb_distinct_keys \
  --old-install-dir=/path/to/pg17-pg-tde-21 \
  --install-dir=/path/to/pg17-pg-tde-22 \
  -v
```

Requirements:

- Same `postgres_major_version()` on old and new paths
- Different `default_version` in `pg_tde.control` (2.1 vs 2.2)
- Uses ephemeral `tmp_path`, not a persistent upgrade dir

Major PG 17→18 tests in the same file need **different** PG majors on old vs new; do not use those for in-place minor upgrades.

---

## PG-2381 and empty key files

The `single_pg2381` scenario runs drop/recreate plus `VACUUM FULL` before upgrade. Older pg_tde 2.2 migration code could fail with `failed to decrypt key` on empty smgr key slots. Fix: [percona/pg_tde#582](https://github.com/percona/pg_tde/pull/582).

- Staged minor: Setup + Verify under `single_pg2381/`
- Major upgrade regression: `tests/test_tde_pg_upgrade.py::TestPg2381EmptyKeyMigration`
- Shell repros: `postgresql/bugs/pg_tde_upgrade_issue.sh`, `PG_tde_upgrade_21_22_report.md`

Install builds that include the fix before expecting green PG-2381 tests.

---

## Adding a new staged scenario

1. Pick a scenario name (e.g. `multidb`).
2. **Setup** test:
   - `_scenario_root(upgrade_data_dir, "multidb")`
   - `_reset_scenario_root(scenario_root)` if you want a clean run
   - `initdb` under `scenario_root / "pgdata"`, populate data, `_capture_pre_upgrade_state(...)`, `_write_state(...)`
3. **Verify** fixture/class:
   - `_read_state(scenario_root)`, check `state["scenario"]`
   - `_bind_cluster_to_persistent_data_dir(...)`, start, `ALTER EXTENSION pg_tde UPDATE`, assert using fields in state
4. Document the scenario in this file and run Setup → operator → Verify like the built-in scenarios.

HA scenarios copy final `nodeA`/`nodeB` data dirs into the persistent tree after tearing down the temporary `tmp_path` cluster used to build replication.

---

## CI split

| Job | When | Flags |
|-----|------|-------|
| `minor-upgrade-setup` | Old pg_tde packages on agent | `--install-dir=<old>`, `--upgrade-data-dir=<artifact path>` |
| `minor-upgrade-operator` | Manual or package upgrade job | Preserve artifact `pgdata/` |
| `minor-upgrade-verify` | New pg_tde packages on agent | `--install-dir=<new>`, same `--upgrade-data-dir` |

Major-upgrade CI instead passes `--old-install-dir` and `--install-dir` in a **single** job when both trees exist.

---

## Pitfalls

| Symptom | Likely cause |
|---------|----------------|
| Tests skipped: `--upgrade-data-dir not provided` | Set flag or `PG_TDE_UPGRADE_DATA_DIR` |
| `No staged Setup state at .../upgrade_state.json` | Run matching Setup test first |
| `initdb: directory exists` on Setup re-run | Expected if you did not reset; Setup wipes the scenario dir — use a fresh scenario name if you need parallel runs |
| Data wrong after upgrade | Package upgrade wiped PGDATA, or Verify used a different `--upgrade-data-dir` |
| `failed to decrypt key` on start (PG-2381) | Old pg_tde 2.2 without PR 582; or ran major `pg_upgrade` path with churned tables |
| Verify uses wrong binaries | `--install-dir` must point at post-upgrade install tree |

---

## Related files

| Path | Role |
|------|------|
| `tests/test_tde_minor_upgrade.py` | Minor upgrade tests |
| `tests/test_tde_pg_upgrade.py` | Major upgrade + `TestPg2381EmptyKeyMigration` + in-place multidb test |
| `conftest.py` | `--upgrade-data-dir`, `upgrade_data_dir` fixture |
| `lib/cluster.py` | `PgCluster`, upgrade helpers |
| `postgresql/bugs/` | Shell repro scripts and reports |
