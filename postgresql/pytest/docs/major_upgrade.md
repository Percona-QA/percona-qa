# Major upgrade workflow (PG 17 → 18 + pg_tde)

This document describes how to run **PostgreSQL major-version upgrades** with the
pytest suite and the staged VM helper script, aligned with the Percona operator
guide:

[Major upgrade — Percona Distribution for PostgreSQL 18](https://docs.percona.com/postgresql/18/major-upgrade.html#on-debian-and-ubuntu-using-apt)

For **in-place pg_tde minor bumps** on the same PG major (e.g. 18.3 → 18.4), see
[`minor_upgrade.md`](minor_upgrade.md) instead.

---

## What the Percona doc says

| Step | Debian/Ubuntu (`apt`) | pg_tde note |
|------|------------------------|-------------|
| 1 | `percona-release setup ppg-18` + `apt install percona-postgresql-18` | Install **`pg_tde` for PG 18** before first start |
| 2 | `systemctl stop postgresql` | |
| 3 | `pg_upgradecluster 17 main --check` | For **encrypted** clusters use **`pg_tde_upgrade`**, not plain `pg_upgrade` |
| 4 | `pg_upgradecluster 17 main` | Same — TDE requires `pg_tde_upgrade` |
| 5 | `systemctl start postgresql` | |
| 6 | `vacuumdb --all --analyze-in-stages` | |
| 7 | `pg_dropcluster 17 main` | After verifying the new cluster |

The doc’s `pg_upgradecluster` steps wrap upstream `pg_upgrade`. When `pg_tde` is
loaded and `tde_heap` data exists, Percona explicitly warns to use
**`pg_tde_upgrade`** instead.

---

## What pytest covers today

| Area | Module | How to run |
|------|--------|------------|
| **pg_tde_upgrade** (17→18, encrypted data) | `tests/test_tde_pg_upgrade.py` (~45 tests) | `--old-install-dir` + `--install-dir` |
| Plain **pg_upgrade** catalog objects | `tests/test_upgrade.py` (~47 tests) | same flags |
| **Post-upgrade analyze** | `TestUpgradePostMaintenance` | `vacuumdb --analyze-in-stages` |
| **`pg_upgrade --check`** | Several classes | |
| **Debian apt / pg_upgradecluster** | Not automated in pytest | Use `run_major_upgrade_workflow.sh --method debian` |

```bash
cd postgresql/pytest && source .env.sh

pytest -m upgrade \
  --old-install-dir=/usr/lib/postgresql/17 \
  --install-dir=/usr/lib/postgresql/18 \
  tests/test_tde_pg_upgrade.py tests/test_upgrade.py -v
```

Skip the whole section:

```bash
pytest tests/ --skip-sections=upgrade -v
```

---

## Staged VM workflow: `run_major_upgrade_workflow.sh`

Mirrors `run_minor_upgrade_workflow.sh` but for **different PG majors** (default
17 → 18).

### Prerequisites

- Non-root user with passwordless `sudo` for `apt` / `pg_createcluster` (debian mode)
- Persistent parent directory (default `/var/lib/pg_tde_major_upgrade`)

```bash
sudo mkdir -p /var/lib/pg_tde_major_upgrade
sudo chown "$USER" /var/lib/pg_tde_major_upgrade
```

### Methods

| Method | When | What it does |
|--------|------|--------------|
| **`pytest`** (default on RHEL / no `pg_createcluster`) | Dev trees or CI with two install prefixes | Runs `TestPspToPspUpgrade` smoke + analyze test via `pg_tde_upgrade` |
| **`debian`** | Ubuntu/Debian with `pg_createcluster` | Creates cluster `pg_tde_major_test`, populates TDE data, runs **`pg_tde_upgrade`** on `/var/lib/postgresql/{17,18}/…`, then `ALTER EXTENSION` + `vacuumdb` |
| **`auto`** | Default when `--method` omitted | `debian` if `pg_createcluster` exists, else `pytest` |

**Important:** The debian method uses **`pg_tde_upgrade` directly** (doc-correct
for TDE). It does **not** call `pg_upgradecluster` alone, because that invokes
plain `pg_upgrade`.

### Full run

```bash
cd postgresql/pytest
bash run_major_upgrade_workflow.sh
```

Defaults:

- `OLD_PG_MAJOR=17`, `NEW_PG_MAJOR=18`
- `PG_TDE_MAJOR_UPGRADE_DATA_DIR=/var/lib/pg_tde_major_upgrade` (workflow state only)
- Debian cluster name: `pg_tde_major_test` (not production `main`)
- pg_tde keyring file: `/var/lib/postgresql/17/pg_tde_major_test/major_upgrade_keyring.per` (owned by `postgres`)

### Split phases (manual package control)

```bash
# 1) Install PG 17 + pg_tde, populate source cluster
bash run_major_upgrade_workflow.sh --setup-only

# 2) Install PG 18 + pg_tde, run pg_tde_upgrade
bash run_major_upgrade_workflow.sh --upgrade-only

# 3) Start upgraded cluster, ALTER EXTENSION, vacuumdb, row check
bash run_major_upgrade_workflow.sh --verify-only --skip-install
```

### Debian doc-parity example

```bash
bash run_major_upgrade_workflow.sh \
  --method debian \
  --cluster-name pg_tde_major_test \
  --old-pg-major 17 \
  --new-pg-major 18
```

State is written to:

```
/var/lib/pg_tde_major_upgrade/major_upgrade_state.env
```

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `PG_TDE_MAJOR_UPGRADE_DATA_DIR` | `/var/lib/pg_tde_major_upgrade` | Keyring + state + pg_tde_upgrade cwd |
| `OLD_PG_MAJOR` | `17` | Source repo (`ppg-17`) |
| `NEW_PG_MAJOR` | `18` | Target repo (`ppg-18`) |
| `PG_MAJOR_UPGRADE_CLUSTER` | `pg_tde_major_test` | Debian cluster name |
| `PG_MAJOR_UPGRADE_METHOD` | `auto` | `pytest` / `debian` / `auto` |
| `OLD_REPO_COMPONENT` | `release` | `percona-release` tier |
| `NEW_REPO_COMPONENT` | `release` | |
| `COMPONENTS` | `server,pg_tde` | Passed to `setup_test_env.sh` |

---

## Mapping: doc step → automation

| Doc step | `run_major_upgrade_workflow.sh` | `test_tde_pg_upgrade.py` |
|----------|--------------------------------|---------------------------|
| Install PG 18 + pg_tde | `install_packages NEW_PG_MAJOR` | N/A (uses existing trees) |
| Stop old cluster | `pg_ctlcluster … stop` | `old.stop()` |
| `--check` | `pg_tde_upgrade --check` | `test_check_mode_with_tde_configured` |
| Upgrade | `pg_tde_upgrade` | `_upgrade()` helper |
| Start + verify data | `psql` row count | `test_tde_heap_data_survives` |
| `ALTER EXTENSION pg_tde UPDATE` | debian verify SQL | `_start_cluster_after_pg_upgrade()` |
| `vacuumdb --analyze-in-stages` | debian verify / pytest | `test_analyze_all_after_upgrade` |
| `pg_dropcluster 17 …` | end of debian verify (`--skip-drop` to keep) | N/A (ephemeral `/tmp`) |
| `apt` / `systemctl` | `setup_test_env.sh --install-pkgs` only | Not simulated |

---

## Related files

| Path | Role |
|------|------|
| `run_major_upgrade_workflow.sh` | Staged VM driver |
| `run_minor_upgrade_workflow.sh` | Same PG major, pg_tde package bump |
| `tests/test_tde_pg_upgrade.py` | Deep pg_tde_upgrade regression |
| `tests/test_upgrade.py` | Plain pg_upgrade + post-maintenance |
| `postgresql/automation/tests/pg_tde_upgrade_test.sh` | Bash parity (ephemeral dirs) |
| `postgresql/bugs/pg_tde_major_upgrade_plain_pg_upgrade_repro.sh` | Why plain `pg_upgrade` fails with TDE |

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `pg_tde_upgrade not found` | PG 18 `pg_tde` package not installed (`percona-pg-tde18`) |
| PG 18 fails to start after upgrade | `shared_preload_libraries=pg_tde` but pg_tde `.so` missing on new major |
| `failed to decrypt key` after upgrade | Used plain `pg_upgrade` instead of `pg_tde_upgrade` |
| pytest skips all upgrade tests | Missing `--old-install-dir` |
| `pg_createcluster not found` | Use `--method pytest` or install `percona-postgresql-common` |
| `Failed to open keyring file ... Permission denied` | Keyring must be under `$PGDATA` (owned by `postgres`); fixed in workflow — use latest script |
| `initdb: unrecognized option '--no-data-checksums'` | PG 17 only — flag is PG 18+; pull latest script |
