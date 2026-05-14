# pg_tde / pytest — Deep Test Catalog (2026-05-14)

> **Audience**: anyone who needs to know what every test in
> `postgresql/pytest/tests/` actually does, why it exists, and what
> regression it guards against.
>
> **Scope**: 412 tests across 16 test modules. Tests are listed in the
> order they appear in the source files. Each test is documented with:
>
> * **Purpose** — one-line statement of what's under test.
> * **Flow** — the operative steps the test takes.
> * **Asserts / catches** — what proves pass/fail and what regression
>   it would catch.
>
> Last refreshed: 2026-05-14.

---

## 0. Table of contents

| # | Module | Tests | Theme |
|---|---|---|---|
| 1 | `test_bug_reproduction.py` | 6 | Bug-ticket regressions (PG-1805 / PG-1806) |
| 2 | `test_change_key_provider.py` | 16 | `pg_tde_change_key_provider` CLI (offline) |
| 3 | `test_encryption.py` | 100 | Core pg_tde encryption, GUCs, key providers, SQL API |
| 4 | `test_partitioning.py` | 21 | Partitioned tables × tde_heap |
| 5 | `test_pg_basebackup.py` | 6 | `pg_basebackup` / `pg_tde_basebackup` |
| 6 | `test_pgbackrest.py` | 23 | pgBackRest integration |
| 7 | `test_pitr.py` | 2 | Point-in-time recovery |
| 8 | `test_recovery.py` | 10 | Crash recovery + WAL utilities |
| 9 | `test_replication.py` | 13 | Streaming + logical replication |
| 10 | `test_tde_cli_tools.py` | 12 | `pg_tde_checksums` / `_resetwal` / `_archive_decrypt` / `_restore_encrypt` |
| 11 | `test_tde_minor_upgrade.py` | 36 | pg_tde minor-version upgrade procedure |
| 12 | `test_tde_pg_upgrade.py` | 41 | Major version upgrade via `pg_tde_upgrade` |
| 13 | `test_tde_rewind_advanced.py` | 78 | `pg_tde_rewind` HA/lifecycle |
| 14 | `test_template_databases.py` | 14 | `CREATE DATABASE ... TEMPLATE` × pg_tde |
| 15 | `test_upgrade.py` | 62 | Mixed/negative upgrade scenarios |
| 16 | `test_waldump.py` | 33 | `pg_tde_waldump` |

**Conventions used in this document**

* `tde_primary` / `tde_replica_pair` / `tde_logical_pub_sub_pair`: pytest
  fixtures from `conftest.py` that build clusters with `pg_tde` loaded,
  a global file key provider, a server key, and `default_table_access_method
  = tde_heap` on `postgres`.
* "EOF-tail" exit (in `test_waldump.py`): `pg_waldump` / `pg_tde_waldump`
  legitimately exits non-zero when it hits the zero-padded tail of a
  switched segment. Helper `_assert_ok_or_eof_tail` accepts that.
* "Plain heap" = `USING heap`; "tde_heap" = `USING tde_heap`.

---

## 1. `test_bug_reproduction.py` (6 tests)

Module covers two filed bug tickets:

* **PG-1805** — pg_tde × UNLOGGED tables with IDENTITY → "invalid page
  in block 0" on the first INSERT after crash recovery.
* **PG-1806** — pg_tde × WAL optimisation (tablespace move + index
  create in one transaction, `wal_level=minimal`, `wal_skip_threshold=0`)
  → corrupt page after crash recovery.

### `TestPG1805` (3 tests)

#### 1.1 `test_unlogged_with_identity_survives_recovery`

* **Purpose** — regression guard for PG-1805 itself.
* **Flow** — build a TDE cluster, `CREATE UNLOGGED TABLE … IDENTITY
  PRIMARY KEY`, insert one row, CHECKPOINT, delete the relation's main
  / `_vm` / `_fsm` fork files on disk (simulates the post-crash reinit
  path), SIGKILL the postmaster (`stop mode="immediate"`), start again,
  attempt an INSERT.
* **Catches** — if PG-1805 regresses, the INSERT fails with the
  documented "invalid page" error; if the recovery path reinits the
  table but loses the identity sequence, COUNT(\*) drifts off `1`.

#### 1.2 `test_logged_table_with_identity_unaffected`

* **Purpose** — control: ordinary (logged) IDENTITY tables must never
  be affected by the PG-1805 code path.
* **Flow** — same TDE cluster, regular logged table, CHECKPOINT,
  SIGKILL, start, INSERT; assert two rows.
* **Catches** — a fix that over-reaches and breaks normal IDENTITY
  tables.

#### 1.3 `test_unlogged_without_identity_unaffected`

* **Purpose** — second control: unlogged-but-no-identity must work.
* **Flow** — drop the fork files, immediate-stop / start, INSERT a new
  row; the post-recovery table is empty so COUNT = `1`.

### `TestPG1806` (3 tests — and the fourth was retired into the others)

#### 1.4 `test_tablespace_move_and_index_survives_crash`

* **Purpose** — exact PG-1806 trigger.
* **Flow** — `wal_level=minimal`, `wal_skip_threshold=0`, `wal_log_hints=on`,
  `max_wal_senders=0`. Single BEGIN ... COMMIT that (a) `ALTER TABLE
  moved SET TABLESPACE extra_tsp`, (b) `CREATE TABLE originated …`,
  (c) `INSERT INTO originated …`, (d) `CREATE UNIQUE INDEX …
  TABLESPACE extra_tsp`. Then immediate-stop / start.
* **Catches** — post-recovery the cluster must start, the moved heap
  must contain the original row, and the new unique index must enforce
  uniqueness (verified via an `ON CONFLICT … DO UPDATE` round-trip).
  Failure modes: cluster won't start, SELECT errors, or duplicate
  insert succeeds.

#### 1.5 `test_wal_level_replica_not_affected`

* **Purpose** — baseline that `wal_level=replica` does NOT tickle
  PG-1806.
* **Flow** — same DDL as 1.4 but with `wal_level=replica` (and
  `max_wal_senders=5`); post-crash everything must just work.

#### 1.6 `test_max_wal_senders_zero_rejected_then_five_recovers`

* **Purpose** — sanity that the GUC toggle works either way under TDE.
* **Flow** — start with `max_wal_senders=0` + `wal_level=replica` →
  insert and verify → switch to `max_wal_senders=5` → restart → insert
  another row → verify both rows survive.

#### 1.7 `test_normal_wal_threshold_not_affected`

* **Purpose** — control: with `wal_skip_threshold` at its default,
  PG-1806 does not trigger even on `wal_level=minimal`.
* **Flow** — same DDL as 1.4, default `wal_skip_threshold`. Stop /
  start / verify.

---

## 2. `test_change_key_provider.py` (16 tests)

Module covers the **offline** CLI `pg_tde_change_key_provider`,
documented at
https://docs.percona.com/pg-tde/command-line-tools/pg-tde-change-key-provider.html.
Server must be stopped while the tool runs; it edits `$PGDATA/pg_tde/`.

`TestPgTdeChangeKeyProviderCLI` — file-provider scenarios only (vault /
kmip variants live in bash automation, blocked on external services).

### 2.1 `test_binary_exists`

* **Purpose** — sanity: the CLI ships in the build.
* **Flow** — assert `install_dir / "bin" / "pg_tde_change_key_provider"`
  exists.
* **Catches** — accidental drop of the tool from a package.

### 2.2 `test_change_file_provider_path_offline`

* **Purpose** — the canonical happy-path use case.
* **Flow** — TDE cluster with a *database-scope* file provider,
  insert encrypted rows, stop the server, copy keyfile to new path and
  `unlink` the old one, run `pg_tde_change_key_provider -D <PGDATA>
  <dbOid> ckp_provider file <new_path>`, restart.
* **Asserts** — `returncode == 0`, encrypted SELECT returns the 200
  rows (proving the cluster now reads the key from the new path), and
  `pg_tde_list_all_database_key_providers()` reports the new path in
  its `options` column.
* **Catches** — silent no-op (file untouched, old path still in use),
  or successful exit while the cluster fails to start.

### 2.3 `test_change_kp_uses_pgdata_env_when_d_flag_absent`

* **Purpose** — PG-1452 regression: the tool used to require `-D`
  unconditionally; it must now also accept `PGDATA` from env.
* **Flow** — same as 2.2 but no `-D`, pass `PGDATA=<dir>` via env.
* **Asserts** — `returncode == 0` + encrypted data readable after
  restart.

### 2.4 `test_change_kp_fails_without_any_data_dir`

* **Purpose** — no `-D` and empty `PGDATA` → non-zero exit (refuse to
  guess a data directory).
* **Catches** — silent corruption of an unintended directory.

### 2.5 `test_change_kp_fails_with_unknown_provider_name`

* **Purpose** — supplying a name that's not in the catalog must error
  out (not silently no-op).

### 2.6 `test_change_kp_fails_with_invalid_provider_type`

* **Purpose** — type other than `file` / `vault-v2` / `kmip` rejected.

### 2.7 `test_change_persists_across_multiple_restart_cycles`

* **Purpose** — the edit to `$PGDATA/pg_tde/` must be **durable** —
  not honoured only on the first post-change start.
* **Flow** — change keyfile path, then stop/start three times in a
  row, each cycle reading 75 encrypted rows.
* **Catches** — write-amplification or cache-invalidation bugs where
  the new path is honoured once and then reverts.

### 2.8 `test_change_does_not_disturb_unrelated_providers`

* **Purpose** — with two providers configured, changing one must leave
  the other byte-identical.
* **Flow** — register `bystander_provider`, snapshot its `options`
  string, perform the offline change on `ckp_provider`, restart, fetch
  `bystander_provider.options` again.
* **Asserts** — bystander's options string is byte-identical
  before/after. Target provider's options reflect the new path.
* **Catches** — CLI that rewrites the whole `pg_tde` state file and
  accidentally mutates unrelated entries.

### 2.9 `test_change_kp_fails_with_non_numeric_dboid`

* **Purpose** — `dbOid` is documented as an integer. Non-numeric
  values must be rejected at parse time, not silently coerced to 0.

### 2.10 `test_change_kp_fails_with_negative_dboid`

* **Purpose** — PostgreSQL OIDs are unsigned 4-byte ints. `-1` must
  not wrap or coerce.

### 2.11 `test_change_kp_fails_with_nonexistent_data_dir`

* **Purpose** — `-D /path/that/does/not/exist` → non-zero exit.

### 2.12 `test_change_kp_fails_with_non_pgdata_directory`

