# KMIP test catalog — pytest module inventory

> **Documentation index:** [README.md](README.md)

Detailed inventory of KMIP-related tests in `postgresql/pytest` (and related bash/TAP
automation). Use this when signing off a KMS vendor, validating [PR #595](https://github.com/percona/pg_tde/pull/595) / [PG-2125](https://perconadev.atlassian.net/browse/PG-2125), or onboarding to the lab.

**Related docs:** [quickstart.md](quickstart.md), [../key_provider_matrix.md](../key_provider_matrix.md), [vendor-signoff.md](vendor-signoff.md), [advanced-scenarios.md](advanced-scenarios.md), [vault-kmip-engine.md](vault-kmip-engine.md).

---

## Summary

| Layer | Module / script | Tests | Profile scope | Marker |
|-------|-----------------|------:|---------------|--------|
| Shared matrix | `tests/test_kmip_common_matrix.py` | 9 | All `KMIP_REVALIDATE_PROFILES` | `kmip`, `kmip_matrix` |
| Full checklist | `tests/test_kmip_server_revalidation.py` | 1×N profiles | All profiles | `kmip`, `kmip_revalidation` |
| Extended / advanced | `tests/test_kmip.py` | 24 | Single profile (`kmip_config`) | `kmip`, `encryption` |
| PG-2125 regression | `tests/test_external_key_provider_regressions.py` | 4 | Single profile | `kmip`, `bug` |
| Vault KMIP engine | `tests/test_vault_kmip.py` | 2 | `vault_kmip` only | `kmip`, `vault_kmip`, `bug` |
| OpenBao + KMIP mix | `tests/test_openbao_bash_parity.py` | 5 scenarios | KMIP + OpenBao | `vault`, `openbao`, `kmip` |
| OpenBao multi-DB | `tests/test_vault_providers.py` | 2 | KMIP + OpenBao | `vault`, `openbao` |
| Offline CLI (kmip) | `tests/test_change_key_provider.py` | 1 | No live server | `encryption` |
| Offline CLI (kmip) | `tests/test_kmip.py` | 1 | Live KMIP | `kmip` |
| Bash revalidation | `scripts/scenarios/hashicorp_vault_kmip.sh` | 4 scenarios | Vault Enterprise KMIP | — |
| TAP (legacy) | `postgresql/t/*.pl` | several | External KMIP lab | — |

**Default KMIP server:** `cosmian` (no vendor license). Override with `KMIP_PROFILE=vault_kmip` (or `fortanix`, `thales`, `akeyless`).

---

## Supported KMIP server profiles

Configured via `KMIP_REVALIDATE_PROFILES`, `KMIP_PROFILE`, or `--kmip-profile`:

| Profile | Vendor | Env prefix | Primary test entry |
|---------|--------|------------|-------------------|
| `cosmian` *(default)* | Cosmian KMS | `KMIP_COSMIAN_*` or `KMIP_SERVER_*` after setup | `./scripts/run_kmip_matrix.sh` |
| `vault_kmip` | HashiCorp Vault KMIP engine | `KMIP_VAULT_*` | `./scripts/run_vault_kmip_revalidation.sh` |
| `fortanix` | Fortanix DSM | `KMIP_FORTANIX_*` | `KMIP_PROFILE=fortanix ./scripts/run_kmip_matrix.sh` |
| `thales` | Thales CipherTrust | `KMIP_THALES_*` | same pattern |
| `akeyless` | Akeyless | `KMIP_AKEYLESS_*` | same pattern |

---

## pg_tde SQL / CLI operations exercised

| Operation | Covered in |
|-----------|------------|
| `pg_tde_add_global_key_provider_kmip` | Matrix, checklist, `test_kmip.py`, regressions, `test_vault_kmip.py` |
| `pg_tde_add_database_key_provider_kmip` | Matrix, checklist, `test_kmip.py`, bash scenarios, OpenBao parity |
| `pg_tde_change_global_key_provider_kmip` | `TestKmipChangeKeyProviderSql` (matrix) |
| `pg_tde_change_database_key_provider_kmip` | `TestKmipChangeKeyProviderSql` (matrix) |
| `pg_tde_create_key_using_global_key_provider` | All suites |
| `pg_tde_create_key_using_database_key_provider` | Matrix, `test_kmip.py`, OpenBao, Vault KMIP |
| `pg_tde_set_key_using_global_key_provider` | All global-scope suites |
| `pg_tde_set_key_using_database_key_provider` | Database-scope suites |
| `pg_tde_set_server_key_using_global_key_provider` | WAL / server-key tests |
| `pg_tde_set_default_key_using_global_key_provider` | Default-key rotation tests |
| `pg_tde_delete_global_key_provider` | `test_kmip.py`, OpenBao scenario 12 |
| `pg_tde_delete_database_key_provider` | `test_kmip.py` (negative) |
| `pg_tde_list_all_global_key_providers` | Listing / delete assertions |
| `pg_tde_list_all_database_key_providers` | Change-provider matrix |
| `pg_tde_verify_key` / `pg_tde_verify_server_key` | Change-provider matrix, Vault KMIP bash |
| `pg_tde_change_key_provider` CLI (`kmip` type) | `test_kmip.py`, `test_change_key_provider.py` |

KMIP protocol path (PR #595): **validate** (add provider) → **register** (create_key) → **locate + get** (read encrypted data / restart).

---

## 1. Shared matrix — `tests/test_kmip_common_matrix.py`

**Purpose:** Same core scenarios for every configured KMS profile. Parametrized by `KMIP_REVALIDATE_PROFILES`.

**Run:**
```bash
source scripts/setup_cosmian_for_pytest.sh          # default
./scripts/run_kmip_matrix.sh

# Vault Enterprise KMIP
source /tmp/vault_kmip_pytest.env
KMIP_PROFILE=vault_kmip ./scripts/run_kmip_matrix.sh
```

### `TestKmipCommonMatrix`

| Test | What it validates |
|------|-------------------|
| `test_global_smoke_restart` | Add global KMIP provider → set principal key → `tde_heap` table (120 rows) → restart → row count |
| `test_key_rotation` | Rotate principal key on same provider → restart → encrypted data readable |
| `test_multi_db_file_and_kmip` | `db1` file principal key; `db2` KMIP principal key; both survive restart |

### `TestKmipChangeKeyProviderSql`

Online SQL from [Percona docs — change KMIP providers](https://docs.percona.com/pg-tde/functions.html?h=pg_tde_add_global_key_provider_kmip).

| Test | What it validates |
|------|-------------------|
| `test_change_database_kmip_provider_updates_options` | `pg_tde_change_database_key_provider_kmip` updates catalog `options` (host, port, certs) |
| `test_change_global_kmip_provider_updates_options` | `pg_tde_change_global_key_provider_kmip` updates global catalog entry |
| `test_change_database_kmip_provider_while_in_use_keeps_data_readable` | Change connection while encrypted table exists → `pg_tde_verify_key` → restart → 50 rows |
| `test_change_global_kmip_provider_while_in_use_keeps_data_readable` | Global provider change with active server key → `pg_tde_verify_server_key` after restart |
| `test_change_nonexistent_database_kmip_provider_fails` | Unknown provider name → error |
| `test_change_nonexistent_global_kmip_provider_fails` | Unknown global provider → error |

**Implementation:** `lib/kmip_common_matrix.py`.

---

## 2. Full revalidation checklist — `tests/test_kmip_server_revalidation.py`

**Purpose:** One parametrized test per profile running the full post–PR-595 checklist.

| Test | Checklist steps (`lib/kmip_revalidation.py`) |
|------|---------------------------------------------|
| `test_kmip_revalidation_checklist` | 1. `add_global_key_provider_kmip` (TLS validate) → 2. register principal key → 3. encrypted DML (100 rows) → 4. read after restart → 5. rotate key + second restart → 6. database-scope KMIP provider + DML + restart |

**Run:**
```bash
pytest tests/test_kmip_server_revalidation.py -v
```

---

## 3. Extended suite — `tests/test_kmip.py`

**Purpose:** Cosmian-first extended coverage, bash/TAP parity, advanced corner cases. Uses single `kmip_config` fixture (default Cosmian; override with `KMIP_PROFILE`).

**Run:**
```bash
source scripts/setup_cosmian_for_pytest.sh
pytest tests/test_kmip.py -v
```

### `TestKmipKeyProviderBasics` (smoke)

| Test | Description |
|------|-------------|
| `test_kmip_global_provider_register_locate_get_after_restart` | Global provider + principal key + 200-row table; restart; verify REGISTER/LOCATE/GET path |
| `test_kmip_key_rotation_register_second_key` | Second key name on same provider (another REGISTER) |

### `TestKmipBashParityScenarios`

Ports `pg_tde_functions_test.sh` / TAP KMIP scenarios.

| Test | Bash / TAP source | Description |
|------|-------------------|-------------|
| `test_multiple_databases_file_and_kmip_providers` | functions_test s2, `t/066` | `db1` file key; `db2` KMIP key; restart |
| `test_kmip_global_default_principal_key_two_databases` | functions_test s3 | Global default KMIP key; `test1` local file key; `test2` inherits default |
| `test_kmip_database_scoped_provider` | functions_test s4 | Database-local KMIP provider on `sbtest2` |

### `TestKmipDeleteKeyProvider`

| Test | Description |
|------|-------------|
| `test_delete_unused_kmip_global_provider` | Delete global KMIP provider not in use |
| `test_delete_kmip_global_provider_in_use_fails` | Delete fails when principal key still uses provider |

### `TestKmipChangeKeyProviderCLI`

| Test | Description |
|------|-------------|
| `test_change_kmip_provider_connection_offline` | Offline `pg_tde_change_key_provider … kmip …` updates connection only; data readable after restart |

### `TestKmipLibkmipClientPr595` ([PG-2125](https://perconadev.atlassian.net/browse/PG-2125))

| Test | Description |
|------|-------------|
| `test_kmip_invalid_server_host_rejected_on_add_provider` | Bad host → clear KMIP/connect error (not silent BIO failure) |
| `test_kmip_build_links_cpp_kmipclient` | `ldd pg_tde.so` shows C++ runtime (PR #595 build) |

### `TestKmipKeyRotationChurn`

| Test | Description |
|------|-------------|
| `test_four_rotations_all_generations_readable` | 4 principal-key rotations; interleaved restarts; all row generations readable |
| `test_default_key_rotation_file_then_kmip_chain` | Default key: file → KMIP provider A → KMIP provider B |

### `TestKmipMultiDatabaseIsolation`

| Test | Description |
|------|-------------|
| `test_three_databases_distinct_kmip_principal_keys` | Three DBs, three distinct KMIP principal keys on one global provider |
| `test_new_database_inherits_kmip_global_default_key` | New DB uses global default KMIP key without per-DB setup |

### `TestKmipMixedProviderTopology`

| Test | Description |
|------|-------------|
| `test_global_kmip_table_and_database_file_table` | Global KMIP for server; database file provider for local table |
| `test_global_kmip_plus_database_scoped_kmip_on_second_db` | Global KMIP + per-database KMIP on second DB |

### `TestKmipStorageCornerCases`

| Test | Description |
|------|-------------|
| `test_partitioned_table_readable_after_kmip_rotation` | Partitioned `tde_heap` table survives KMIP key rotation |
| `test_toast_wide_row_survives_triple_kmip_rotation` | Wide TOAST rows (9 KB) survive 3 KMIP rotations + restart |

### `TestKmipWalAndServerKey`

| Test | Description |
|------|-------------|
| `test_wal_encryption_triple_restart_with_bulk_dml` | WAL encryption on; 3000 rows; 3 restart/checkpoint cycles; `is_wal_encrypted()` |

### `TestKmipFailureAndCornerCases`

| Test | Description |
|------|-------------|
| `test_cannot_add_duplicate_global_kmip_provider_name` | Duplicate global provider name → error |
| `test_delete_database_kmip_provider_in_use_fails` | Delete in-use database KMIP provider → error |
| `test_read_fails_after_kmip_server_loses_all_keys` | `@pytest.mark.cosmian` — fresh Cosmian with no keys → read fails (`not found` / key provider) |
| `test_non_tls_tcp_endpoint_rejected_on_add_provider` | Plain TCP (no TLS) → SSL/handshake error on add provider |

### `TestKmipDumpRestore` (`@pytest.mark.slow`)

| Test | Description |
|------|-------------|
| `test_pg_dump_table_into_second_db_with_new_kmip_key` | `pg_dump` encrypted table → restore into second DB with different KMIP principal key |

---

## 4. PG-2125 regression — `tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression`

**Bug:** [PG-2125](https://perconadev.atlassian.net/browse/PG-2125) — legacy C libkmip BIO failures; fixed by C++ kmipclient ([PR #595](https://github.com/percona/pg_tde/pull/595)).

| Test | Description |
|------|-------------|
| `test_kmip_full_lifecycle_multiple_restarts` | 500 rows → rotate → 2 restarts → tail row readable; backend must stay alive |
| `test_kmip_repeated_create_key_is_idempotent` | Re-run `create_key` for same name must not break provider |
| `test_kmip_wal_encryption_with_server_key` | WAL encryption + 2000 rows + restart |
| `test_kmip_requires_cpp_kmipclient_build` | `xfail` if `pg_tde.so` lacks C++ link (pre-595 package) |

**Run:**
```bash
pytest tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression -v
```

---

## 5. Vault KMIP engine (server-specific) — `tests/test_vault_kmip.py`

**Not Vault KV v2.** Enterprise KMIP secrets engine only. Customer **Register symmetric key -2** repro.

| Test | Description |
|------|-------------|
| `test_vault_kmip_add_global_provider_connects` | TLS validate / add global KMIP provider |
| `test_vault_kmip_create_key_register_symmetric_key_customer_repro` | Customer `create_key` SQL; `xfail` on Register -2 unless `VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1` |

**Bash parity:** `scripts/scenarios/hashicorp_vault_kmip.sh` (4 scenarios).

**Run:**
```bash
source /tmp/vault_kmip_pytest.env
./scripts/run_vault_kmip_revalidation.sh
```

---

## 6. OpenBao scenarios using KMIP — `tests/test_openbao_bash_parity.py`

Requires OpenBao **and** KMIP (`kmip_config` + `vault_config`).

| Test | Scenario | KMIP role |
|------|----------|-----------|
| `test_openbao_scenario4_multi_provider_single_database` | s4 | DB-scoped KMIP + Vault + file on `sbtest2` |
| `test_openbao_scenario5_global_file_provider_change` | s5 | Global KMIP provider present |
| `test_openbao_scenario6_local_and_global_vault_providers` | s6 | Global KMIP table `t1`; DB Vault table `t2` |
| `test_openbao_scenario7_default_key_rotation` | s7 | Rotate default key across Vault → KMIP → file |
| `test_openbao_scenario8_dump_restore_provider_migration` | s8 | Dump/restore; add KMIP DB provider on restored DB |

Also: `tests/test_vault_providers.py` — `test_openbao_global_vault_multi_db_with_kmip_and_file`, `test_openbao_local_db_vault_and_global_kmip_default`.

---

## 7. Offline CLI — `pg_tde_change_key_provider`

| Module | Test | Description |
|--------|------|-------------|
| `test_kmip.py` | `test_change_kmip_provider_connection_offline` | Positive: offline KMIP connection update |
| `test_change_key_provider.py` | `test_change_kp_fails_with_missing_kmip_required_args` | Negative: missing key_path rejected |

---

## 8. Bash runners (pytest wrappers)

| Script | Includes KMIP tests |
|--------|---------------------|
| `scripts/run_kmip_matrix.sh` | `test_kmip_common_matrix.py`, `test_kmip_server_revalidation.py`; optional `test_kmip.py` with `KMIP_MATRIX_INCLUDE_COSMIAN_EXTENDED=1`; optional `test_vault_kmip.py` when `vault_kmip` profile |
| `scripts/run_kmip_revalidation.sh` | Wrapper for matrix + extended Cosmian |
| `scripts/run_vault_kmip_revalidation.sh` | `test_vault_kmip.py` only |
| `scripts/run_hashicorp_vault_revalidation.sh` | KV + optional KMIP bash scenarios |
| `scripts/run_key_provider_matrix.sh` | KMIP + Vault KV + file keyring when configured |

---

## 9. Legacy TAP / automation (not pytest)

| File | KMIP coverage |
|------|----------------|
| `t/066_multiple_db_diff_key_prov.pl` | Multi-DB different providers |
| `t/069_change_database_key_provider_and_verify_data_integrity.pl` | Change DB provider to KMIP |
| `t/070_change_global_key_provider_and_verify_data_integrity.pl` | Global KMIP provider change |
| `t/071_global_key_rotation_and_verification.pl` | Global default key rotation to KMIP |
| `t/072_data_migration_between_key_providers.pl` | DB-scoped KMIP after migration |
| `automation/tests/pg_tde_functions_test.sh` | KMIP scenarios 2–4 |
| `automation/tests/change_pg_tde_key_provider.sh` | Change provider under load (kmip type) |
| `automation/tests/pg_tde_rewind_extended.sh` | Optional KMIP provider change during rewind |

---

## 10. Pytest markers

| Marker | Meaning |
|--------|---------|
| `kmip` | Any KMIP-tagged test |
| `kmip_matrix` | Shared matrix (`test_kmip_common_matrix.py`) |
| `kmip_revalidation` | Full checklist per profile |
| `vault_kmip` | Vault KMIP engine only (`test_vault_kmip.py`) |
| `cosmian` | Requires local `cosmian_kms` binary (eviction test) |
| `kmip_build` | Build/link check (`ldd`) |
| `slow` | Long-running (dump/restore) |
| `bug` | Explicit regression (PG-2125, Vault Register -2) |

Tests skip when `KMIP_*` env is unset or KMS is unreachable (except CLI negatives).

---

## 11. Quick command reference

```bash
# Default Cosmian — full matrix
source scripts/setup_cosmian_for_pytest.sh
./scripts/run_kmip_matrix.sh

# Matrix only (no extended)
KMIP_MATRIX_SUITE=common ./scripts/run_kmip_matrix.sh

# Checklist only
KMIP_MATRIX_SUITE=checklist ./scripts/run_kmip_matrix.sh

# Extended Cosmian suite
pytest tests/test_kmip.py -v

# PG-2125 regression
pytest tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression -v

# Vault Enterprise KMIP engine
source /tmp/vault_kmip_pytest.env
KMIP_PROFILE=vault_kmip ./scripts/run_kmip_matrix.sh
./scripts/run_vault_kmip_revalidation.sh

# Vendor sign-off (example)
KMIP_PROFILE=fortanix pytest tests/test_kmip_common_matrix.py tests/test_kmip_server_revalidation.py -v
```

---

## 12. Coverage gaps (intentional)

| Area | Status |
|------|--------|
| Cross-provider type migration (file → kmip → vault) in one pytest | Partial — TAP `t/069`; Vault leg needs Vault server |
| Every vendor on `test_kmip.py` extended suite | No — extended suite is single-profile; matrix covers all profiles |
| Vault KMIP Register -2 strict pass | Opt-in via `VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1` |
| Fortanix / Thales / Akeyless in CI | Manual / scheduled jobs with vendor credentials |

---

*Last updated: 2026-05-19 — reflects KMIP change-provider matrix tests and Cosmian default profile.*
