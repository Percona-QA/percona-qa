# CI upgrade scenarios — `tde-upgrade-parallel` + 18.4.1 → 18.4.2

Runbook for matching Percona Jenkins job
[`tde-upgrade-parallel`](https://pg.cd.percona.com/job/tde-upgrade-parallel/)
and the in-place **18.4.1 → 18.4.2** patch bump.

Full pytest/bash catalog: [`upgrade_matrix.md`](upgrade_matrix.md).

---

## Two upgrade types in this doc

| Track | Jenkins-style name | PostgreSQL | Data dir | Tooling in this repo |
|-------|-------------------|------------|----------|----------------------|
| **A — Major parallel** | `tde-upgrade-parallel` | Different major (typ. **17 → 18**) | New cluster via `pg_tde_upgrade` | Bash runners + `tests/test_tde_pg_upgrade.py` |
| **B — Minor patch** | (same job or separate minor job) | Same major (**18 → 18**) | **Same** `$PGDATA` | `run_minor_upgrade_workflow.sh` + `tests/test_tde_minor_upgrade.py` |

---

## A. `tde-upgrade-parallel` (major upgrade matrix)

Jenkins build [#122 parameters](https://pg.cd.percona.com/job/tde-upgrade-parallel/122/parameters/)
is not readable without VPN/login from outside Percona. The job name and repo layout
imply a **parallel matrix of major-version upgrade bash scripts** driven by:

| Parameter (typical) | Maps to |
|---------------------|---------|
| `OLD_SERVER_BUILD_PATH` / `OLD_INSTALL_DIR` | Source PG (e.g. `/usr/lib/postgresql/17`) |
| `NEW_SERVER_BUILD_PATH` / `INSTALL_DIR` | Target PG (e.g. `/usr/lib/postgresql/18`) |
| `TESTNAME` | Comma-separated `.sh` under `automation/tests/` or `upgrade_testing/tests/` |
| `IO_METHOD` | `worker` (default), `sync`, or `io_uring` |
| `SKIP_TEST` | Comma-separated basenames to skip |

Confirm exact parameter names on the Jenkins **Build with Parameters** page before
filing a CI ticket.

### A.1 Bash scripts (Jenkins / manual parity)

#### Automation suite (`postgresql/automation/`)

Each script is a self-contained major-upgrade scenario. Run via `test_runner.sh`:

```bash
cd postgresql/automation/wrapper

OLD=/usr/lib/postgresql/17    # or dev tree: /home/ubuntu/pgwork/pginst/17
NEW=/usr/lib/postgresql/18    # or dev tree: /home/ubuntu/pgwork/pginst/18
IO=worker

run_one() {
  bash test_runner.sh \
    --server_build_path "$NEW" \
    --old_server_build_path "$OLD" \
    --testname "$1" \
    --io_method "$IO"
}

# Core smoke
run_one pg_tde_upgrade_test.sh

# Flavour permutations
run_one pg_tde_upgrade_ppg_to_psp.sh      # 4 scenarios: PG-2240, ALTER EXT, multi-DB, --check
run_one pg_tde_upgrade_psp_to_psp.sh      # PSP 17→18: data + multi-DB keys
run_one pg_tde_upgrade_access_method.sh   # 5 heap↔tde_heap permutations
run_one pg_tde_upgrade_wal_encryption.sh  # 4 WAL enc on/off paths
run_one pg_tde_upgrade_scenarios_test.sh  # 7: multi-DB, mixed AM+FK, schema, TOAST, partitions, global KP, --check
```

#### Upgrade-testing suite (`postgresql/upgrade_testing/`)

Uses `pg_tde_upgrade_runner.sh` (always calls `pg_tde_upgrade` wrapper):

```bash
cd postgresql/upgrade_testing/wrapper

OLD=/usr/lib/postgresql/17
NEW=/usr/lib/postgresql/18
IO=worker

bash pg_tde_upgrade_runner.sh \
  --old_server_build_path "$OLD" \
  --new_server_build_path "$NEW" \
  --testname pg_tde_upgrade_basic_test.sh,pg_tde_upgrade_wal_encryption.sh \
  --io_method "$IO"
```

#### Run all major bash scripts in one loop (local “parallel” prep)

```bash
cd postgresql/automation/wrapper
OLD=/usr/lib/postgresql/17
NEW=/usr/lib/postgresql/18

for t in \
  pg_tde_upgrade_test.sh \
  pg_tde_upgrade_ppg_to_psp.sh \
  pg_tde_upgrade_psp_to_psp.sh \
  pg_tde_upgrade_access_method.sh \
  pg_tde_upgrade_wal_encryption.sh \
  pg_tde_upgrade_scenarios_test.sh
do
  echo "======== $t ========"
  bash test_runner.sh \
    --server_build_path "$NEW" \
    --old_server_build_path "$OLD" \
    --testname "$t" \
    --io_method worker \
  || exit 1
done

cd ../../upgrade_testing/wrapper
bash pg_tde_upgrade_runner.sh \
  --old_server_build_path "$OLD" \
  --new_server_build_path "$NEW" \
  --testname pg_tde_upgrade_basic_test.sh,pg_tde_upgrade_wal_encryption.sh \
  --io_method worker
```

Jenkins runs these as **parallel stages** (one script per executor); locally the
loop above is sequential but exercises the same scenarios.

### A.2 Pytest parity (recommended on dev trees)

Single command covering all major TDE regression (48 tests) + plain `pg_upgrade` (47):

```bash
cd postgresql/pytest && source .env.sh

export OLD_INSTALL_DIR=/home/ubuntu/pgwork/pginst/17   # adjust
export INSTALL_DIR=/home/ubuntu/pgwork/pginst/18

pytest -m upgrade \
  --old-install-dir="$OLD_INSTALL_DIR" \
  --install-dir="$INSTALL_DIR" \
  tests/test_tde_pg_upgrade.py tests/test_upgrade.py \
  -v --tb=short
```

#### Version-specific subsets

| Old / new pg_tde.control | Run these classes | Skip reason for others |
|--------------------------|-------------------|------------------------|
| **2.1 → 2.2** (cross-minor) | `TestPg2381EmptyKeyMigration`, `TestPg2379MultiDbKeyMigration` + all other major classes | `TestPg2381MajorUpgradeSamePgTdeControl` skips |
| **2.2 → 2.2** (same control, e.g. PG17 2.2.0 → PG18 2.2.1) | `TestPg2381MajorUpgradeSamePgTdeControl`, `TestPspToPspUpgrade`, … | `TestPg2381EmptyKeyMigration`, `TestPg2379MultiDbKeyMigration` skip |

Check control version:

```bash
grep default_version "$OLD_INSTALL_DIR"/share/*/extension/pg_tde.control
grep default_version "$INSTALL_DIR"/share/*/extension/pg_tde.control
```

#### Staged VM workflow (packages, Debian/RHEL)

```bash
cd postgresql/pytest
sudo mkdir -p /var/lib/pg_tde_major_upgrade && sudo chown "$USER" /var/lib/pg_tde_major_upgrade

bash run_major_upgrade_workflow.sh \
  --old-pg-major 17 \
  --new-pg-major 18
```

See [`major_upgrade.md`](major_upgrade.md) for `--method debian`, split phases, and troubleshooting.

### A.3 Script → pytest mapping (quick reference)

| Bash script | Pytest class(es) |
|-------------|------------------|
| `pg_tde_upgrade_test.sh` | `TestUpgradeBashScriptParity`, `TestPspToPspUpgrade` |
| `pg_tde_upgrade_ppg_to_psp.sh` | `TestPpgToPspUpgrade` |
| `pg_tde_upgrade_psp_to_psp.sh` | `TestPspToPspUpgrade` |
| `pg_tde_upgrade_access_method.sh` | `TestUpgradeAccessMethodPermutations` |
| `pg_tde_upgrade_wal_encryption.sh` | `TestUpgradeWalEncryptionPaths` |
| `pg_tde_upgrade_scenarios_test.sh` | `TestPgTdeUpgradeComplexSchema`, `TestTdeUpgradeExtremeCornerCases` |
| `upgrade_testing/.../basic_test.sh` | `TestUpgradeBashScriptParity::test_upgrade_database_key_provider_and_partitions` |
| `upgrade_testing/.../wal_encryption.sh` | `TestUpgradeBashScriptParity::test_upgrade_with_wal_encryption_left_on` |

---

## B. 18.4.1 → 18.4.2 (in-place patch / minor bump)

Same PostgreSQL **major** (18), same `$PGDATA`, operator replaces packages
(18.4.1 → 18.4.2), then pytest Verify runs `ALTER EXTENSION pg_tde UPDATE` when
the catalog minor advances.

This is **not** `pg_upgrade` and **not** `tests/test_upgrade.py`.

### B.1 Automated full workflow (recommended)

```bash
cd postgresql/pytest

sudo mkdir -p /var/lib/pg_tde_minor_upgrade
sudo chown "$USER" /var/lib/pg_tde_minor_upgrade

# Defaults: 18.4.1 from **release** → 18.4.2 from **testing**
bash run_minor_upgrade_workflow.sh

# Explicit (same as defaults):
OLD_PG_VERSION=18.4.1 NEW_PG_VERSION=18.4.2 \
OLD_REPO_COMPONENT=release NEW_REPO_COMPONENT=testing \
bash run_minor_upgrade_workflow.sh
```

### B.2 Manual staged pytest (split CI jobs)

**Phase 1 — Setup (18.4.1 packages):**

```bash
export PG_TDE_UPGRADE_DATA_DIR=/var/lib/pg_tde_minor_upgrade
export INSTALL_DIR=/usr/lib/postgresql/18

bash setup_test_env.sh --install-pkgs --pg-major 18.4.1 --repo-component release --components server,pg_tde

pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetup \
  tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeSetupHA \
  tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeSetup \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v
```

**Phase 2 — Operator:** stop clusters, `apt`/`yum` upgrade to **18.4.2** (do not wipe PGDATA).

**Phase 3 — Verify (18.4.2 packages):**

```bash
bash setup_test_env.sh --install-pkgs --pg-major 18.4.2 --repo-component testing --components server,pg_tde

pytest tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerify \
  tests/test_tde_minor_upgrade.py::TestPgTdeMinorUpgradeVerifyHA \
  tests/test_tde_minor_upgrade.py::TestPg2381MinorUpgradeVerify \
  --install-dir="$INSTALL_DIR" \
  --upgrade-data-dir="$PG_TDE_UPGRADE_DATA_DIR" \
  -v
```

### B.3 Non-staged behaviour tests (single pytest run on 18.4.2)

Run after packages are on 18.4.2; no `--upgrade-data-dir`:

```bash
pytest tests/test_tde_minor_upgrade.py::TestTdeMinorUpgradePreConditions \
  tests/test_tde_minor_upgrade.py::TestAlterExtensionUpdate \
  tests/test_tde_minor_upgrade.py::TestRollingRestart \
  tests/test_tde_minor_upgrade.py::TestWalArchivingContinuity \
  --install-dir="$INSTALL_DIR" -v
```

### B.4 What each staged scenario checks

| Scenario dir | Setup | Verify | Validates |
|--------------|-------|--------|-----------|
| `single/` | 500-row `tde_heap`, WAL enc on | `ALTER EXTENSION`, row digests, new INSERT | Core 18.4.1→18.4.2 path |
| `single_pg2381/` | Drop/recreate + `VACUUM FULL` churn | Same + post-churn query | PG-2381 smgr key migration |
| `ha/` | Primary + streaming standby | Both nodes after package bump | HA / rolling-upgrade safety |

### B.5 When `ALTER EXTENSION` is a no-op

If 18.4.1 and 18.4.2 ship the **same** `pg_tde.control` `default_version` (e.g. both
`2.2`), Verify still passes: data, keys, and WAL settings must match
`upgrade_state.json`; `ALTER EXTENSION pg_tde UPDATE` is idempotent.

Confirm:

```bash
psql -c "SELECT extversion FROM pg_extension WHERE extname='pg_tde';"
psql -c "SELECT pg_tde_version();"
```

---

## Combined CI checklist

Use this when reproducing Jenkins #122 **and** the 18.4.1→18.4.2 bump on one VM.

| # | Track | Action | Pass criterion |
|---|-------|--------|----------------|
| 1 | Major | All 6 `automation/tests/pg_tde_upgrade_*.sh` green | Each script exits 0 |
| 2 | Major | Both `upgrade_testing/tests/*.sh` green | Row counts match pre/post upgrade |
| 3 | Major | `pytest -m upgrade tests/test_tde_pg_upgrade.py` | 48 tests pass (minus expected skips for your control-version pair) |
| 4 | Major | `run_major_upgrade_workflow.sh` (optional VM smoke) | Debian or pytest method completes verify |
| 5 | Minor | `run_minor_upgrade_workflow.sh` 18.4.1→18.4.2 | Setup + Verify green |
| 6 | Minor | `--with-pg2381` | PG-2381 churn scenario green (needs pg_tde with PR #582) |
| 7 | Minor | Non-staged HA/ALTER EXTENSION tests | 4 classes pass on 18.4.2 |

---

## Environment notes

| Item | Major (17→18) | Minor (18.4.1→18.4.2) |
|------|---------------|------------------------|
| Flags | `--old-install-dir` + `--install-dir` | `--upgrade-data-dir` (staged) |
| Persistent data | Ephemeral `/tmp` in bash; optional `/var/lib/pg_tde_major_upgrade` | `/var/lib/pg_tde_minor_upgrade` |
| Skip section | `--skip-sections=upgrade` | `--skip-sections=minor_upgrade` |
| io_uring | `--io-method=io_uring` only when build + host allow | same |

---

## Related files

| Path | Role |
|------|------|
| `run_tde_upgrade_parallel.sh` | Local driver for major bash matrix (section A.1) |
| `run_minor_upgrade_workflow.sh` | 18.4.1→18.4.2 staged driver (section B.1) |
| `run_major_upgrade_workflow.sh` | PG 17→18 staged driver |
| `docs/upgrade_matrix.md` | Full test catalog |
| `docs/minor_upgrade.md` | Minor upgrade runbook |
| `docs/major_upgrade.md` | Major upgrade runbook |
