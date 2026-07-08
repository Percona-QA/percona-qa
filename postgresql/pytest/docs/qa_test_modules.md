# pg_tde Test Modules — Coverage by Area

> **Audience:** QA, build/release, management  
> **Related:** [QA workflow](qa_workflow.md) · [Test coverage summary](qa_test_coverage_executive_summary.md) · [Test sections](test_sections.md)  
> **Scale:** ~550 automated pytest scenarios (+ bash automation and multi-OS package smoke)

This document describes **what pg_tde areas we test**, grouped by **functional module**.
It does not reference source file names — only product behaviour and scenarios.

---

## Module overview

| # | Module | Approx. scenarios | Primary focus |
|---|--------|------------------:|---------------|
| 1 | Core encryption & SQL API | 82 | Tables, GUCs, extension lifecycle |
| 2 | Cipher & SMGR | 18 | AES-128/256, cipher context reuse |
| 3 | Providers & keys | 40+ | File keyring, global/DB scope, rotation |
| 4 | KMIP key providers | 34+ | Cosmian + vendor KMS matrix |
| 5 | Vault KV & OpenBao | 23+ | Production secret-store path |
| 6 | Major upgrade (`pg_tde_upgrade`) | 48 | PG 17→18, same data directory |
| 7 | Major upgrade (`pg_upgrade`) | 47 | New PGDATA, heap + TDE |
| 8 | Minor upgrade (in-place) | 11 | Patch bump, `ALTER EXTENSION` |
| 9 | pg_tde_rewind / HA | 97 | Failover, rewind, chaos loops |
| 10 | pgBackRest integration | 19 | Backup/restore with encryption |
| 11 | Base backup | 6 | Streaming backup, HA rebuild |
| 12 | Point-in-time recovery | 2 | PITR with encrypted WAL |
| 13 | Crash & WAL recovery | 17 | Recovery, relfilenode reuse |
| 14 | Replication | 14 | Physical + logical |
| 15 | CLI tools | 15 | checksums, resetwal, archive tools |
| 16 | WAL dump | 27 | `pg_tde_waldump` vs plain waldump |
| 17 | Partitioned tables | 21 | Range/list/hash × TDE |
| 18 | Unlogged tables | 25+ | UNLOGGED + IDENTITY, crash paths |
| 19 | Template databases | 14 | `CREATE DATABASE … TEMPLATE` |
| 20 | Offline key-provider change | 16 | `pg_tde_change_key_provider` |
| 21 | Distribution migration | 10 | Same/different server migration |
| 22 | Bug regressions | 18 | Filed Jira tickets |
| 23 | External-provider regressions | 7 | libkmip, namespace, lifecycle |

---

## 1. Core encryption & SQL API

**What it covers:** Day-to-day pg_tde behaviour after `CREATE EXTENSION pg_tde`.

| Area | Scenarios |
|------|-----------|
| Extension setup | Load `shared_preload_libraries`, create extension, version checks |
| Encrypted access method | `CREATE TABLE … USING tde_heap`, read/write, `pg_tde_is_encrypted()` |
| Tablespaces | `ALTER DATABASE … SET TABLESPACE`, encrypted data in custom tablespaces |
| WAL encryption GUCs | Enable/disable WAL encryption, segment size interactions |
| Checksums | Data checksums with TDE enabled |
| Dynamic encryption state | Toggle encryption settings under load |
| Enforce encryption | Policies that require TDE for new tables |
| Verify / delete key APIs | `pg_tde_verify_key`, key deletion rules |
| Negative cases | Invalid provider names, missing keys, bad configuration |

---

## 2. Cipher tests

**What it covers:** Encryption algorithm choice and low-level cipher behaviour (SMGR layer).

