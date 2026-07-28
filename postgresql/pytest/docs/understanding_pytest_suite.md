Don’t read all ~550 tests linearly. Use a **layered map → harness → helpers → one module deep → expand by section** approach.

## Mental model (3 layers)

```text
docs/          → what we test & why (product coverage)
conftest.py    → how every test gets a PG install, ports, fixtures
lib/           → reusable ops (cluster, TDE, KMIP, backup, replication)
tests/         → scenarios (assert product behavior)
```

Almost every test is: **build cluster → configure TDE/provider → do work → restart/failover/backup → assert**.

---

## Strategy (in order)

### 1. Start with docs (½–1 day) — map, don’t memorize

| Read | Why |
|------|-----|
| [docs/qa_workflow_executive_summary.md](postgresql/pytest/docs/qa_workflow_executive_summary.md) | Big picture |
| [docs/qa_test_modules.md](postgresql/pytest/docs/qa_test_modules.md) | ~23 modules by *product area* (no filenames) |
| [docs/qa_test_coverage_executive_summary.md](postgresql/pytest/docs/qa_test_coverage_executive_summary.md) | File ↔ area mapping |
| [docs/test_sections.md](postgresql/pytest/docs/test_sections.md) | Markers / `--skip-sections` |

After this you should know *areas* (encryption, KMIP, upgrade, rewind, pgBackRest…), not every test name.

### 2. Learn the harness (critical)

Read in this order:

1. **`conftest.py`** (root) — `--install-dir`, `io_method` / `--io-method-matrix`, KMIP/Vault options, collection skips  
2. **`tests/conftest.py`** — `pg_factory`, `tde_primary`, `replica_pair`  
3. Run once and watch fixtures:

```bash
cd postgresql/pytest
source .env.sh   # if you use it
pytest tests/test_encryption.py -k "test_enable" -v --collect-only
pytest tests/test_encryption.py -k "test_enable" -v -s
```

Ask: *Where does PGDATA come from? Who starts/stops the server? Who sets `shared_preload_libraries`?*

### 3. Learn `lib/` before diving into tests

These are the “verbs” every scenario uses:

| File | Role |
|------|------|
| `lib/cluster.py` | `PgCluster`: initdb, start/stop, SQL, config |
| `lib/tde.py` | `TdeManager`: extension, providers, keys, WAL encrypt, basebackup |
| `lib/replication.py` | Standby create, catchup, streaming |
| `lib/backup.py` | pgBackRest |
| `lib/kmip.py` / `lib/vault.py` | External provider config |

Read **method names**, not every line. Then any test becomes readable.

### 4. Study one “spine” module end-to-end

Best first spine:

1. **`tests/test_encryption.py`** — core TDE SQL  
2. **`tests/test_kmip.py`** — external keys + restart (you already touched Scenario 3)  
3. **`tests/test_replication.py`** — HA basics  
4. **`tests/test_pg_tde_pgbackrest.py`** — backup/restore pattern  

For each file:

```bash
pytest tests/test_kmip.py --collect-only -q
```

Then for each `class` / `test_*`: read the **docstring** → skim setup → find the **assert after restart/failover**. That assert is the scenario’s purpose.

### 5. Expand by section, not by filename alphabet

Use markers:

```bash
pytest --list-test-sections
pytest tests/ -m encryption --collect-only -q
pytest tests/ -m kmip --collect-only -q
pytest tests/ -m pgbackrest --collect-only -q
pytest tests/ -m rewind --collect-only -q
```

Deep-dive order that matches dependencies:

1. encryption / cipher  
2. key providers (file → KMIP → Vault/OpenBao)  
3. replication / basebackup  
4. recovery / waldump / CLI  
5. pgBackRest / PITR  
6. rewind / HA  
7. upgrade / migration  
8. bug / external regressions  

Area-specific catalogs when needed: `docs/kmip/`, `docs/vault.md`, `docs/upgrade_matrix.md`.

### 6. How to understand *one* scenario quickly

Template for any test:

1. **Class docstring** — theme  
2. **Fixtures** — `pg_factory`, `kmip_config`, `vault_config`, `io_method`  
3. **Setup** — providers/keys/WAL encrypt  
4. **Action** — DML, restart, promote, backup, restore  
5. **Assert** — what must still work / what must fail  
6. **Bash twin?** — many docstrings cite `postgresql/automation/tests/*.sh`

If confused, run **only that test** with `-vv --tb=short` and read `server.log` from the failure artifact path.

---

## Practical weekly plan

| Day | Focus |
|-----|--------|
| 1 | Docs + `conftest` + `lib/cluster.py` + `lib/tde.py` |
| 2 | `test_encryption.py` + `test_cipher.py` (run a few) |
| 3 | KMIP/Vault (`test_kmip.py`, `test_vault_providers.py`, `docs/kmip/`) |
| 4 | Replication + basebackup + one pgBackRest smoke |
| 5 | One hard area you care about (rewind **or** upgrade) |

Don’t try to memorize all 32 `test_*.py` files in week one.

---

## Commands that reveal structure

```bash
# All test node ids
pytest tests/ --collect-only -q | less

# Group by marker
pytest tests/ --collect-only -q -m kmip

# Find scenario by keyword
rg -n "Scenario 3|default principal|wal_encrypt" tests/ docs/

# See what a module claims to cover
sed -n '1,40p' tests/test_pg_tde_pgbackrest.py
```

---

## What *not* to do

- Don’t start with `test_tde_rewind_advanced.py` or full upgrade matrices  
- Don’t read `coverage_reports/` first (they’re snapshots, not the map)  
- Don’t learn OpenBao/Vault/KMIP before file-keyring + `TdeManager`  

---

**Rule of thumb:** if you can explain `pg_factory` → `TdeManager` → restart → assert for one simple test, you can read any scenario in this suite; the rest is domain (KMIP, rewind, pgBackRest), not a different architecture.