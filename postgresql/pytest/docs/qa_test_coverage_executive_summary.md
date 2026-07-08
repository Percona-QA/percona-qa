# pg_tde Test Coverage — Executive Summary

> **Audience:** Management, build/release, onboarding QA  
> **Full catalog:** [coverage_reports/test_catalog_2026-05-14.md](../coverage_reports/test_catalog_2026-05-14.md) (per-test detail)  
> **QA workflow:** [qa_workflow.md](qa_workflow.md) · **Modules by area:** [qa_test_modules.md](qa_test_modules.md)

---

## Slide 1 — Headline numbers

| Metric | Value |
|--------|------:|
| **pytest scenarios** | **550** |
| **Test modules** | **29** |
| **Bash automation scripts** | **~50** (Jenkins parity) |
| **Supported KMS backends** | Cosmian, Fortanix, Thales, Akeyless, Vault KV, OpenBao |
| **Upgrade tracks** | Major (17→18), minor in-place (patch bump) |

All pytest tests run against **ephemeral PostgreSQL clusters** with `pg_tde` loaded — no manual SQL scripts required per test.

---

## Slide 2 — What we prove (one line each)

| Area | Customer risk if broken |
|------|-------------------------|
| **Encryption at rest** | Data readable without keys; wrong cipher or key scope |
| **Key providers** | Cannot use Vault/KMIP/file keyring in production |
| **Upgrades** | Data loss or keys unusable after PG or pg_tde upgrade |
| **HA / rewind** | Failover corrupts encrypted data or WAL |
| **Backup / recovery** | Backups/restores return plaintext or fail silently |
| **Replication** | Standby diverges or cannot decrypt |
| **CLI tools** | `pg_tde_rewind`, `pg_tde_waldump`, basebackup broken in ops |

---

## Slide 3 — Coverage map (by theme)

```
┌─────────────────────────────────────────────────────────────────┐
│  CORE ENCRYPTION (82)     │  CIPHER / SMGR (18)                 │
│  PARTITIONS (21)          │  TEMPLATE DBs (14)                  │
├─────────────────────────────────────────────────────────────────┤
│  UPGRADES: major pg_tde (48) + pg_upgrade (47) + minor (11)     │
├─────────────────────────────────────────────────────────────────┤
│  REWIND / HA (97)         │  REPLICATION (14)                   │
├─────────────────────────────────────────────────────────────────┤
│  BACKUP: pgBackRest (19)  │  basebackup (6)  │  PITR (2)       │
│  RECOVERY / CRASH (10)    │  unlogged (7)     │  bugs (18)       │
├─────────────────────────────────────────────────────────────────┤
│  WAL: waldump (27)        │  CLI tools (15)  │  change_kp (16)  │
├─────────────────────────────────────────────────────────────────┤
│  KEY PROVIDERS: KMIP (34) │  Vault KV (15)   │  file matrix (2) │
│  OpenBao (8)              │  regressions (7) │  Vault KMIP (2)  │
├─────────────────────────────────────────────────────────────────┤
│  MIGRATION (10)           │  PDG doc scenarios                  │
└─────────────────────────────────────────────────────────────────┘
```

Numbers in parentheses = pytest test count per module group.

---

## Slide 4 — Core encryption & SQL API (82 tests)

**Module:** `test_encryption.py` (+ `test_cipher.py`, `test_partitioning.py`, `test_template_databases.py`)

| Scenario | Examples |
|----------|----------|
| TDE table access methods | `tde_heap`, mixed heap/TDE |
| Global & database key providers | File keyring, add/delete/change |
| Principal key lifecycle | create, set, rotate, default key |
| GUCs | `shared_preload_libraries`, encryption settings |
| Multi-database | Per-DB keys, isolation |
| Negative cases | Wrong provider name, missing key, bad paths |
| Cipher algorithms | AES-128/256, restart survival (`test_cipher.py`) |
| Partitions | Range/list/hash × `tde_heap` (21 tests) |
| Template databases | `CREATE DATABASE ... TEMPLATE` with TDE (14 tests) |

**Guards:** day-to-day DBA operations with pg_tde enabled.

---

## Slide 5 — Upgrades (106 tests)

| Track | Module | Tests | What happens |
|-------|--------|------:|--------------|
| **Major — pg_tde_upgrade** | `test_tde_pg_upgrade.py` | 48 | PG 17→18, same data dir, `pg_tde_upgrade` wrapper |
| **Major — pg_upgrade** | `test_upgrade.py` | 47 | New PGDATA, heap + TDE tables |
| **Minor in-place** | `test_tde_minor_upgrade.py` | 11 | 18.4.1→18.4.2, persistent `$PGDATA`, `ALTER EXTENSION` |

**Plus bash matrix** (`run_tde_upgrade_parallel.sh`, ~8 scripts): WAL encryption paths, access-method permutations, multi-DB keys, PSP↔PSP, PPG↔PSP.