| Area | Scenarios |
|------|-----------|
| AES-128 / AES-256 | Full suite survives cluster restart |
| Independent keys | Two relations, different keys, decrypt independently |
| SMGR cipher reuse | Cipher context reuse across operations (PR #554 / PG-2278) |
| GUC `pg_tde.cipher` | Valid/invalid cipher settings |
| Restart survival | Data intact after stop/start with each cipher |

---

## 3. Providers & keys

**What it covers:** All key-provider types at **file keyring** level and generic SQL APIs (before external KMS).

| Area | Scenarios |
|------|-----------|
| Global providers | Add, list, delete global key providers |
| Database-scoped providers | Per-database keyring isolation |
| Principal key lifecycle | Create key, set server key, set default key, rotate |
| Multi-database | Different keys per database on one cluster |
| Change provider (online SQL) | `pg_tde_change_*_key_provider_*` while cluster running |
| Delete provider rules | Cannot delete provider in use; catalog consistency |
| Inherit / delete global | Child databases and provider inheritance |
| File keyring matrix | Shared smoke scenarios on local file provider |

---

## 4. KMIP key providers

**What it covers:** Key Management Interoperability Protocol — remote KMS integration.

| Area | Scenarios |
|------|-----------|
| Provider registration | Add global/database KMIP provider (host, port, TLS certs) |
| Key lifecycle | Create key on KMS, set principal key, encrypted DML |
| Restart | Cluster stop/start; keys still resolve from KMS |
| Rotation | Principal key rotation via KMIP |
| Multi-database | Separate KMIP keys per database |
| Mixed topology | File + KMIP providers on same cluster |
| Online provider change | `change_*_key_provider_kmip` (connection metadata) |
| Offline CLI change | `pg_tde_change_key_provider` with KMIP args (server stopped) |
| Delete provider | Catalog rules for KMIP providers |
| Failure cases | Bad host, unreachable server, auth errors |
| WAL / server key | Server key and WAL encryption with KMIP |
| Dump / restore | Logical dump paths with KMIP keys |
| Vendor revalidation | Full checklist per KMS (Cosmian, Fortanix, Thales, Akeyless) |
| libkmip regression | C++ kmipclient lifecycle (PG-2125) |

**Backends exercised:** Cosmian (every CI build), Fortanix, Thales CipherTrust, Akeyless (scheduled sign-off), Vault KMIP engine (lab only).

---

## 5. Vault KV & OpenBao

**What it covers:** Production-recommended HashiCorp Vault **KV v2** and OpenBao parity.

| Area | Scenarios |
|------|-----------|
| Vault KV v2 | Add provider, create/set key, encrypted tables |
| Namespaces | Enterprise namespace + mount (`pg_tde`, `ns1/`) |
| OpenBao | Namespace scenarios, bash-parity scenarios 4–10, 12 |
| Change provider | `change_database_key_provider_vault_v2` |
| Mount permissions | Warning when mount metadata insufficient |
| Shared matrix | Same core scenarios as KMIP/file (smoke, rotation, multi-DB) |
| Namespace regression | PG-1959 Vault/OpenBao namespace edge cases |

**Note:** Vault **KMIP engine** is a separate lab module (customer Register -2 repro), not the production path.

---

## 6. Major upgrade — `pg_tde_upgrade` (same data directory)

**What it covers:** In-place major version bump (typically PostgreSQL 17 → 18) using the pg_tde upgrade wrapper.

| Area | Scenarios |
|------|-----------|
| Basic smoke | Upgrade empty and populated clusters |
| PPG → PSP paths | Percona package lineage permutations |
| PSP → PSP | Same vendor line major bump |
| Access methods | heap ↔ tde_heap combinations preserved |
| WAL encryption | Upgrade with WAL encryption on/off |
| Multi-database keys | Keys per DB survive upgrade |
| Complex schema | Partitions, FKs, TOAST, mixed objects |
| PITR after upgrade | Encrypted WAL + recovery post-upgrade |
| Enforce encryption | GUC state after upgrade |
| Upgrade modes | `--check`, link mode, dry-run paths |
| PG-2381 | Empty key migration edge case |
| PG-2379 | Multi-DB key migration |
| Bash script parity | Same scenarios as automation shell scripts |
| Extreme corner cases | Large schemas, unusual key states |

---

## 7. Major upgrade — `pg_upgrade` (new PGDATA)

**What it covers:** Standard PostgreSQL major upgrade tool with TDE tables.

| Area | Scenarios |
|------|-----------|
| Smoke | Basic pg_upgrade with tde_heap tables |
| Checksums | Upgrade with data checksums enabled |
| Extensions | pg_tde extension survives pg_upgrade |
| Data integrity | Row counts, constraints after upgrade |
| Multi-database | All DBs with TDE |
| Link vs copy mode | `--link` and copy-based upgrade |
| Parallel jobs | pg_upgrade `-j` with TDE |
| Multi-hop | Sequential major upgrades |
| Config preservation | postgresql.conf / GUCs |
| Post-maintenance | VACUUM, ANALYZE after upgrade |
| Negative cases | Wrong paths, missing old cluster, failed pre-checks |
| TDE corner cases | Mixed heap/TDE, large tables |
| Replication state | Slots/publications where applicable |
| Scale | Larger table counts |

---

## 8. Minor upgrade (in-place patch bump)

**What it covers:** Same PostgreSQL major, newer pg_tde/PostgreSQL patch (e.g. 18.4.1 → 18.4.2).

| Area | Scenarios |
|------|-----------|
| Pre-conditions | Extension version, package tier checks |
| Staged Setup | Populate encrypted cluster, save state |
| Package upgrade | apt/yum install new patch (operator step) |
| Staged Verify | Keys, tables, DML after upgrade |
| `ALTER EXTENSION pg_tde UPDATE` | Extension SQL migration |
| Rolling restart | Multiple stop/start cycles |
| WAL archiving | Archiving continuity across bump |
| HA variant | Setup/Verify with primary + standby |
| PG-2381 minor path | Churn scenario on patch upgrade |

Persistent data directory across Setup and Verify (staged workflow).

---

## 9. pg_tde_rewind / HA

**What it covers:** High availability — promote standby, rewind former primary, encrypted data intact.

| Area | Scenarios |
|------|-----------|
| Basic rewind | Simple timeline divergence, `--source-server` |
| Extended scenarios | Multiple tables, tablespaces, growing files |
| Checkpoint interaction | Rewind around checkpoint boundaries |
| Randomized | Non-deterministic file change patterns |
| WAL encryption | Rewind with encrypted WAL segments |
| Full HA cycle | Promote → rewind → rejoin pattern |
| Chaos loop | Repeated failover + rewind under load |
| Sysbench-driven | Sustained DML during failover loop |
| Key provider edges | Rewind after key rotation / provider change |
| Data structures | FSM, VM forks, relfilenode edge cases |
| Negative | Unclean shutdown, bad timeline, missing files |
| Multi-round | Several promote/rewind cycles in sequence |
| Encrypted WAL TAP parity | Ports of upstream TAP rewind scenarios |
| Extreme corner cases | Unusual timeline / fork combinations |

---

## 10. pgBackRest integration

**What it covers:** Percona pgBackRest backup and restore with encrypted PostgreSQL data.

| Area | Scenarios |
|------|-----------|
| Full backup / restore | stanza create, backup, restore, verify data |
| Incremental / diff | Chain of backups with TDE |
| Encrypted WAL | Backup behaviour with WAL encryption |
| Matrix scenarios | Multiple backup types and restore paths |
| Advanced / negative | Missing stanza, corrupt backup, wrong paths |
| HA failover rebuild | Backup after promote, rebuild standby |
| Wrapper contract | Encrypted WAL wrapper integration |

---

## 11. Base backup

**What it covers:** Native PostgreSQL base backup and pg_tde-specific base backup tool.

| Area | Scenarios |
|------|-----------|
| `pg_basebackup` | Streaming base backup from TDE primary |
| `pg_tde_basebackup` | TDE-aware base backup binary |
| WAL encryption | Base backup with encrypted WAL |
| HA rebuild | Rebuild standby from backup after failover |

---

## 12. Point-in-time recovery (PITR)

**What it covers:** Recovery to a point in time with encrypted WAL.

| Area | Scenarios |
|------|-----------|
| PITR smoke | Base backup + WAL archive → recover to timestamp |
| Encrypted WAL archive | PITR when WAL segments are encrypted |

---

## 13. Crash & WAL recovery

**What it covers:** Crash recovery, relfilenode reuse, WAL helper utilities.

| Area | Scenarios |
|------|-----------|
| Crash recovery | SIGKILL / immediate stop → restart → data valid |
| Relfilenode reuse | Relation file reuse after DROP/CREATE |
| WAL utilities | Archive cleanup, receive WAL paths |
| Unlogged reinit | UNLOGGED table re-init after crash (default & custom tablespace) |
| UNLOGGED + sequences | Identity/serial behaviour after reinit |

---

## 14. Replication

**What it covers:** Physical and logical replication with pg_tde loaded.

| Area | Scenarios |
|------|-----------|
| Streaming replication | Primary → standby, encrypted tables replicate |
| TDE-specific streaming | Key material available on standby |
| Standby promotion | Promote standby, former primary demoted |
| Logical replication | Publication/subscription with tde_heap |
| WAL segment size | Replication under non-default WAL seg size |

---

## 15. CLI tools

**What it covers:** pg_tde command-line utilities shipped with the extension.

| Tool | Scenarios |
|------|-----------|
| `pg_tde_checksums` | Verify/checksums on encrypted cluster |
| `pg_resetwal` / `pg_tde_resetwal` | Reset WAL after corruption scenarios |
| `pg_tde_archive_decrypt` | Decrypt archived WAL for inspection/recovery |
| `pg_tde_restore_encrypt` | Re-encrypt restored WAL segments |
| Negative CLI | Missing args, bad paths, server running when must be stopped |

---

## 16. WAL dump

**What it covers:** Inspecting WAL records on encrypted clusters.

| Area | Scenarios |
|------|-----------|
| Encrypted vs plain | `pg_waldump` vs `pg_tde_waldump` on same WAL |
| Data types | Heap, btree, gist, hash record visibility |
| Relation kinds | Different rel kinds in WAL output |
| Filters | Start/end LSN, rmgr filters |
| Plaintext WAL mode | Behaviour when WAL encryption off |
| Custom resource manager | pg_tde RMGR (ID 140) registered at startup |

---

## 17. Partitioned tables

**What it covers:** Declarative partitioning with `tde_heap`.

| Area | Scenarios |
|------|-----------|
| Partition types | Range, list, hash partitioned TDE tables |
| Attach/detach | Partition attach and detach |
| DML | INSERT/UPDATE/DELETE across partitions |
| Corner cases | Default partition, multi-level, index-only scans |

---

## 18. Unlogged tables & WAL optimisation

**What it covers:** UNLOGGED relations and WAL-skipping edge cases with TDE.

| Area | Scenarios |
|------|-----------|
| UNLOGGED + IDENTITY | PG-1805 regression (invalid page after crash) |
| UNLOGGED without IDENTITY | Control scenario |
| WAL optimisation | PG-1806 (tablespace move + index in one xact, minimal WAL) |
| TRUNCATE / COPY | Crash during TRUNCATE, COPY, prepared xacts |
| Subtransactions | Nested subtransactions + tablespace SET |
| Temp tables | No orphan relfilenodes after temp use |

---

## 19. Template databases

**What it covers:** Creating new databases from TDE-enabled templates.

| Area | Scenarios |
|------|-----------|
| Template with TDE | `CREATE DATABASE … TEMPLATE` preserves encryption |
| Key inheritance | New DB uses correct key provider state |
| Mixed templates | Template from DB with/without TDE |

---

## 20. Offline key-provider change

**What it covers:** `pg_tde_change_key_provider` CLI (server **must** be stopped).

| Area | Scenarios |
|------|-----------|
| File provider | Change keyring file path offline |
| Persistence | Change survives multiple restarts |
| Isolation | Unrelated providers untouched |
| Validation | Bad OID, missing PGDATA, wrong provider type |
| KMIP / Vault args | Required PEM paths and vault v2 arguments validated |
| Negative | Nonexistent data directory, legacy vault type rejected |

---

## 21. Distribution migration

**What it covers:** Migrating PostgreSQL + pg_tde per Percona Distribution documentation.

| Area | Scenarios |
|------|-----------|
| Same server | Upgrade/migrate on one host |
| Different server | Dump/restore or replication-style move |
| pg_tde continuity | Keys and encrypted tables valid after migrate |
| Cross minor version | Migration across minor PG versions |

---

## 22. Bug regressions

**What it covers:** Specific filed bugs — must never reappear.

| Ticket | Issue |
|--------|-------|
| PG-1805 | UNLOGGED + IDENTITY → corrupt page after recovery |
| PG-1806 | WAL skip + tablespace move → corrupt page after crash |
| PG-2125 | KMIP C++ client / libkmip rewrite |
| PG-1959 | Vault/OpenBao namespace handling |
| PG-2278 / PR #554 | SMGR cipher context reuse |
| PG-2379 | Multi-DB key migration on major upgrade |
| PG-2381 | Empty key migration on upgrade |

---

## 23. Bash automation layer (Jenkins parity)

**Not counted in pytest 550** — complementary shell scenarios:

| Category | Examples |
|----------|----------|
| Upgrade matrix | Basic, WAL encryption, access methods, multi-DB, PPG↔PSP |
| Rewind / HA | Loop test, negative, key-provider edges, full HA cycle |
| Vault / OpenBao | OpenBao scenario scripts, mount permission warnings |
| WAL / GUC | WAL encrypt GUC, segment size, archive paths |
| Functions smoke | SQL function coverage script |
| pgBackRest HA | Failover + rebuild matrix |
| Partition / template | Shell parity for partition and template DB tests |

Run via Jenkins `tde-upgrade-parallel` or `automation/wrapper/test_runner.sh`.

---

## 24. Multi-OS package smoke (pre-release)

**Outside pytest** — Vagrant matrices under `package_testing/` and `tarball_testing/`:

| Check | Platforms |
|-------|-----------|
| Package install | Debian 11/12, Oracle Linux 8/9, Ubuntu 22/24 |
| Tarball install | Same + SSL variant smoke |
| SQL smoke | File keyring, WAL encrypt, extension load, uninstall |

---

## How modules map to test runs

```bash
cd postgresql/pytest && source .env.sh

pytest tests/ -m encryption -v       # Modules 1–3, 17–19
pytest tests/ -m kmip -v               # Module 4
pytest tests/ -m "vault or openbao" -v  # Module 5
pytest tests/ -m upgrade -v            # Modules 6–7
pytest tests/ -m minor_upgrade -v      # Module 8
pytest tests/ -m rewind -v             # Module 9
pytest tests/ -m pgbackrest -v         # Module 10
pytest tests/ -m backup -v             # Modules 11–12
pytest tests/ -m recovery -v           # Module 13
pytest tests/ -m replication -v        # Module 14
pytest tests/ -m waldump -v            # Module 16
pytest tests/ -m bug -v                # Module 22

pytest tests/ --skip-sections=upgrade,slow -v   # Fast core pass
pytest --list-test-sections
```

---

## Summary

**23 functional modules** in pytest cover encryption, keys, every supported KMS, both major upgrade tools, minor in-place upgrades, HA/rewind, backup/DR, replication, CLI utilities, and filed bug regressions. Bash automation and multi-OS smoke extend this for Jenkins and release promotion.

For per-test detail (purpose, flow, asserts), see the deep catalog:
`coverage_reports/test_catalog_2026-05-14.md`.