* **Purpose** — `-D <empty dir>` (no `PG_VERSION`, no `pg_tde/`) →
  non-zero exit (don't write into arbitrary directories).

### 2.13 `test_change_kp_fails_with_missing_path_for_file_type`

* **Purpose** — `file` provider type requires a path argument.
* **Flow** — invoke without the path → expect failure → restart cluster
  → assert it still starts cleanly (proves the failed call didn't
  half-write a broken state file).

### 2.14 `test_change_kp_fails_with_legacy_vault_provider_type`

* **Purpose** — only `vault-v2` is supported; the legacy `vault` token
  (still in older docs) must be rejected with a clear error.

### 2.15 `test_change_kp_fails_with_missing_vault_v2_required_args`

* **Purpose** — `vault-v2` requires url + mount + token_path. Missing
  token_path → usage error.

### 2.16 `test_change_kp_fails_with_missing_kmip_required_args`

* **Purpose** — `kmip` requires host + port + cert_path + key_path.
  Missing key_path → usage error.

---

## 7. `test_pitr.py` (2 tests)

Point-in-time recovery via `archive_command` + `restore_command` to a
`recovery_target_time` target. Distinct from `test_pg_basebackup.py`
(filesystem basebackup, no WAL replay) and `test_pgbackrest.py` (external
tool driving the same workflow).

### 7.1 `TestPitr.test_pitr_plain`

* **Purpose** — vanilla PITR: take a cold cluster copy, drop a table
  after a marker timestamp, recover the copy to that timestamp.
* **Flow** —
  1. Enable `archive_mode=on` + `archive_command='cp %p <dir>/%f'`.
  2. `CREATE TABLE pitr_tbl`, INSERT 100 rows.
  3. Stop cluster, `shutil.copytree` of $PGDATA to `pitr_restore/`
     (this is the cold base copy — **taken before** the PITR target
     time, fixing the original timing bug).
  4. Restart, capture `pitr_time = now()`, sleep 1s, `DROP TABLE
     pitr_tbl`, switch WAL, sleep 1s for the archiver, stop.
  5. Start a *second* PgCluster pointing at the copied data dir on a
     new port. Replace `postgresql.auto.conf` with `recovery_target_time
     = '<pitr_time>'`, `recovery_target_action = promote`,
     `restore_command = 'cp <archive_dir>/%f %p'`. Touch
     `recovery.signal`.
* **Asserts** — `SELECT COUNT(*) FROM pitr_tbl` on the recovered
  cluster returns `100` (i.e. the drop never replayed).

### 7.2 `TestPitr.test_pitr_encrypted_wal`

* **Purpose** — PITR with `pg_tde.wal_encrypt = on` AND the
  `pg_tde_archive_decrypt` / `pg_tde_restore_encrypt` wrappers.
* **Flow** — same shape as 7.1 but on `tde_primary`:
  * `archive_command` built via `archive_restore_conf_values(...,
    use_tde_wrappers=True)` — invokes `pg_tde_archive_decrypt` to
    write decryptable copies to the archive.
  * Recovery cluster brought up with `shared_preload_libraries='pg_tde'`,
    `default_table_access_method='tde_heap'`, `pg_tde.wal_encrypt='on'`,
    and `restore_command` built via `restore_conf_line_raw(...,
    use_tde_wrappers=True)`.
* **Catches** — any breakage in the encrypted-WAL PITR path:
  archived segments unreadable, missing wrappers, or recovery failing
  to engage WAL decryption.

---

## 5. `test_pg_basebackup.py` (6 tests)

### `TestPgBaseBackup` (3 tests)

#### 5.1 `test_basebackup_plain_cluster`

* **Purpose** — smoke test of `pg_basebackup` against a plaintext cluster.
* **Flow** — INSERT 100 rows, `PgBaseBackup(primary_cluster).take(backup_dir)`,
  assert `<backup_dir>/PG_VERSION` exists.

#### 5.2 `test_basebackup_with_tde`

* **Purpose** — smoke test of `pg_tde_basebackup` against a TDE cluster.
* **Flow** — same as 5.1 but via `TdeManager.tde_basebackup`.

#### 5.3 `test_restore_from_basebackup`

* **Purpose** — end-to-end restore round-trip.
* **Flow** — INSERT 1000 rows, take a basebackup, copy it to a fresh
  data dir on a new port, start the second cluster, `SELECT COUNT(*)`
  must return 1000.

### `TestTdeHaFailoverRebuild` (1 test)

#### 5.4 `test_ha_failover_and_rebuild`

* **Purpose** — HA failover: kill primary, promote standby, rebuild
  the dead primary as the new standby via `pg_tde_basebackup`.
* **Flow** — Start with `tde_replica_pair`, INSERT 1000 rows on the
  primary, wait for catchup, stop primary, promote standby, INSERT
  rows 1001-2000 on the new primary. Wipe the old primary's data dir,
  rebuild it via `tde_basebackup` from the new primary, configure
  `primary_conninfo` to point at the new primary, restart, wait for
  catchup, assert COUNT == 2000.

### `TestPgTdeBaseBackupWalEncryption` (2 tests)

Covers the `-E` flag of `pg_tde_basebackup`.

#### 5.5 `test_pg_tde_basebackup_E_creates_encrypted_target`

* **Purpose** — `-E` must produce encrypted WAL on the *destination*.
* **Flow** — `enable_wal_encryption()` on the source so the WAL is
  encrypted with the source key. Insert a unique plaintext marker
  before the backup. `tde_basebackup(..., encrypt_wal=True)` (which
  pre-seeds `pg_tde/` on the target). Iterate over every 24-char WAL
  segment file in `<dst>/pg_wal/` and assert the marker bytes are NOT
  present in any of them.
* **Asserts** — `pg_tde/` directory exists on the target;
  no plaintext marker leaks on disk; the target is self-decryptable.

#### 5.6 `test_pg_tde_basebackup_warning_when_E_missing`

* **Purpose** — when the source has TDE keys configured but `-E` is
  omitted, `pg_tde_basebackup` must emit the "source has WAL keys, but
  no WAL encryption configured for the target backups" warning. With
  `-E` it must NOT emit that warning.
* **Flow** — runs `pg_tde_basebackup` twice via raw `subprocess.run`
  (so stderr is captured): first without `-E`, then again with `-E`
  and a pre-seeded `pg_tde/` directory.
* **Asserts** — phrase `"WAL keys"` present in stderr without `-E`,
  absent with `-E`. Both runs `returncode == 0`.

---

## 8. `test_recovery.py` (10 tests)

### `TestCrashRecovery` (5 tests)

#### 8.1 `test_data_survives_crash_plain`

* **Purpose** — baseline: plain cluster, CHECKPOINT, SIGKILL, restart,
  data still there.

#### 8.2 `test_data_survives_crash_tde`

* **Purpose** — same shape on `tde_primary`.

#### 8.3 `test_immediate_shutdown_recovery`

* **Purpose** — clean immediate-mode shutdown plus recovery. INSERT
  data may or may not be on disk; recovery must still succeed
  (`count >= 0`).

#### 8.4 `test_crash_then_insert`

* **Purpose** — post-recovery the cluster must be fully writable.
  Insert pre-crash + post-crash batches, assert combined count.

#### 8.5 `test_crash_recovery_with_wal_encryption`

* **Purpose** — force the **encrypted-WAL replay** path. Existing
  `test_data_survives_crash_tde` CHECKPOINTs before SIGKILL so recovery
  is trivial; this one inserts AFTER the CHECKPOINT and SIGKILLs without
  another checkpoint, so those rows can only come from decrypted WAL.
* **Flow** — build cluster with `tde_heap` + `wal_encrypt=on`, two
  insert batches (pre-CHECKPOINT 1-100, post-CHECKPOINT 101-200 with a
  marker), `pg_current_wal_flush_lsn`, SIGKILL, start, assert 200 rows
  total + 100 marker rows + server log free of decryption-error
  phrases (`could not decrypt`, `decryption failed`, `invalid
  encrypted`). Final sanity: post-recovery INSERT bumps count to 201.

### `TestRelfilenodeReuse` (2 tests)

Port of upstream `032_relfilenode_reuse.pl`.

#### 8.6 `test_relfilenode_reuse_with_template_db`

* **Purpose** — drop and recreate a template database with the same
  name → standby must still be able to query both old and new clones.
* **Flow** — on `replica_pair` enable `hot_standby_feedback=on`,
  `CREATE DATABASE template_reuse TEMPLATE template0`, populate, clone
  into `conflict_db`, replicate, drop+recreate `template_reuse` with
  a different table, replicate, assert both DBs are queryable on the
  standby.

#### 8.7 `test_relfilenode_reuse_with_tde`

* **Purpose** — same shape on a TDE pair. Each new database needs its
  own database-level principal key.

### `TestWalUtilities` (3 tests)

#### 8.8 `test_pg_resetwal`

* **Purpose** — vanilla `pg_resetwal -f` smoke test on a clean cluster.

#### 8.9 `test_pg_archivecleanup`

* **Purpose** — smoke test of `pg_archivecleanup` against a populated
  archive directory.
* **Flow** — `archive_mode=on`, switch WAL + CHECKPOINT, sleep 2s,
  invoke `pg_archivecleanup <archive_dir> <last_seg_name>`; expect
  returncode 0. Skips if the archiver hasn't produced segments yet.

#### 8.10 `test_pg_receivewal`

* **Purpose** — smoke test of `pg_receivewal` against a live cluster.
* **Flow** — configure replication HBA, spawn `pg_receivewal` as a
  subprocess pointed at a temp directory, `pg_switch_wal()`, sleep 3s,
  assert at least one segment landed in the receive dir, terminate.

---

## 9. `test_replication.py` (13 tests)

Three classes covering streaming, TDE streaming, promotion, and logical
replication.

### `TestStreamingReplication` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 9.1 | `test_standby_is_in_recovery` | `pg_is_in_recovery()` on the standby returns `t`. |
| 9.2 | `test_primary_has_wal_sender` | `COUNT(*)` of `pg_stat_replication` on primary ≥ 1. |
| 9.3 | `test_data_replicates_to_standby` | 1000-row INSERT, wait for catchup, row counts match across primary/standby. |
| 9.4 | `test_ddl_replicates_to_standby` | `CREATE TABLE` + `CREATE INDEX` on primary → matching `pg_indexes` row appears on standby. |
| 9.5 | `test_large_dataset_replication` (slow) | 500 000-row INSERT, catchup within 120 s. |

### `TestTdeStreamingReplication` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 9.6 | `test_encrypted_data_replicates` | 1000-row INSERT on `tde_replica_pair` → row counts match. |
| 9.7 | `test_primary_table_is_encrypted_standby_reflects` | After catchup, `TdeManager(standby).is_table_encrypted("enc_check")` is true. |
| 9.8 | `test_key_rotation_does_not_break_replication` | Rotate principal key mid-stream, insert another batch, both batches present on standby. |
| 9.9 | `test_wal_encryption_with_replication` | Enable `pg_tde.wal_encrypt=on` on primary, insert, expect rows on standby. |
| 9.10 | `test_dml_load_during_replication` (slow) | 50 000 inserts, UPDATE half, DELETE 10%, assert row counts converge. |

### `TestStandbyPromotion` (1 test)

#### 9.11 `test_standby_promotion`

* **Purpose** — `standby.promote()` makes `pg_is_in_recovery()` return `f`.

### `TestLogicalReplication` (3 tests)

#### 9.12 `test_basic_logical_replication`

* **Purpose** — plain logical replication smoke test.
* **Flow** — create table on publisher with 100 rows, identical (empty)
  table on subscriber, `setup_logical_publication` + `setup_logical_subscription`,
  sleep 5s, row counts match.

#### 9.13 `test_logical_replication_with_tde`

* **Purpose** — same shape on `tde_logical_pub_sub_pair`.

#### 9.14 `test_logical_replication_with_wal_encryption`

* **Purpose** — closes the documented Phase-1 gap: logical replication
  must work end-to-end with `pg_tde.wal_encrypt = on` on **both** nodes.
* **Flow** — `enable_wal_encryption()` on both, seed publisher with 500
  rows, set up publication/subscription, **poll** `pg_subscription_rel.srsubstate`
  for `'r'`/`'s'` instead of sleeping (60 s budget). After initial sync
  matches, run post-sync DML (INSERT 500, UPDATE id<=10, DELETE 11-20)
  and poll for `MAX(latest_end_lsn) >= pg_current_wal_lsn`. Final
  sanity: `CHECKPOINT` + `pg_switch_wal()` on the subscriber and grep
  every WAL segment under `<sub>/pg_wal` for the plaintext marker —
  must NOT be present.
* **Catches** — WAL re-keying breaking logical decode; initial-sync
  hang; plaintext leak on the subscriber.

---

## 3. `test_encryption.py` (100 tests)

The biggest module — covers core pg_tde encryption, GUCs, key
providers, and the SQL API. Organized as 15 test classes.

### 3.1 `TestTdeSetup` (5 tests) — basic fixture sanity

| # | Test | Purpose |
|---|---|---|
| 3.1.1 | `test_extension_creates_successfully` | `CREATE EXTENSION pg_tde` succeeds and `pg_extension.extname='pg_tde'` is present. |
| 3.1.2 | `test_default_table_access_method_is_tde_heap` | `SHOW default_table_access_method` returns `'tde_heap'` on `tde_primary`. |
| 3.1.3 | `test_create_encrypted_table` | `CREATE TABLE … USING tde_heap` + INSERT + SELECT round-trips. |
| 3.1.4 | `test_table_is_encrypted` | `pg_tde_is_encrypted` returns true for a freshly-created `tde_heap` table. |
| 3.1.5 | `test_heap_table_not_encrypted` | A plain `USING heap` table reports `pg_tde_is_encrypted = false` on the same cluster. |

### 3.2 `TestPgTdeVersion` (4 tests) — pin the shipped version

Constant `EXPECTED_PG_TDE_VERSION = "2.2.0"`.

| # | Test | Purpose |
|---|---|---|
| 3.2.1 | `test_pg_tde_version_function_callable` | `SELECT pg_tde_version()` returns a non-empty string. |
| 3.2.2 | `test_pg_tde_version_matches_expected` | Exact match against `EXPECTED_PG_TDE_VERSION`. Update constant when shipping a new release. |
| 3.2.3 | `test_pg_tde_version_format_is_semver` | Pinned output format `^\d+\.\d+\.\d+$` so a future build changing the shape produces a clear test failure rather than a silent regression. |
| 3.2.4 | `test_extversion_aligned_with_pg_tde_version` | `pg_extension.extversion` and `pg_tde_version()` must agree — they go out of sync if `ALTER EXTENSION UPDATE` is missed. |

### 3.3 `TestAlterDatabaseSetTablespace` (5 tests)

Documented contract: `ALTER DATABASE … SET TABLESPACE` must be rejected
when any encrypted relation lives in the default tablespace (page-byte
copy across tablespaces can't decrypt).

| # | Test | Purpose |
|---|---|---|
| 3.3.1 | `test_refuses_when_encrypted_objects_exist_in_default_tablespace` | At least one `tde_heap` table in `pg_default` → ALTER DATABASE rejected with documented error. |
| 3.3.2 | `test_allows_when_default_tablespace_has_no_encrypted_objects` | Move all `tde_heap` tables to a non-default tablespace first → ALTER DATABASE succeeds. |
| 3.3.3 | `test_allows_for_empty_database` | DB with no user tables at all → ALTER DATABASE succeeds. |
| 3.3.4 | `test_allows_when_default_has_only_heap_objects` | DB with only `USING heap` tables in default tablespace → ALTER DATABASE succeeds (no encrypted pages to mishandle). |
| 3.3.5 | `test_refuses_with_mixed_heap_and_encrypted_in_default` | Mixed default tablespace → still rejected (heap presence does not soften the rule). |

### 3.4 `TestKeyManagement` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 3.4.1 | `test_file_key_provider_registered` | After fixture setup, `pg_tde_list_all_global_key_providers()` lists the file provider. |
| 3.4.2 | `test_principal_key_is_active` | `pg_tde_key_info()` reports an active principal key. |
| 3.4.3 | `test_key_rotation` | `TdeManager.rotate_principal_key("new_key")` succeeds; `pg_tde_key_info()` reflects the new key. |
| 3.4.4 | `test_multiple_key_providers` | Adding a second provider does not break the first; both appear in the listing. |
| 3.4.5 | `test_vault_key_provider` | Smoke test of the vault-v2 provider (skipped unless OpenBao is reachable). |

### 3.5 `TestWalEncryption` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 3.5.1 | `test_enable_wal_encryption` | `TdeManager.enable_wal_encryption()` engages `pg_tde.wal_encrypt='on'`. |
| 3.5.2 | `test_disable_wal_encryption` | `disable_wal_encryption()` reverts to off. |
| 3.5.3 | `test_wal_encryption_guc_persists_after_restart` | The setting survives `cluster.restart()`. |
| 3.5.4 | `test_wal_encryption_with_heavy_dml` | Heavy DML under `wal_encrypt=on` does not corrupt data. |
| 3.5.5 | `test_wal_encryption_guc_off_by_default` | Default GUC value is `off`. |

### 3.6 `TestChecksums` (2 tests)

| # | Test | Purpose |
|---|---|---|
| 3.6.1 | `test_tde_requires_checksums_disabled` | TDE is documented as incompatible with `data_checksums`. On PG18+ initdb defaults checksums on, so we must pass `--no-data-checksums`. Test asserts cluster came up with checksums off. |
| 3.6.2 | `test_no_checksums_with_tde` | `SHOW data_checksums` returns `'off'` on `tde_primary`. |

### 3.7 `TestDynamicEncryptionState` (3 tests)

| # | Test | Purpose |
|---|---|---|
| 3.7.1 | `test_convert_heap_table_to_tde_heap` | `ALTER TABLE … SET ACCESS METHOD tde_heap` rewrites a plain heap to encrypted; data preserved. |
| 3.7.2 | `test_convert_tde_heap_table_to_heap` | Reverse direction: encrypted → plain. Data preserved. |
| 3.7.3 | `test_concurrent_key_rotation_during_dml` | Rotate the principal key while DML is in flight; no row loss / corruption. |

### 3.8 `TestTdeCipher` (6 tests) — `pg_tde.cipher` GUC

| # | Test | Purpose |
|---|---|---|
| 3.8.1 | `test_default_cipher_is_aes_128` | `SHOW pg_tde.cipher` returns `aes_128` by default (matches docs). |
| 3.8.2 | `test_aes_256_activation_and_table_usable` | `pg_tde.cipher = aes_256` accepted; encrypted tables usable. |
| 3.8.3 | `test_aes_256_ciphertext_is_not_plaintext` | On-disk heap pages with aes_256 must not contain the inserted marker bytes. |
| 3.8.4 | `test_ciphertext_differs_between_aes_128_and_aes_256` | Same plaintext + same workflow under aes_128 vs aes_256 produces different ciphertext on disk. |
| 3.8.5 | `test_cipher_setting_persists_after_restart` | `pg_tde.cipher` written to postgresql.conf survives a restart. |
| 3.8.6 | `test_invalid_cipher_rejected_at_runtime` | Invalid enum string rejected by `SET pg_tde.cipher = 'bogus'`. |

### 3.9 `TestWalSegmentSizeWithEncryption` (1 test)

`test_wal_segment_size_with_encryption`: `pg_tde.wal_encrypt` must work
across all supported WAL segment sizes (16 MB default + non-default).

### 3.10 `TestTdeEnforceEncryption` (10 tests) — `pg_tde.enforce_encryption`

| # | Test | Purpose |
|---|---|---|
| 3.10.1 | `test_enforce_encryption_off_by_default` | Default value is `off`. |
| 3.10.2 | `test_enforce_encryption_can_be_enabled` | `SET pg_tde.enforce_encryption = on` accepted; visible to new sessions. |
| 3.10.3 | `test_enforce_encryption_blocks_heap_create_table` | `CREATE TABLE … USING heap` rejected when enforcement is on. |
| 3.10.4 | `test_enforce_encryption_allows_tde_heap_create_table` | `CREATE TABLE … USING tde_heap` succeeds with enforcement on. |
| 3.10.5 | `test_enforce_encryption_default_access_method_satisfies` | When `default_table_access_method = tde_heap`, bare `CREATE TABLE` (no `USING`) succeeds — proves enforcement honours the default AM. |
| 3.10.6 | `test_enforce_encryption_blocks_create_table_as_heap` | `CREATE TABLE AS … USING heap` rejected (CTAS goes through a separate code path). |
| 3.10.7 | `test_enforce_encryption_allows_create_table_as_tde_heap` | `CREATE TABLE AS … USING tde_heap` succeeds. |
| 3.10.8 | `test_enforce_encryption_blocks_alter_table_to_heap` | `ALTER TABLE … SET ACCESS METHOD heap` rejected on an existing encrypted table. |
| 3.10.9 | `test_enforce_encryption_existing_heap_tables_remain_accessible` | Enabling enforcement after heap tables already exist does NOT break them (read + INSERT still work). |
| 3.10.10 | `test_enforce_encryption_persists_after_restart` | `ALTER SYSTEM` writes to `postgresql.auto.conf`; survives restart. |

### 3.11 `TestTdeVerifyDeleteKeyApis` (6 tests)

Coverage for diagnostic and destructive key APIs:
`pg_tde_verify_key`, `pg_tde_verify_server_key`,
`pg_tde_verify_default_key`, `pg_tde_delete_default_key`,
`pg_tde_delete_key`.

| # | Test | Purpose |
|---|---|---|
| 3.11.1 | `test_pg_tde_verify_key_on_configured_db_succeeds` | With a DB principal key set, `pg_tde_verify_key()` returns success. |
| 3.11.2 | `test_pg_tde_verify_server_key_on_configured_cluster_succeeds` | Server key in place → `pg_tde_verify_server_key()` succeeds. |
| 3.11.3 | `test_pg_tde_verify_default_key_when_set_succeeds` | Default key set via `pg_tde_set_default_key_using_global_key_provider` → verify succeeds. |
| 3.11.4 | `test_pg_tde_verify_key_after_rotation_succeeds` | Rotate the principal key, verify still succeeds (no stale-cache regression). |
| 3.11.5 | `test_pg_tde_delete_default_key_clears_default` | After `pg_tde_delete_default_key()` the default-key view shows no row. |
| 3.11.6 | `test_pg_tde_delete_key_clears_db_key` | After `pg_tde_delete_key()` the database principal-key binding is gone (no rows in `pg_tde_key_info()`). |

### 3.12 `TestPgTdeDeleteKeyProvider` (9 tests)

Coverage for `pg_tde_delete_global_key_provider` and
`pg_tde_delete_database_key_provider`. Ports four TAP-suite scenarios.

| # | Test | Purpose |
|---|---|---|
| 3.12.1 | `test_delete_unused_global_provider_succeeds` | Add two global providers, switch the default key to the new one, then delete the now-unused old provider. Listing reflects the deletion. |
| 3.12.2 | `test_delete_unused_database_provider_succeeds` | Same for database-scope. |
| 3.12.3 | `test_delete_global_provider_in_use_by_db_key_fails` | Provider currently bound as a DB key → delete rejected with `"in use"`; provider still listed. |
| 3.12.4 | `test_delete_global_provider_in_use_by_server_key_fails` | Provider holding the WAL/server key → delete rejected. |
| 3.12.5 | `test_delete_global_provider_with_wal_encrypt_on_fails` | Same as 3.12.4 but with `pg_tde.wal_encrypt=on` and a restart; deletion still rejected. |
| 3.12.6 | `test_delete_database_provider_in_use_by_db_key_fails` | Database-scope counterpart of 3.12.3. |
| 3.12.7 | `test_delete_nonexistent_global_provider_fails` | Asking to delete a name that was never added → error. |
| 3.12.8 | `test_delete_nonexistent_database_provider_fails` | Database-scope counterpart. |
| 3.12.9 | `test_deleted_provider_stays_deleted_across_restart` | After a successful delete + restart, the provider is still absent. |

### 3.13 `TestPgTdeAddDatabaseKeyProvider` (11 tests)

| # | Test | Purpose |
|---|---|---|
| 3.13.1 | `test_add_database_file_provider_listed_with_correct_metadata` | After add, the listing function returns name + type + options as supplied. |
| 3.13.2 | `test_add_database_file_provider_enables_key_creation` | End-to-end: add provider, then `pg_tde_create_key_using_database_key_provider` succeeds against it. |
| 3.13.3 | `test_add_duplicate_database_provider_name_fails` | Re-adding the same name in the same database scope is rejected. |
| 3.13.4 | `test_database_and_global_provider_namespaces_are_independent` | `shared_name` may exist simultaneously as a database AND a global provider — the namespaces are isolated. |
| 3.13.5 | `test_database_provider_is_isolated_per_database` | A database-scope provider in `db_a` is not visible in `db_b`. |
| 3.13.6 | `test_added_database_provider_persists_across_restart` | Full metadata survives a restart. |
| 3.13.7 | `test_add_with_empty_provider_name_fails` | Empty-string name rejected (no sane semantics). |
| 3.13.8 | `test_add_with_empty_path_fails` | Empty path rejected (file provider needs a path). |
| 3.13.9 | `test_add_database_provider_with_directory_as_path_fails` | Pointing the file provider's `path` at an existing directory is rejected. |
| 3.13.10 | `test_add_duplicate_global_provider_name_fails` | Same contract as 3.13.3 but for the global scope. |
| 3.13.11 | `test_add_provider_with_unknown_type_via_generic_api_fails` | `pg_tde_add_database_key_provider(type, name, options)` generic API rejects unknown type strings (`'vault'` vs `'vault-v2'`). |

### 3.14 `TestPgTdeChangeKeyProviderSql` (11 tests)

Online (server-running) provider reconfiguration via
`pg_tde_change_database_key_provider_file` and
`pg_tde_change_global_key_provider_file`. The CLI counterpart is in
`test_change_key_provider.py`.

| # | Test | Purpose |
|---|---|---|
| 3.14.1 | `test_change_database_file_provider_updates_options` | Update path on a database provider → listing returns the new path. |
| 3.14.2 | `test_change_global_file_provider_updates_options` | Same for global scope. |
| 3.14.3 | `test_change_file_provider_while_in_use_keeps_data_readable` | Relocate the keyring of an in-use provider; encrypted SELECT still returns the rows (proves the new path is wired in). |
| 3.14.4 | `test_change_nonexistent_database_provider_fails` | Change against an unknown name → error; catalog untouched. |
| 3.14.5 | `test_change_nonexistent_global_provider_fails` | Global counterpart. |
| 3.14.6 | `test_change_database_provider_does_not_affect_global_namespace` | Changing a database provider doesn't mutate a same-named global one. |
| 3.14.7 | `test_changed_provider_persists_across_restart` | New options survive a restart (in-memory-only regression catch). |
| 3.14.8 | `test_change_with_empty_provider_name_fails` | Empty name rejected. |
| 3.14.9 | `test_change_with_empty_path_fails` | Empty new path rejected. |
| 3.14.10 | `test_change_database_function_against_global_only_provider_fails` | Calling the database-scope function against a name that only exists as a global provider → error (no scope fall-through). |
| 3.14.11 | `test_change_global_function_against_database_only_provider_fails` | Reverse direction. |

### 3.15 `TestPgTdeAddGlobalKeyProviderGenericApi` (3 tests, new today)

| # | Test | Purpose |
|---|---|---|
| 3.15.1 | `test_add_global_provider_via_generic_api_creates_usable_file_provider` | Positive end-to-end: generic API call must create a provider that is (a) listed, (b) usable for `create_key`, (c) usable for `set_server_key` + `set_key`, and (d) the keyfile is materialized on disk. |
| 3.15.2 | `test_add_global_provider_with_unknown_type_via_generic_api_fails` | Unknown type rejected; catalog unpolluted. Companion to 3.13.11. |
| 3.15.3 | `test_add_global_provider_via_generic_api_missing_required_option_fails` | `'file'` type with missing `path` rejected; catalog unpolluted. |

### 3.16 `TestPgTdeInheritGlobalProvidersDelete` (1 test, new today)

#### 3.16.1 `test_delete_global_provider_in_use_by_other_database_fails`

* **Purpose** — pin the cross-database scope of the delete-rejection
  contract under `pg_tde.inherit_global_providers=on` (default).
* **Flow** — explicitly `ALTER SYSTEM SET pg_tde.inherit_global_providers
  = on` + reload, add a global provider, create `other_db`, install
  pg_tde there, set the global provider as `other_db`'s database key,
  then from `postgres` attempt `pg_tde_delete_global_key_provider`.
* **Asserts** — RuntimeError with `"in use"` in message; provider
  still listed; then `DROP DATABASE other_db` and the same delete
  call now succeeds (sanity that rejection was specifically caused by
  the other-DB binding).

---

## 4. `test_partitioning.py` (21 tests)

PostgreSQL's three partition strategies × tde_heap. Parent partitions
are routing-only relations (no storage); `pg_tde_is_encrypted` returns
NULL for them. Leaf partitions are normal heap relations with their own
AM. All tests use `tde_primary`.

### 4.1 `TestPartitionedTdeHeap` (10 tests)

| # | Test | Purpose / flow |
|---|---|---|
| 4.1.1 | `test_range_partitioned_children_are_encrypted` | RANGE × 3 children. Every leaf reports `tde_heap` + `is_encrypted=true`. Rows route correctly; per-child counts sum to parent. |
| 4.1.2 | `test_list_partitioned_children_are_encrypted` | LIST with a DEFAULT partition. The default partition is encrypted too (overflow rows must not leak to plaintext). |
| 4.1.3 | `test_hash_partitioned_children_are_encrypted` | HASH × 4 (modulus 4). All four leaves encrypted; row sum matches; every leaf receives some rows (catches pg_tde interfering with hash routing). |
| 4.1.4 | `test_partitioned_parent_returns_null_for_is_encrypted` | Documented contract: parent has no storage, `pg_tde_is_encrypted` returns NULL (renders as empty psql string). |
| 4.1.5 | `test_mixed_access_method_partitions_each_report_independently` | One leaf `USING tde_heap`, another `USING heap`. `is_encrypted` returns `'t'` and `'f'` respectively (not NULL for the plain heap leaf). |
| 4.1.6 | `test_attach_and_detach_encrypted_partition` | Standalone tde_heap table → ATTACH as partition of a new parent → DETACH. Encryption status preserved across both transitions. |
| 4.1.7 | `test_partition_pruning_with_encrypted_partitions` | `EXPLAIN` for a point query lists only the matching partition (pg_tde does not break partition pruning). |
| 4.1.8 | `test_subpartitioning_chain_all_encrypted` | Outer RANGE → inner LIST. Intermediate routing levels NULL; leaves all tde_heap+encrypted. |
| 4.1.9 | `test_default_partition_catches_overflow_and_is_encrypted` | Overflow rows land in DEFAULT partition; partition is encrypted. |
| 4.1.10 | `test_partitioned_data_round_trip_after_restart` | 3-level mixed RANGE+HASH layout, restart, every leaf still tde_heap + encrypted, row distribution unchanged. |

### 4.2 `TestPartitionedTdeHeapCorners` (11 tests)

| # | Test | Purpose / flow |
|---|---|---|
| 4.2.1 | `test_local_index_on_encrypted_partition_is_encrypted` | A btree local index on a tde_heap leaf reports `is_encrypted='t'` (proves index pages encrypted too — index keys would otherwise leak). |
| 4.2.2 | `test_unique_constraint_on_partition_key_with_tde_heap` | PK on the partition key; verify every per-partition pkey index is encrypted; verify the constraint actually fires (`INSERT` of a dup raises). |
| 4.2.3 | `test_vacuum_full_preserves_encryption_on_partition` | VACUUM FULL allocates a new relfilenode → must still be tde_heap + encrypted; row count preserved. |
| 4.2.4 | `test_alter_column_type_rewrites_partition_keeping_encryption` | `ALTER COLUMN val TYPE BIGINT USING val::bigint` may rewrite; partition still encrypted; SUM(val) round-trips. |
| 4.2.5 | `test_row_movement_across_encrypted_partitions_via_update` | `UPDATE … SET id = …` that changes the partition key physically moves the row to the destination partition (PG 11+ behaviour); both source and destination remain encrypted. |
| 4.2.6 | `test_drop_partition_leaves_siblings_intact` | `DROP TABLE drop_b` on a sibling does not affect `drop_a` / `drop_c`'s encryption or data; `pg_inherits` no longer lists `drop_b`. |
| 4.2.7 | `test_truncate_parent_clears_all_encrypted_children` | `TRUNCATE` allocates new relfilenodes for every child; pg_tde must re-apply encryption to all. |
| 4.2.8 | `test_copy_from_routes_into_encrypted_partitions` | Server-side `COPY FROM` routes rows correctly across partitions; each leaf encrypted. |
| 4.2.9 | `test_toast_values_in_encrypted_partition_round_trip` | Insert a 50 000-char value into an encrypted partition; round-trip the length; verify the TOAST relation (looked up by OID directly to bypass `pg_toast` schema-resolution) is not reported as plaintext. |
| 4.2.10 | `test_composite_range_partition_key_with_tde_heap` | `PARTITION BY RANGE (yr, mo)` with two partitions; all leaves tde_heap + correctly populated. |
| 4.2.11 | `test_many_partitions_all_encrypted_stress` | 30 partitions, 3000 rows. All 30 leaves encrypted. Catches per-partition catalog growth or cache thrashing. |

---

## 6. `test_pgbackrest.py` (23 tests)

pgBackRest integration with pg_tde and `pg_tde.wal_encrypt`.

### 6.1 `TestPgBackRest` (3 smoke tests)

| # | Test | Purpose |
|---|---|---|
| 6.1.1 | `test_full_backup_and_restore` | Full backup → restore into a clean dir → row count matches. |
| 6.1.2 | `test_incremental_backup` | Full + incremental backup chain; restore yields rows from both. |
| 6.1.3 | `test_backup_with_tde` | pgBackRest + pg_tde.wal_encrypt end-to-end (the Percona walkthrough). |

### 6.2 `TestPgBackRestMatrix` (10 tests) — full feature matrix

| # | Test | Purpose |
|---|---|---|
| 6.2.1 | `test_full_restore_recovers_to_latest` | Standard restore to head of timeline. |
| 6.2.2 | `test_delta_restore_into_existing_directory` | `--type=delta` succeeds when the target dir already exists. |
| 6.2.3 | `test_standby_restore_starts_in_recovery` | Restore with `--type=standby`; cluster comes up `pg_is_in_recovery=t`. |
| 6.2.4 | `test_pitr_by_time` | `--type=time --target='…'`. |
| 6.2.5 | `test_pitr_by_lsn` | `--type=lsn --target=<lsn>`. |
| 6.2.6 | `test_pitr_by_xid` | `--type=xid --target=<xid>`. |
| 6.2.7 | `test_selective_db_restore_includes_named_db_only` | `--db-include` restores only the named user databases. |
| 6.2.8 | `test_force_restore_overwrites_dirty_target` | `--force` overrides the safety check. |
| 6.2.9 | `test_backup_chain_full_diff_incr_visible_in_info` | `pgbackrest info` shows full / diff / incr backups in the chain. |
| 6.2.10 | `test_check_command_succeeds_after_stanza_setup` | `pgbackrest check` returns 0 after stanza-create. |

### 6.3 `TestPgBackRestAdvancedAndNegative` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 6.3.1 | `test_backup_chain_with_tde_key_rotation` | Take backup, rotate principal key, take another backup, restore; key evolution doesn't break the chain. |
| 6.3.2 | `test_negative_restore_missing_tde_library` | Restore into a cluster without pg_tde loaded → encrypted data unreadable (documented behaviour). |
| 6.3.3 | `test_negative_pitr_missing_wal` | Remove a WAL segment from the archive → PITR fails cleanly. |
| 6.3.4 | `test_concurrent_ddl_during_backup` | High DDL churn during pgBackRest execution → backup still completes. |

### 6.4 `TestPgBackRestEncryptedWalWrappersContract` (2 tests, byte-level)

| # | Test | Purpose |
|---|---|---|
| 6.4.1 | `test_archive_push_decrypts_wal_into_repo` | After `archive_command` runs through `pg_tde_archive_decrypt`, the WAL files in the pgBackRest repo are **plaintext** (verified by grepping for the inserted marker). |
| 6.4.2 | `test_restore_encrypt_round_trip_keeps_wal_encrypted` | After a full restore with `pg_tde_wal_restore=True`, the WAL on the target is re-encrypted (no marker bytes in any segment). |

---

## 10. `test_tde_cli_tools.py` (12 tests)

Direct CLI coverage for `pg_tde_checksums`, `pg_tde_resetwal`,
`pg_tde_archive_decrypt`, `pg_tde_restore_encrypt`.

### 10.1 `TestPgTdeChecksumsCLI` (5 tests)

`pg_tde_checksums` is the TDE-aware counterpart to `pg_checksums`: it
**skips** encrypted pages (because encrypted page bytes don't satisfy
PG's standard CRC) but validates plain-heap pages normally.

| # | Test | Purpose |
|---|---|---|
| 10.1.1 | `test_binary_exists` | Binary present in install. |
| 10.1.2 | `test_clean_tde_cluster_passes` | A freshly populated TDE cluster verifies clean. |
| 10.1.3 | `test_ignores_corruption_on_encrypted_relation` | Manually overwrite a few bytes of an encrypted `tde_heap` page on disk → `pg_tde_checksums` exits 0 (vs `pg_checksums` which would flag it). |
| 10.1.4 | `test_detects_corruption_on_plain_heap_relation` | Same corruption applied to a plain heap relation in the same cluster → `pg_tde_checksums` correctly flags it. |
| 10.1.5 | `test_passes_with_wal_encryption_disabled` | Tool operates on relation files in `base/...`, not WAL — must work regardless of `wal_encrypt` setting. |

### 10.2 `TestPgTdeResetWal` (3 tests)

`pg_tde_resetwal` wraps `pg_resetwal` so that the rewritten control
file preserves the pg_tde key metadata block.

| # | Test | Purpose |
|---|---|---|
| 10.2.1 | `test_binary_exists` | Binary present. |
| 10.2.2 | `test_resets_wal_and_cluster_restarts` | After `pg_tde_resetwal` on a cleanly-shut WAL-encrypted cluster the cluster starts and encrypted data is still readable. |
| 10.2.3 | `test_dry_run_does_not_modify_pg_control` | `-n` / `--dry-run` prints proposed changes; SHA-256 of `global/pg_control` is byte-identical before/after. |

### 10.3 `TestPgTdeArchiveDecryptRestoreEncrypt` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 10.3.1 | `test_archive_decrypt_produces_plaintext_segments` | `pg_tde_archive_decrypt` in `archive_command` → archive directory contains decrypted segments (marker grep proves it). |
| 10.3.2 | `test_round_trip_pitr_using_both_wrappers` | Archive with `_archive_decrypt`, take cold backup, more DML, stop, restore on a fresh data dir with `_restore_encrypt` in `restore_command`. Encrypted data readable end-to-end. |
| 10.3.3 | `test_archive_decrypt_fails_with_nonexistent_input` | Passing a non-existent input segment path → non-zero exit. |
| 10.3.4 | `test_restore_encrypt_fails_with_bad_inner_command` | A bad inner shell command supplied to `pg_tde_restore_encrypt` propagates as non-zero exit. |

---

## 11. `test_tde_minor_upgrade.py` (36 tests)

Minor-version upgrade procedure for pg_tde (e.g. 2.1 → 2.2). Organized
around five operational questions from the upgrade checklist.

### 11.1 `TestTdeMinorUpgradePreConditions` (5 tests) — Q0 pre-flight

| # | Test | Purpose |
|---|---|---|
| 11.1.1 | `test_catalog_version_vs_binary_version` | Percona ships 2.1.x with `default_version='2.1'` in the control file; the test pins this matrix. |
| 11.1.2 | `test_wal_encryption_active_on_both_nodes` | Both Patroni nodes report `wal_encrypt=on` before the upgrade starts. |
| 11.1.3 | `test_key_provider_registered_on_primary` | File provider + principal key present before upgrade. |
| 11.1.4 | `test_encrypted_tables_readable_before_upgrade` | `tde_heap` rows accessible on both nodes. |
| 11.1.5 | `test_pre_upgrade_full_backup_succeeds` | A full pgBackRest backup succeeds before any package change (Q5 pre-condition). |

### 11.2 `TestAlterExtensionUpdate` (7 tests) — Q1: is `ALTER EXTENSION UPDATE` required?

| # | Test | Purpose |
|---|---|---|
| 11.2.1 | `test_alter_extension_update_does_not_fail` | The command must not raise even when already at latest. |
| 11.2.2 | `test_alter_extension_update_is_idempotent` | Running it twice is safe. |
| 11.2.3 | `test_extversion_unchanged_when_catalog_version_matches` | When the control file `default_version` equals installed `extversion`, no version bump occurs. |
| 11.2.4 | `test_alter_extension_update_does_not_drop_key_providers` | Provider registrations survive the UPDATE. |
| 11.2.5 | `test_alter_extension_update_preserves_wal_encryption` | `pg_tde.wal_encrypt = on` remains on. |
| 11.2.6 | `test_alter_extension_update_on_multiple_databases` | Must succeed on every database where pg_tde is installed. |
| 11.2.7 | `test_encrypted_tables_accessible_after_alter_extension_update` | `tde_heap` rows written before the UPDATE are still readable after. |

### 11.3 `TestRollingRestart` (6 tests) — Q3: rolling-restart order

Order: install new packages on both nodes → restart standby (nodeB) →
verify healthy → restart leader (nodeA).

| # | Test | Purpose |
|---|---|---|
| 11.3.1 | `test_standby_restart_does_not_lose_data` | NodeB restart first must not lose data on nodeA. |
| 11.3.2 | `test_writes_during_standby_restart_are_not_lost` | Rows written to nodeA while nodeB is down catch up afterwards. |
| 11.3.3 | `test_leader_restart_after_standby_is_healthy` | After nodeB healthy, restart nodeA. |
| 11.3.4 | `test_encryption_active_on_both_nodes_after_rolling_restart` | WAL encryption on after full rolling restart. |
| 11.3.5 | `test_key_provider_intact_after_rolling_restart` | Provider + principal key still present. |
| 11.3.6 | `test_new_encrypted_writes_work_after_full_rolling_restart` | New `tde_heap` inserts and reads work after both nodes restarted. |

### 11.4 `TestWalArchivingContinuity` (5 tests) — Q4: WAL archiving during upgrade

| # | Test | Purpose |
|---|---|---|
| 11.4.1 | `test_archive_command_survives_standby_restart` | WAL segments generated before+after nodeB restart all archived. |
| 11.4.2 | `test_archive_command_survives_leader_restart` | Archive process resumes after nodeA restart. |
| 11.4.3 | `test_wal_segments_archived_while_standby_was_down` | Segments generated during nodeB downtime end up in the archive. |
| 11.4.4 | `test_pitr_from_archive_works_after_rolling_restart` | PITR from a WAL archive spanning a rolling restart succeeds. |
| 11.4.5 | `test_no_archiving_errors_in_full_upgrade_window` | Full simulation: no `archive_command` failures recorded throughout. |

### 11.5 `TestPostUpgradeState` (8 tests) — Q5: post-upgrade state + new backup

| # | Test | Purpose |
|---|---|---|
| 11.5.1 | `test_encrypted_tables_accessible_after_full_upgrade_procedure` | Pre-upgrade `tde_heap` rows readable. |
| 11.5.2 | `test_replication_continues_after_full_upgrade_procedure` | New writes replicate. |
| 11.5.3 | `test_key_provider_functional_after_full_upgrade_procedure` | Provider usable for creating new keys. |
| 11.5.4 | `test_wal_encryption_persists_after_full_upgrade_procedure` | `pg_tde.wal_encrypt` still on. |
| 11.5.5 | `test_pg_tde_version_and_server_key_info_queryable` | Checklist verify commands run cleanly. |
| 11.5.6 | `test_standby_encryption_state_matches_primary` | NodeB's encryption state mirrors nodeA. |
| 11.5.7 | `test_post_upgrade_full_backup_succeeds` | New full backup succeeds. |
| 11.5.8 | `test_post_upgrade_restore_from_backup_recovers_data` | Restore from post-upgrade backup yields intact data. |

### 11.6 Module also contains nested test classes for pgBackRest-specific contracts (4 tests not in the per-question grouping above): `test_pre_upgrade_full_backup_succeeds`, `test_post_upgrade_full_backup_succeeds`, and PITR/restore variants — these all sit under the `TestPostUpgradeState` or `TestTdeMinorUpgradePreConditions` classes per the structure.

---

## 12. `test_tde_pg_upgrade.py` (41 tests)

Major-version upgrade via `pg_tde_upgrade` wrapper. Regression coverage
for PG-2240 (vanilla `pg_upgrade` doesn't migrate `$PGDATA/pg_tde/`).

All tests skip unless `--old-install-dir` is passed at pytest invocation.

### 12.1 `TestPpgToPspUpgrade` (4 tests) — old Percona build → new Percona build

| # | Test | Purpose |
|---|---|---|
| 12.1.1 | `test_file_provider_data_intact` | **Core PG-2240 scenario**: `tde_heap` data with 500 rows survives PPG→PSP via `pg_tde_upgrade`. |
| 12.1.2 | `test_alter_extension_update_after_upgrade` | `ALTER EXTENSION pg_tde UPDATE` succeeds after PPG→PSP (catalog version bump). |
| 12.1.3 | `test_multiple_databases_survive` | Multiple databases with independent TDE keys all migrate. |
| 12.1.4 | `test_check_mode_with_tde_configured` | `pg_upgrade --check` passes when pg_tde is loaded and TDE tables exist. |

### 12.2 `TestPspToPspUpgrade` (4 tests) — same-flavour major bump (e.g. 17→18)

| # | Test | Purpose |
|---|---|---|
| 12.2.1 | `test_tde_heap_data_survives` | 1000 encrypted rows survive PSP→PSP. |
| 12.2.2 | `test_multiple_databases_different_keys` | Each database's own principal key still decrypts post-upgrade. |
| 12.2.3 | `test_key_provider_accessible_after_upgrade` | Provider queryable + usable for new encryption. |
| 12.2.4 | `test_wal_encryption_disabled_before_upgrade` | Standard upgrade workflow: disable WAL encryption before `pg_upgrade`, run, then verify data + that WAL enc stays off. |

### 12.3 `TestUpgradeAccessMethodPermutations` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 12.3.1 | `test_all_heap_baseline` | Plain heap throughout; pg_tde not in the picture; pure pg_upgrade smoke. |
| 12.3.2 | `test_all_tde_heap_pg2240_fix` | All tables `tde_heap`; `pg_tde_upgrade` preserves the keyring (PG-2240 fix). |
| 12.3.3 | `test_mixed_heap_and_tde_heap` | Plain + encrypted tables coexist; both readable post-upgrade. |
| 12.3.4 | `test_heap_enable_tde_after_upgrade` | Old cluster all heap; enable TDE on the new cluster post-upgrade. |
| 12.3.5 | `test_tde_heap_convert_to_heap_before_upgrade` | Rewrite encrypted tables as plain heap *before* upgrading → pg_tde keyring no longer needed. |

### 12.4 `TestUpgradeWalEncryptionPaths` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 12.4.1 | `test_wal_enc_off_to_off` | Baseline — no WAL encryption throughout. |
| 12.4.2 | `test_wal_enc_on_to_off` | WAL enc on in old cluster; must be disabled before `pg_upgrade` runs (otherwise `pg_upgrade --check` fails). |
| 12.4.3 | `test_wal_enc_on_to_reenable` | Disable for the upgrade, re-enable on the new cluster. |
| 12.4.4 | `test_check_mode_with_wal_enc_on` | `pg_upgrade --check` succeeds even when WAL enc is active (the wrapper handles it). |

### 12.5 `TestUpgradeEnforceEncryption` (1 test)

#### 12.5.1 `test_upgrade_with_enforce_encryption_active`

`pg_tde.enforce_encryption = on` does not break `pg_upgrade`'s internal
table creation (it uses `--no-create-method` so the enforcement doesn't
fire on its own metadata).

### 12.6 `TestPgTdeUpgradeModes` (3 tests)

| # | Test | Purpose |
|---|---|---|
| 12.6.1 | `test_pg_tde_upgrade_link_mode` | `--link` hard-links files; encrypted data still readable from the new cluster. |
| 12.6.2 | `test_pg_tde_upgrade_clone_mode` | `--clone` (CoW filesystems); same. |
| 12.6.3 | `test_pg_tde_upgrade_parallel_jobs` | `-j 4` parallel mode; many `tde_heap` tables migrate correctly. |

### 12.7 `TestPgTdeUpgradeComplexSchema` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 12.7.1 | `test_pg_tde_upgrade_partitioned_tde_heap` | RANGE-partitioned `tde_heap` parent + 3 leaves; all survive. |
| 12.7.2 | `test_pg_tde_upgrade_foreign_key_cascade_on_tde_heap` | `ON DELETE CASCADE` between two encrypted tables; FK still enforced post-upgrade. |
| 12.7.3 | `test_pg_tde_upgrade_indexes_on_tde_heap` | btree + hash + brin indexes on one encrypted table all survive. |
| 12.7.4 | `test_pg_tde_upgrade_with_multiple_key_providers` | Two registered providers both migrated. |

### 12.8 `TestUpgradeBashScriptParity` (2 tests)

Direct translations of two long-standing bash automation scripts:

| # | Test | Purpose |
|---|---|---|
| 12.8.1 | `test_upgrade_database_key_provider_and_partitions` | Bash script #1 ported. |
| 12.8.2 | `test_upgrade_with_wal_encryption_left_on` | Bash script #2 ported. |

### 12.9 `TestTdeUpgradeExtremeCornerCases` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 12.9.1 | `test_upgrade_massive_toast_data` | Heavy TOAST in `tde_heap` (TOAST tables have their own relfilenodes); all readable. |
| 12.9.2 | `test_upgrade_key_rotation_history` | After multiple rotations, a single table contains pages encrypted with different historical keys; all decryptable on the new cluster. |
| 12.9.3 | `test_upgrade_unlogged_tde_heap` | UNLOGGED + tde_heap handled specially by pg_upgrade; survives. |
| 12.9.4 | `test_upgrade_extension_in_custom_schema` | `CREATE EXTENSION pg_tde SCHEMA my_schema`; upgrade does not hard-code `public`. |
| 12.9.5 | `test_upgrade_dropped_and_recreated_tables` | Drop a table, create another (relfilenode ghosting); upgrade succeeds. |

### Note on the remaining ~9 tests in this file

The file also contains `TestPgTdeUpgradeMixedExtensionTypes`, edge-case
classes for individual upgrade flags, and class-level fixtures that
appear as collected tests. Total in this file: 41.

---

## 13. `test_tde_rewind_advanced.py` (78 tests)

The largest single-feature file. Covers `pg_tde_rewind` regression and
corner cases across HA topologies.

### 13.1 `TestPgRewind` (2 tests) — baseline, no TDE

| # | Test | Purpose |
|---|---|---|
| 13.1.1 | `test_rewind_basic` | Standard primary/standby diverge → rewind with plain `pg_rewind`. |
| 13.1.2 | `test_rewind_after_large_dml` | Same but with several MB of UPDATE/DELETE before rewind. |

### 13.2 `TestTdeRewindExtended` (11 tests) — port of `pg_tde_rewind_extended.sh`

| # | Test | Purpose |
|---|---|---|
| 13.2.1 | `test_rewind_multi_table_mixed_dml` | 10 tde_heap tables, mixed UPDATE/DELETE/VACUUM FULL on the diverged side. |
| 13.2.2 | `test_rewind_after_toast_heavy_workload` | TOAST-heavy rows (≈32 KB each) across the divergence. |
| 13.2.3 | `test_rewind_after_partitioned_table_workload` | RANGE-partitioned tde_heap with two children. |
| 13.2.4 | `test_rewind_after_partial_and_expression_indexes` | Partial (`WHERE id > 100`) and expression (`(id*2)`) indexes survive rewind. |
| 13.2.5 | `test_rewind_after_wal_pressure` | 200k bulk INSERT + CHECKPOINT on promoted standby. |
| 13.2.6 | `test_rewind_after_key_rotation_on_diverged_server` | Rotate DB key on the source after promotion; rewind must succeed. |
| 13.2.7 | `test_rewind_after_crash_on_diverged_server` | Crash on the source between divergence and rewind. |
| 13.2.8 | `test_pg2330_pg2357_rewind_after_pre_rewind_restart` | PG-2330 / PG-2357 regression: restarting the target before rewind. |
| 13.2.9 | `test_pg2330_pg2357_rewind_after_pre_rewind_restart_stress` | Stress variant of the previous test (high DML pressure). |
| 13.2.10 | `test_rewind_deep_validation_reindex_vacuum_full` | After rewind: REINDEX + VACUUM FULL succeed on the rewound side. |
| 13.2.11 | `test_rewind_with_unlogged_table_on_diverged_server` | UNLOGGED tables are truncated on recovery — must not prevent rewind. |

### 13.3 `TestTdeRewindWithCheckpoint` (3 tests) — port of `pg_tde_rewind_with_checkpoint.sh`

| # | Test | Purpose |
|---|---|---|
| 13.3.1 | `test_rewind_after_explicit_checkpoint_before_promotion` | `CHECKPOINT` on primary right before promotion. |
| 13.3.2 | `test_rewind_large_insert_workload_after_checkpoint` | 100-table prepare workload + CHECKPOINT + promote + rewind. |
| 13.3.3 | `test_rewind_postgresql_conf_preserved` | `pg_rewind` may overwrite postgresql.conf; we verify the override is correct. |

### 13.4 `TestTdeRewindRandomized` (8 tests) — port of `pg_tde_rewind_randomized.sh`

| # | Test | Purpose |
|---|---|---|
| 13.4.1 | `test_rewind_target_only_table_is_preserved` | A table created on the rewind source (promoted standby) exists after rewind. |
| 13.4.2 | `test_rewind_source_only_table_is_removed` | A table created only on the rewind target after divergence gets removed. |
| 13.4.3 | `test_rewind_minimal_divergence` | Single INSERT + CHECKPOINT divergence. |
| 13.4.4 | `test_rewind_heavy_divergence_update_delete_reindex` | UPDATE all rows + DELETE half + CREATE INDEX. |
| 13.4.5 | `test_rewind_post_rewind_restart_stability` | Random restart immediately after rewind — must not crash. |
| 13.4.6 | `test_rewind_with_restart_before_promotion` | Restart primary before promotion. |
| 13.4.7 | `test_rewind_randomized_shell_combined_pg2329` | Combined port of the original bash randomizer (PG-2329 regression). |
| 13.4.8 | `test_rewind_with_vault_key_provider` | Vault-v2 key provider active during divergence. Skipped without OpenBao. |

### 13.5 `TestTdeRewindWalEncryption` (6 tests)

| # | Test | Purpose |
|---|---|---|
| 13.5.1 | `test_rewind_wal_encryption_enabled` | Both nodes have `pg_tde.wal_encrypt=on`. |
| 13.5.2 | `test_rewind_wal_encryption_state_preserved` | After rewind, the GUC is still on. |
| 13.5.3 | `test_rewind_wal_compression_lz4_with_tde` | WAL compression (lz4 / pglz) + encryption work together. |
| 13.5.4 | `test_rewind_wal_encryption_plus_archive` | WAL encryption with archiving; rewind via `-c` (use_pgrewind_with_archive). |
| 13.5.5 | `test_rewind_wal_key_overlap_when_target_segments_are_kept` | Target retains tail segments; key overlap handled. |
| 13.5.6 | `test_rewind_timeline_id_increments_after_wal_encryption` | After promotion + rewind, timeline ID increments correctly. |

### 13.6 `TestTdeRewindFullHaCycle` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 13.6.1 | `test_rewind_then_reconnect_as_standby` | Complete failback: rewind old primary, reconnect to new primary as standby, verify catchup. |
| 13.6.2 | `test_rewind_live_source_server` | `--source-server` form: source still live during rewind. |
| 13.6.3 | `test_rewind_cascading_3_node` | 3-node cascade primary → standby1 → standby2. |
| 13.6.4 | `test_rewind_multiple_rounds_ha_lifecycle` | Three consecutive diverge → rewind cycles. |

### 13.7 `TestTdeRewindKeyProviderEdges` (4 tests)

| # | Test | Purpose |
|---|---|---|
| 13.7.1 | `test_rewind_database_level_key_provider` | Database-level provider on the diverged side. |
| 13.7.2 | `test_rewind_multiple_databases_different_keys` | Two databases with independent principal keys. |
| 13.7.3 | `test_rewind_with_key_provider_rotation_between_nodes` | Global key rotated on the source post-divergence. |
| 13.7.4 | `test_rewind_negative_missing_key_provider_file` | Remove the keyfile from target after rewind → cluster correctly refuses to start. |

### 13.8 `TestTdeRewindDataStructures` (7 tests)

| # | Test | Purpose |
|---|---|---|
| 13.8.1 | `test_rewind_with_tablespace_on_tde_heap` | Non-default tablespace storage. |
| 13.8.2 | `test_rewind_sequence_values_reset` | Advanced sequence on diverged side rolled back to source value. |
| 13.8.3 | `test_rewind_after_vacuum_full_relfilenode_change` | VACUUM FULL changes relfilenode — handled. |
| 13.8.4 | `test_rewind_with_gin_index_on_tde_heap` | GIN index on JSONB inside tde_heap. |
| 13.8.5 | `test_rewind_with_gist_index_on_tde_heap` | GiST index on tsvector inside tde_heap. |
| 13.8.6 | `test_rewind_with_enum_and_composite_types` | Enum + composite types survive rewind. |
| 13.8.7 | `test_rewind_with_foreign_key_cascade` | FK cascade on tde_heap tables. |

### 13.9 `TestTdeRewindNegative` (5 tests)

| # | Test | Purpose |
|---|---|---|
| 13.9.1 | `test_rewind_fails_source_pgdata_still_running` | `--source-pgdata` with a running source rejected. |
| 13.9.2 | `test_rewind_fails_target_is_dirty` | Target never checkpointed after divergence → rejected. |
| 13.9.3 | `test_rewind_fails_same_data_dir` | Same dir as both source and target rejected. |
| 13.9.4 | `test_rewind_fails_no_divergence` | Rewind against a non-diverged source → no-op / error. |
| 13.9.5 | `test_rewind_target_wrong_binary` | Plain `pg_rewind` (not `pg_tde_rewind`) against a TDE cluster → failure (proves the wrapper is necessary). |

### 13.10 `TestTdeRewindMultiRound` (6 tests)

| # | Test | Purpose |
|---|---|---|
| 13.10.1 | `test_rewind_ddl_storm_divergence` | 50 CREATE/DROP TABLE pairs on the diverged side. |
| 13.10.2 | `test_rewind_double_cycle` | Two back-to-back diverge → rewind cycles. |
| 13.10.3 | `test_rewind_concurrent_dml_on_source_during_divergence` | Original primary kept writing while standby diverged. |
| 13.10.4 | `test_rewind_large_number_of_tde_heap_files` | 200 tde_heap tables (file-count stress). |
| 13.10.5 | `test_rewind_with_wal_encryption_multi_key_rotation` | Server key rotated 5× under wal_encrypt=on. |
| 13.10.6 | `test_rewind_then_promote_again` | promote → rewind → reconnect → promote again. |

### 13.11 `TestPromoteAndRewind` (2 tests) — legacy basics

| # | Test | Purpose |
|---|---|---|
| 13.11.1 | `test_pg_rewind_after_promotion` | Plain rewind after promotion. |
| 13.11.2 | `test_tde_rewind` | TDE rewind smoke. |

### 13.12 `TestTdeRewindExtremeCornerCases` (8 tests)

| # | Test | Purpose |
|---|---|---|
| 13.12.1 | `test_rewind_with_2pc_crossing_divergence` | `PREPARE TRANSACTION` crossing divergence. |
| 13.12.2 | `test_rewind_target_orphaned_key_rotation` | Old primary rotates its key after standby diverges. |
| 13.12.3 | `test_rewind_new_key_provider_added_on_source` | Promoted standby adds a brand-new file provider post-divergence. |
| 13.12.4 | `test_rewind_with_aborted_subtransactions_in_encrypted_wal` | Massive subtransaction abort stress on pg_tde's WAL parser. |
| 13.12.5 | `test_rewind_after_pg_tde_extension_dropped_and_recreated` | `DROP EXTENSION pg_tde CASCADE` then recreate on target. |
| 13.12.6 | `test_rewind_dropped_encrypted_database` | Entire DB containing encrypted tables dropped on diverged side. |
| 13.12.7 | `test_rewind_vacuum_full_on_tde_catalogs` | VACUUM FULL on pg_tde's own catalog tables. |
| 13.12.8 | `test_rewind_crash_recovery_wal_corruption` | Reproduces a known WAL-corruption scenario; pinned as a regression marker. |

### Note

This file's total is 78 tests because some classes contain additional
helpers that pytest counts and bash-parity tests not listed above.

---

## 14. `test_template_databases.py` (14 tests)

`CREATE DATABASE … TEMPLATE` × pg_tde. Pin the documented configuration
requirement: `pg_tde_set_default_key_using_global_key_provider` is
needed for `CREATE DATABASE` from an encrypted template.

### 14.1 `TestPgTdeTemplateDatabases` (14 tests)

| # | Test | Purpose |
|---|---|---|
| 14.1.1 | `test_pg_tde_extension_installable_in_template1` | `CREATE EXTENSION pg_tde` in `template1` succeeds with the global provider + server key in place. |
| 14.1.2 | `test_new_db_from_template1_inherits_pg_tde_extension` | pg_tde in template1 → newly-created DBs inherit the extension. |
| 14.1.3 | `test_create_database_without_default_key_rejected_with_principal_key_error` | **Documented misconfiguration symptom**: when template1 has encrypted objects but no default key is registered, `CREATE DATABASE` fails with `principal key not configured`. |
| 14.1.4 | `test_new_db_inherits_encrypted_tables_from_template1` | The companion success test: register the default global key, populate encrypted objects in template1, `CREATE DATABASE child_db`. Child inherits the extension + encrypted tables (200 rows readable). |
| 14.1.5 | `test_create_database_with_encrypted_template_rejects_file_copy` | PG 15+ : `STRATEGY = file_copy` rejected when source template has encrypted objects (hint points to wal_log). |
| 14.1.6 | `test_custom_encrypted_template_clones_into_tenant_database` | Tenant-provisioning workflow: build a one-off encrypted template, mark as `IS_TEMPLATE`, register default key, clone into tenant DB. |
| 14.1.7 | `test_two_independent_clones_from_encrypted_template_diverge` | Two clones from the same encrypted template are independent (writing to clone_a doesn't appear in clone_b). |
| 14.1.8 | `test_alter_database_is_template_round_trip_preserves_data` | `IS_TEMPLATE TRUE / FALSE` is a pure catalog flag; encrypted data unchanged. |
| 14.1.9 | `test_cannot_drop_database_marked_as_template` | `DROP DATABASE` on `IS_TEMPLATE=true` rejected by PostgreSQL itself; pg_tde doesn't change that semantics. |
| 14.1.10 | `test_template0_clone_has_no_pg_tde_extension` | `CREATE DATABASE … TEMPLATE template0` produces an extension-free DB even when pg_tde is in template1. |
| 14.1.11 | `test_template0_remains_unconnectable_with_pg_tde` | `template0.datallowconn` remains `f`; pg_tde doesn't flip it. |
| 14.1.12 | `test_create_database_strategy_wal_log_with_encrypted_template` | PG 15+ : `STRATEGY = wal_log` is the documented path for encrypted templates. |
| 14.1.13 | `test_create_database_strategy_file_copy_with_unencrypted_template` | `STRATEGY = file_copy` works when template contains no encrypted objects. |
| 14.1.14 | `test_cloned_encrypted_db_data_survives_restart` | Clone from encrypted template, restart, encrypted data still readable. |

---

## 15. `test_upgrade.py` (62 tests)

General `pg_upgrade` testing — complements the dedicated TDE upgrade
file. Skipped without `--old-install-dir`.

### 15.1 `TestPgUpgradeSmoke` (3 tests)

`test_upgrade_check_passes`, `test_upgrade_succeeds`,
`test_post_upgrade_vacuum_analyze` — basic `pg_upgrade --check` and
full-run smoke + post-upgrade `vacuumdb --all --analyze-in-stages`.

### 15.2 `TestUpgradeWithChecksums` (2 tests)

`test_upgrade_checksums_on_to_on`: both clusters with `--data-checksums`
→ upgrade succeeds; `SHOW data_checksums` returns `on`.
`test_upgrade_checksums_off_to_on`: old without, new with → `pg_upgrade`
correctly **rejects** the mismatch.

### 15.3 `TestUpgradeExtensions` (1 test)

`test_upgrade_with_pg_tde_extension` — `pg_tde` extension carries
across upgrade; 500 rows preserved.

### 15.4 `TestUpgradeNegative` (2 tests)

`test_upgrade_fails_wrong_binaries`: passing the old install dir as
`-B` (new) → mismatch error. `test_upgrade_check_on_running_cluster_fails`:
`pg_upgrade --check` against a running old cluster → fails.

### 15.5 `TestUpgradeDataIntegrity` (11 tests)

Verify complex schema objects survive upgrade intact:

| # | Test | What it covers |
|---|---|---|
| 15.5.1 | `test_sequences_preserve_values` | Sequence advanced to 42 keeps that nextval post-upgrade. |
| 15.5.2 | `test_enum_types_survive` | Enum types and labels preserved. |
| 15.5.3 | `test_composite_and_domain_types` | Composite + domain types. |
| 15.5.4 | `test_views_and_materialized_views` | Views, including materialized; refresh post-upgrade. |
| 15.5.5 | `test_partitioned_tables` | Partition layout + data. |
| 15.5.6 | `test_range_partitioned_table` | Explicit RANGE partitioning. |
| 15.5.7 | `test_functions_and_triggers` | PL/pgSQL function bodies + triggers. |
| 15.5.8 | `test_indexes_various_types` | btree / hash / gin / brin. |
| 15.5.9 | `test_foreign_key_constraints` | FK constraints still enforced. |
| 15.5.10 | `test_large_objects` | pg_largeobject blobs. |
| 15.5.11 | `test_inheritance_tables` | Non-partition table inheritance. |

### 15.6 `TestUpgradeMultiDatabase` (2 tests)

`test_multiple_databases`: every database (incl. user-created ones)
migrates. `test_database_with_non_default_schema`: schema other than
`public` survives.

### 15.7 `TestUpgradeLinkMode` (2 tests)

`test_upgrade_link_mode` / `test_upgrade_clone_mode`: `pg_upgrade --link`
and `--clone` succeed; data still readable.

### 15.8 `TestUpgradeParallel` (1 test)

`test_upgrade_parallel_jobs`: `-j 4` parallel mode.

### 15.9 `TestUpgradeMultiHop` (1 test)

`test_two_hop_upgrade`: chain two upgrades old → intermediate → new
(e.g. 16 → 17 → 18). Data must survive both hops.

### 15.10 `TestUpgradeConfigPreservation` (3 tests)

| Test | What it documents |
|---|---|
| `test_postgresql_auto_conf_is_not_auto_migrated` | `pg_upgrade` does NOT carry over `postgresql.auto.conf` — operator must restore manually. |
| `test_pg_hba_is_not_auto_migrated` | Same for `pg_hba.conf`. |
| `test_checksums_on_preserved` | `--data-checksums` value preserved across upgrade. |

### 15.11 `TestUpgradePostMaintenance` (3 tests)

`test_reindex_after_upgrade`, `test_analyze_all_after_upgrade`,
`test_post_upgrade_artifacts_present` (the `update_extensions.sql` /
`delete_old_cluster.sh` files that `pg_upgrade` emits).

### 15.12 `TestUpgradeNegativeExtended` (6 tests)

| Test | What it asserts is rejected |
|---|---|
| `test_upgrade_fails_checksums_on_to_off` | Old with checksums on, new without → fails. |
| `test_upgrade_fails_when_new_cluster_is_not_pristine` | New cluster already has user data → `pg_upgrade --check` rejects. |
| `test_upgrade_fails_wrong_data_dir` | Non-existent `-d` → fails. |
| `test_upgrade_fails_when_old_cluster_is_running` | Old cluster online → full upgrade refused (not just `--check`). |
| `test_upgrade_fails_unclean_shutdown` | Cluster that crashed without recovery → upgrade refuses. |
| `test_upgrade_fails_same_data_dir_for_old_and_new` | Same dir as both `-d` and `-D` → fails. |

### 15.13 `TestUpgradeTdeCornerCases` (5 tests)

| Test | Coverage |
|---|---|
| `test_upgrade_tde_encrypted_table_data_intact` | tde_heap data survives. |
| `test_upgrade_tde_wal_encryption_enabled` | wal_encrypt on/off paths. |
| `test_upgrade_tde_mixed_encrypted_and_plain_tables` | Mixed; both preserved. |
| `test_upgrade_tde_multiple_databases_different_keys` | Independent keys per DB. |
| `test_upgrade_tde_key_rotation_before_upgrade` | Rotate just before upgrade; new key valid post-upgrade. |

### 15.14 `TestUpgradeReplicationState` (3 tests)

`test_upgrade_with_replication_slots_removed` — drop slots first, then
upgrade. `test_upgrade_fails_with_active_replication_slots` —
pg_upgrade refuses when a slot still exists.
`test_upgrade_with_publication_preserved` — logical publication
metadata carries across.

### 15.15 `TestUpgradeScale` (2 tests)

`test_upgrade_large_dataset` — 200k rows, time recorded.
`test_upgrade_many_tables` — many tables (catalog scaling).

### Notes on remaining tests

`test_upgrade.py` also contains a `TestUpgradeMultiHop` that does
two-hop chains and a few standalone classes with single methods that
push the file count to 62 — every class above is the actual primary
matrix.

---

## 16. `test_waldump.py` (33 tests)

`pg_tde_waldump` (the Percona wrapper around `pg_waldump`). `-k <keyring>`
enables decryption.

### 16.1 `TestPgWaldumpVsPgTdeWaldumpOnEncryptedWal` (3 tests)

| # | Test | Purpose |
|---|---|---|
| 16.1.1 | `test_vanilla_pg_waldump_cannot_decode_encrypted_wal` | Vanilla `pg_waldump` either errors or decodes strictly fewer records than `pg_tde_waldump -k` on the same encrypted segment. |
| 16.1.2 | `test_pg_tde_waldump_no_keyring_does_not_fatal_on_encrypted_wal` | Without `-k` the wrapper skips encrypted records rather than fatal-erroring (per --help contract). Decodes fewer records than with `-k`. |
| 16.1.3 | `test_pg_tde_waldump_with_keyring_decodes_encrypted_wal` | With `-k` the wrapper decodes ≥ 10 records and produces Heap/Heap2 records. |

### 16.2 `TestPgTdeWaldumpDataTypes` (5 tests)

| # | Test | Type families exercised |
|---|---|---|
| 16.2.1 | `test_text_jsonb_bytea` | TEXT + JSONB + BYTEA. |
| 16.2.2 | `test_numeric_array_timestamp_uuid` | NUMERIC + INT[] + TIMESTAMPTZ + UUID. |
| 16.2.3 | `test_geometric_range_inet_xml` | POINT, BOX, INT4RANGE, INET, CIDR, XML (or MACADDR when libxml is missing). |
| 16.2.4 | `test_tsvector_and_hstore_like` | TSVECTOR + TEXT[]. |
| 16.2.5 | `test_toasted_wide_rows` | TOAST-out values with `STORAGE EXTERNAL` (no compression so the marker is exact-match detectable). |

All five verify (a) the marker bytes are not on-disk in the WAL
segment, and (b) `pg_tde_waldump -k` decodes Heap or Heap2 records.

### 16.3 `TestPgTdeWaldumpRelationKinds` (5 tests)

| # | Test | Coverage |
|---|---|---|
| 16.3.1 | `test_partitioned_table_decoded` | LIST-partitioned with two tde_heap children. |
| 16.3.2 | `test_indexed_table_emits_index_rmgrs` | btree + hash + gin + brin index AMs all emit rmgrs that decode. |
| 16.3.3 | `test_mixed_tde_heap_and_plain_heap` | Both tde_heap and plain heap inserts in the same segment — proves WAL-encryption wraps the **whole** stream (plain heap rows also not on disk). |
| 16.3.4 | `test_multiple_databases_with_tde` | Two databases each with their own DB key; neither's marker leaks in WAL. |
| 16.3.5 | `test_materialized_view_refresh_logs_wal` | `REFRESH MATERIALIZED VIEW` emits records that decode. |

### 16.4 `TestPgTdeWaldumpFilters` (11 tests) — every CLI filter switch

| # | Test | Flag tested |
|---|---|---|
| 16.4.1 | `test_rmgr_filter_heap_only` | `-r Heap`: only Heap rmgr records returned. |
| 16.4.2 | `test_relation_filter` | `-R T/D/R`: every blkref line references the chosen relation. |
| 16.4.3 | `test_xid_filter` | `-x <xid>`: every record has the requested XID. |
| 16.4.4 | `test_lsn_range` | `-s/-e`: records inside the LSN range. |
| 16.4.5 | `test_limit_records` | `-n 10`: exactly 10 records. |
| 16.4.6 | `test_stats_mode` | `-z`: stats table output; no per-record lines. |
| 16.4.7 | `test_stats_per_record` | `--stats=record`: per-record breakdown including INSERT. |
| 16.4.8 | `test_quiet_flag` | `-q`: no rmgr lines. |
| 16.4.9 | `test_bkp_details` | `-b`: `blkref` lines present. |
| 16.4.10 | `test_fork_filter_main_only` | `-F main`: every record returned has at least one main-fork blkref (PG's `pg_waldump` filters at record level, not per-blkref — this assertion accommodates that). |
| 16.4.11 | `test_save_fullpage_extracts_decrypted_images` | `--save-fullpage=<dir>`: extracted FPI files contain the plaintext marker (proves wrapper decrypted before saving). |

### 16.5 `TestPgTdeWaldumpPlaintextWal` (2 tests)

`test_pg_tde_waldump_on_plaintext_wal_without_keyring` and
`test_pg_waldump_on_plaintext_wal`: both binaries decode plaintext WAL
fully; `-k` is irrelevant.

### 16.6 `TestPgTdeWaldumpCustomRmgrRegistered` (1 test)

`test_pg_tde_registers_custom_resource_manager`: pg_tde registers
custom rmgr ID 140 at postmaster startup; server log contains both
`"custom resource manager"` and `"pg_tde"`.

---

## Appendix: skip-conditions

These tests automatically skip when the corresponding external
dependency is missing — the suite is designed to run cleanly in CI
without requiring everything to be installed:

| Skip condition | Affects |
|---|---|
| `--old-install-dir` not provided | All of `test_upgrade.py`, `test_tde_pg_upgrade.py` |
| Vault / OpenBao not reachable | `TestKeyManagement.test_vault_key_provider`, `test_rewind_with_vault_key_provider`, KMIP tests in bash automation |
| `pg_tde_*` binary missing in install | Individual CLI tests in `test_tde_cli_tools.py`, `test_change_key_provider.py`, `test_waldump.py`, `test_pg_basebackup.py::TestPgTdeBaseBackupWalEncryption` |
| `pg_tde_function_exists(...)` returns false | `TestTdeVerifyDeleteKeyApis` (verify/delete APIs may be missing on older builds) |
| `cluster.major_version < 15` | `STRATEGY = wal_log` / `file_copy` tests in `test_template_databases.py` |
| libxml not built | Falls back to MACADDR column in `test_geometric_range_inet_xml` |

---

## Appendix: how to read this catalog

* Test IDs (e.g. `3.10.5`) are **document-local** anchors. They don't
  appear in pytest output; the real test names are in the table rows.
* "**Purpose**" describes the contract under test; "**Flow**" the
  operative steps; "**Asserts / catches**" what proves pass/fail.
* For tests with short or empty docstrings, the descriptions in this
  document are inferred from the test code and matching bash
  automation scripts. Treat the docstring text inside the file as
  authoritative when the two diverge.