**Guards:** customer upgrade windows — the highest business-impact area.

---

## Slide 6 — High availability & rewind (97 tests)

**Module:** `test_tde_rewind_advanced.py`

| Scenario | Examples |
|----------|----------|
| Live vs offline rewind | `--source-server` vs `--source-pgdata` |
| Failover loops | Promote standby → rewind old primary |
| WAL encryption | Encrypted WAL segments during rewind |
| Tablespaces | Encrypted data in custom tablespaces |
| Key provider edges | Rewind after key rotation |
| Sysbench-driven stress | Sustained DML during failover |
| Negative cases | Unclean shutdown, bad timeline |

**Plus bash:** `pg_tde_rewind_*` scripts (~15) for Jenkins HA parity.

**Guards:** production HA topologies with encrypted data.

---

## Slide 7 — Backup, recovery & WAL (84 tests)

| Module | Tests | Focus |
|--------|------:|-------|
| `test_pgbackrest.py` | 19 | Full/incremental backup, restore, encrypted repo |
| `test_pg_basebackup.py` | 6 | `pg_tde_basebackup` / streaming base backup |
| `test_pitr.py` | 2 | Point-in-time recovery with encrypted WAL |
| `test_recovery.py` | 10 | Crash recovery, `pg_resetwal`, archive paths |
| `test_unlogged_recovery.py` | 7 | UNLOGGED + TDE edge cases |
| `test_waldump.py` | 27 | `pg_tde_waldump`, WAL encryption visibility |
| `test_tde_cli_tools.py` | 15 | checksums, archive decrypt/restore encrypt |

**Guards:** backup/DR procedures customers rely on for compliance.

---

## Slide 8 — Replication (14 tests)

**Module:** `test_replication.py`

| Scenario | Examples |
|----------|----------|
| Physical streaming | Primary → standby with TDE |
| Logical replication | Pub/sub with encrypted tables |
| WAL / seg size | Replication under encrypted WAL |

**Plus bash:** streaming replication, logical replication, `pg_createsubscriber` scripts.

**Guards:** standby decryption and replication continuity.

---

## Slide 9 — External key providers (68+ tests)

Shared **matrix pattern** — same scenarios on every backend ([key_provider_matrix.md](key_provider_matrix.md)):

| Backend | Pytest modules | Tests | CI frequency |
|---------|----------------|------:|--------------|
| **Cosmian KMIP** | `test_kmip_common_matrix.py`, `test_kmip_server_revalidation.py`, `test_kmip.py` | 34+ | Every build |
| **Fortanix / Thales / Akeyless** | Same matrix, `KMIP_PROFILE=*` | 34+ each | Scheduled sign-off |
| **Vault KV v2** | `test_vault_kv_common_matrix.py`, `test_vault_providers.py` | 13 | Every build (dev) + Enterprise lab |
| **OpenBao** | `test_openbao_bash_parity.py` | 8 | Every build |
| **File keyring** | `test_file_keyring_common_matrix.py` | 2 | Dev/test only |
| **Regressions** | `test_external_key_provider_regressions.py` | 7 | PG-2125, PG-1959, namespace |
| **Vault KMIP engine** | `test_vault_kmip.py` | 2 | Lab only (not prod path) |

**Shared KMIP scenarios:** add provider → create key → encrypted DML → restart → rotate → online `change_*_key_provider_kmip`.

**Guards:** production KMS integrations (Thales, Akeyless, Fortanix, Vault).

---

## Slide 10 — Offline CLI & key provider changes (16 tests)

**Module:** `test_change_key_provider.py`

| Scenario | Examples |
|----------|----------|
| Offline file provider | Change path while server stopped |
| Validation | Bad OID, missing args, wrong provider type |
| Persistence | Survives multiple restart cycles |
| KMIP/Vault arg checks | Required PEM paths, vault v2 args |

**Tool:** `pg_tde_change_key_provider` — documented ops path for connection metadata updates.

---

## Slide 11 — Bug regressions (18 tests)

**Module:** `test_bug_reproduction.py`

| Ticket | Issue |
|--------|-------|
| **PG-1805** | UNLOGGED + IDENTITY → invalid page after crash |
| **PG-1806** | WAL optimisation + tablespace move → corrupt page |
| **PG-2278 / PR #554** | SMGR cipher context reuse |
| Additional crash/TRUNCATE/COPY edge cases | WAL threshold, subtransactions, triggers |

**Guards:** filed customer bugs do not reappear.

---

## Slide 12 — Migration & distribution (10 tests)

**Module:** `test_pdg_migration.py`

| Scenario | Examples |
|----------|----------|
| Same-server migration | Percona Distribution doc paths |
| Different-server migration | Dump/restore with TDE |
| Key provider continuity | Keys valid after migration |

