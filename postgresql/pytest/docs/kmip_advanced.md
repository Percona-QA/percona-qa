# KMIP advanced pytest scenarios

`tests/test_kmip_advanced.py` — pytest-only integration tests beyond smoke/bash
parity. Targets PR #595 / libkmip client behaviour under realistic churn.

## Prerequisites

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_cosmian_for_pytest.sh
pytest tests/test_kmip_advanced.py -v
```

One test (`test_read_fails_after_kmip_server_loses_all_keys`) requires local
`cosmian_kms` to restart with an empty KMIP database (`@pytest.mark.cosmian`).

## Scenario matrix

| Class | Test | What it stresses |
|-------|------|------------------|
| **KeyRotationChurn** | `test_four_rotations_all_generations_readable` | 4 principal-key rotations, inserts each gen, restarts |
| | `test_default_key_rotation_file_then_kmip_chain` | Global default key: file → KMIP → second KMIP ring |
| **MultiDatabaseIsolation** | `test_three_databases_distinct_kmip_principal_keys` | 3 DBs, same global ring, distinct principal keys |
| | `test_new_database_inherits_kmip_global_default_key` | `CREATE DATABASE` + inherited KMIP default |
| **MixedProviderTopology** | `test_global_kmip_table_and_database_file_table` | Global KMIP + DB-scoped file on `postgres` |
| | `test_global_kmip_plus_database_scoped_kmip_on_second_db` | Global KMIP on `postgres`, DB KMIP on `isolated` |
| **StorageCornerCases** | `test_partitioned_table_readable_after_kmip_rotation` | Partitioned `tde_heap` + rotation |
| | `test_toast_wide_row_survives_triple_kmip_rotation` | TOAST (~9 KB rows) across 3 rotations |
| **WalAndServerKey** | `test_wal_encryption_triple_restart_with_bulk_dml` | WAL encrypt + 3× restart + 3k rows |
| **FailureAndCornerCases** | `test_cannot_add_duplicate_global_kmip_provider_name` | Catalog duplicate name |
| | `test_delete_database_kmip_provider_in_use_fails` | Delete in-use DB provider |
| | `test_read_fails_after_kmip_server_loses_all_keys` | Cosmian empty restart (cosmian only) |
| | `test_non_tls_tcp_endpoint_rejected_on_add_provider` | TLS handshake failure |
| **DumpRestore** (`slow`) | `test_pg_dump_table_into_second_db_with_new_kmip_key` | `pg_dump` / restore across DBs + different KMIP keys |

## Full KMIP CI run

```bash
./scripts/run_kmip_revalidation.sh
```

Includes: revalidation checklist, `test_kmip.py`, `test_kmip_advanced.py`,
`TestKmipCppClientRegression`.

## Vendor labs

Advanced tests use `KMIP_*` (whatever server is configured). Re-run the same
file against Fortanix/Thales/Akeyless by mapping vendor env to `KMIP_*` before
pytest (see `config/kmip_profiles.example.env`).