---

## Slide 13 — Bash automation layer (~50 scripts)

Not counted in pytest 550 — run via Jenkins `tde-upgrade-parallel` and `test_runner.sh`:

| Category | Example scripts |
|----------|-------------------|
| Upgrade matrix | `pg_tde_upgrade_*.sh` (6 variants) |
| Rewind / HA | `pg_tde_rewind_*.sh` (~15) |
| Vault / OpenBao | `pg_tde_open_bao_tests.sh`, vault mount warnings |
| WAL / encryption GUC | `wal_encrypt_guc_test.sh`, `pg_tde_wal_encryption_*` |
| pgBackRest HA | `pg_tde_pgbackrest_*` |
| Functions smoke | `pg_tde_functions_test.sh` |

**Purpose:** Jenkins parity, long-running scenarios, bash/TAP heritage from pg_tde upstream.

---

## Slide 14 — Multi-OS package smoke (outside pytest)

| Suite | OS matrix | What it proves |
|-------|-----------|----------------|
| `package_testing/` | Debian 11/12, OL8/9, Ubuntu 22/24 | apt/yum install, SQL smoke, uninstall |
| `tarball_testing/` | Same + ssl variants | Tarball install path |

**Guards:** packaging mistakes before **testing → release** promotion.

---

## Slide 15 — What is intentionally out of scope

| Item | Reason |
|------|--------|
| pg_tde unit/TAP in pg_tde repo | Engineering CI (`t/kmip.pl`, meson) |
| Every vendor KMS every nightly | Cosmian in CI; vendors on schedule |
| Customer Ansible/K8s deployments | Environment-specific |
| Citus / TimescaleDB full matrix | Ecosystem compatibility — manual/lab |
| Performance / soak at scale | Separate perf initiative |

---

## Slide 16 — How to run by section

```bash
cd postgresql/pytest && source .env.sh

pytest tests/ -m encryption -v          # core TDE
pytest tests/ -m rewind -v              # HA / rewind
pytest tests/ -m upgrade -v             # major upgrades
pytest tests/ -m minor_upgrade -v         # patch bump
pytest tests/ -m kmip -v                # KMIP providers
pytest tests/ -m "vault or openbao" -v   # Vault / OpenBao

pytest tests/ --skip-sections=upgrade,slow -v   # fast regression
pytest --list-test-sections                       # all sections
```

---

## Slide 17 — Summary for management

> **550 automated pytest scenarios** exercise encryption, keys, upgrades, HA, backup, replication, and every supported external KMS — on ephemeral clusters that mirror production configuration. **~50 bash scripts** extend this for Jenkins upgrade matrices. **Multi-OS Vagrant smoke** gates package promotion. Together this is the evidence package QA uses before recommending **testing → release**.

---

## Appendix — pytest module index

| Module | Tests | Marker / theme |
|--------|------:|----------------|
| `test_encryption.py` | 82 | `encryption` |
| `test_tde_rewind_advanced.py` | 97 | `rewind` |
| `test_tde_pg_upgrade.py` | 48 | `upgrade` |
| `test_upgrade.py` | 47 | `upgrade` |
| `test_waldump.py` | 27 | `waldump` |
| `test_kmip.py` | 24 | `kmip` |
| `test_partitioning.py` | 21 | `encryption` |
| `test_pgbackrest.py` | 19 | `pgbackrest` |
| `test_bug_reproduction.py` | 18 | `bug` |
| `test_cipher.py` | 18 | `encryption` |
| `test_change_key_provider.py` | 16 | `encryption` |
| `test_tde_cli_tools.py` | 15 | `encryption` |
| `test_replication.py` | 14 | `replication` |
| `test_template_databases.py` | 14 | `encryption` |
| `test_tde_minor_upgrade.py` | 11 | `minor_upgrade` |
| `test_pdg_migration.py` | 10 | `migration` |
| `test_recovery.py` | 10 | `recovery` |
| `test_vault_providers.py` | 10 | `vault` |
| `test_kmip_common_matrix.py` | 9 | `kmip_matrix` |
| `test_openbao_bash_parity.py` | 8 | `openbao` |
| `test_external_key_provider_regressions.py` | 7 | `kmip`, `vault`, `openbao` |
| `test_unlogged_recovery.py` | 7 | `recovery` |
| `test_pg_basebackup.py` | 6 | `backup` |
| `test_vault_kv_common_matrix.py` | 3 | `vault` |
| `test_file_keyring_common_matrix.py` | 2 | `encryption` |
| `test_vault_hashicorp_parity.py` | 2 | `vault` |
| `test_vault_kmip.py` | 2 | `vault_kmip` |
| `test_pitr.py` | 2 | `backup` |
| `test_kmip_server_revalidation.py` | 1×N | `kmip_revalidation` (per profile) |
| **Total** | **550** | |
