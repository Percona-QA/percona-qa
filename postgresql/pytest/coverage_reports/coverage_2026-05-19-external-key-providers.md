# pg_tde Pytest Coverage Report — External Key Providers (2026-05-19)

**Date:** 2026-05-19  
**Previous report:** [`coverage_2026-05-14.md`](coverage_2026-05-14.md) (bash audit; Vault/OpenBao listed as blocked)  
**Related:** [`coverage_2026-05-19.md`](coverage_2026-05-19.md) (minor upgrade / PDG migration)

---

## Executive summary

| Metric | 2026-05-14 | 2026-05-19 (this work) | Δ |
|---|---|---|---|
| Pytest test modules | 18 | **26** | **+8** |
| Collected tests | 446 | **501** | **+55** |
| Bash scripts blocked on Vault/OpenBao/KMIP | 4 | **0** (pytest ports; still need live services) | closed in QA |
| KMIP pytest coverage | ❌ | **✅** PyKMIP + revalidation matrix + Vault KMIP regression | |
| OpenBao `pg_tde_open_bao_tests.sh` | partial (s1–3) | **✅ s1–12** (s11 in regressions) | |
| HashiCorp mount-metadata bash | ❌ | **✅** | |
| `change_database_key_provider_vault_v2.sh` | ❌ | **✅** (KV reseed + online SQL) | |

### Headline

External key-provider coverage moved from “bash-only + skip in CI” to a **dedicated pytest stack**: KMIP (PR #595 / PG-2125), Vault KV v2, OpenBao namespaces (PG-1959), HashiCorp and Vault-KMIP customer regressions, and **full bash parity** for the four automation scripts that were previously external-service-blocked.

Tests remain **opt-in** via `@pytest.mark.kmip` / `vault` / `openbao` and skip when `VAULT_*` / `KMIP_*` are unset.

---

## 1. New and extended pytest modules

| Module | Tests | Markers | Purpose |
|---|---|---|---|
| `tests/test_kmip.py` | 10 | `kmip`, `encryption` | PyKMIP smoke, bash parity slices, delete, offline CLI, PR #595 negatives |
| `tests/test_kmip_server_revalidation.py` | 1×N profiles | `kmip`, `kmip_revalidation` | Post–libkmip checklist per KMS profile |
| `tests/test_vault_providers.py` | 10 | `vault`, `openbao` | Vault KV v2 + OpenBao s1–3 (unchanged count; baseline) |
| `tests/test_vault_hashicorp_parity.py` | 2 | `vault` | HashiCorp mount-metadata + `change_database_key_provider_vault_v2` |
| `tests/test_openbao_bash_parity.py` | 8 | `vault`, `openbao` | `pg_tde_open_bao_tests.sh` scenarios 4–10, 12 |
| `tests/test_external_key_provider_regressions.py` | 7 | `bug`, `kmip`, `vault`, `openbao` | PG-2125 KMIP lifecycle; PG-1959 namespace + kv-only token; OpenBao s11 |
| `tests/test_vault_kmip.py` | 2 | `kmip`, `vault_kmip`, `bug` | HashiCorp **Vault KMIP engine** — customer `register symmetric key: -2` |

**Supporting libraries / scripts**

| Artifact | Role |
|---|---|
| `lib/kmip.py`, `lib/kmip_profiles.py`, `lib/kmip_revalidation.py` | KMIP config + revalidation checklist |
| `lib/vault_kmip.py` | Vault KMIP engine env + error matching |
| `lib/vault_cli.py` | KV-only tokens, `vault kv` export/import/delete |
| `lib/tde.py` | `change_database_key_provider_vault`, `change_global_key_provider_file`, `add_database_key_provider_file` |
| `scripts/setup_kmip_for_pytest.sh`, `scripts/run_kmip_revalidation.sh` | Docker PyKMIP / matrix runner |
| `scripts/setup_vault_for_pytest.sh`, `scripts/setup_openbao_for_pytest.sh` | Vault + OpenBao + optional `VAULT_KV_ONLY_TOKEN_FILE` |
| `scripts/setup_vault_kmip_for_pytest.sh` | Vault Enterprise KMIP engine (lab) |
| `docs/kmip.md`, `docs/kmip_revalidation.md`, `docs/vault_kmip.md`, `docs/vault.md` | Runbooks |

---

## 2. Bash script ↔ pytest parity (the four formerly blocked scripts)

| Bash script | Pytest | Notes |
|---|---|---|
| `pg_tde_hashicorp_vault_mount_permission_warning_test.sh` | `test_vault_hashicorp_parity.py::test_hashicorp_kv_only_token_without_mount_metadata` | Restricted token; no `sys/mounts`; mount `secret_v2` (or `VAULT_SECRET_MOUNT`) |
| `pg_tde_change_database_key_provider_vault_v2.sh` | `test_vault_hashicorp_parity.py::test_change_database_key_provider_vault_v2_after_kv_reseed` | Export KV → delete secrets → import → `pg_tde_change_database_key_provider_vault_v2`; needs `vault` CLI |
| `pg_tde_openbao_vault_mount_permission_warning_test.sh` | `test_external_key_provider_regressions.py::test_vault_kv_only_token_without_mount_metadata` | PG-1959 / PR #492; namespaced mount |
| `pg_tde_open_bao_tests.sh` | See §3 | 12 scenarios total |

**Also ported (functions_test / TAP overlap):** `test_vault_providers.py::TestHashicorpVaultKeyProvider` covers parts of `pg_tde_functions_test.sh` vault/KMIP paths.

---

## 3. `pg_tde_open_bao_tests.sh` — scenario map

| Scenario | Bash theme | Pytest |
|---|---|---|
| 1 | DB-scoped Vault on `db1` | `test_openbao_database_provider_outside_db_catalog_scope` |
| 2 | Multi-DB vault + kmip + file | `test_openbao_global_vault_multi_db_with_kmip_and_file` |
| 3 | Vault DB provider + KMIP global default | `test_openbao_local_db_vault_and_global_kmip_default` |
| 4 | One DB, vault + kmip + file providers | `test_openbao_scenario4_multi_provider_single_database` |
| 5 | `change_global_key_provider_file` | `test_openbao_scenario5_global_file_provider_change` |
| 6 | Global kmip + DB vault tables | `test_openbao_scenario6_local_and_global_vault_providers` |
| 7 | Default key rotation vault → kmip → file | `test_openbao_scenario7_default_key_rotation` |
| 8 | pg_dump restore + provider migration | `test_openbao_scenario8_dump_restore_provider_migration` (`@pytest.mark.slow`) |
| 9 | Default + local keys, delete provider/key | `test_openbao_scenario9_default_and_local_keys` |
| 10 | Global vault key on DB | `test_openbao_scenario10_delete_global_with_active_db_key` |
| 11 | Delete global after server key on file | `test_vault_delete_provider_after_server_key_on_file` (regressions) |
| 12 | Delete unused global provider | `test_openbao_scenario12_delete_unused_global_provider` |

---

## 4. KMIP revalidation matrix (PR #595)

| Profile | Automation | Pytest |
|---|---|---|
| `pykmip_docker` | `setup_kmip.sh` / Docker | Default `KMIP_REVALIDATE_PROFILES`; `test_kmip_server_revalidation` |
| `fortanix`, `thales`, `cosmian`, `akeyless` | Lab env | Same parametrized checklist; skip if `KMIP_<VENDOR>_HOST` unset |
| `vault_kmip` | Vault Enterprise KMIP | `test_vault_kmip.py` (customer register -2; xfail unless fixed) |

**Runner:** `./scripts/run_kmip_revalidation.sh` — checklist + `test_kmip.py` + `TestKmipCppClientRegression`.

---

## 5. Jira / PR regression mapping

| Jira | PR / theme | Pytest |
|---|---|---|
| [PG-2125](https://perconadev.atlassian.net/browse/PG-2125) | [PR #595](https://github.com/percona/pg_tde/pull/595) C++ kmipclient | `TestKmipCppClientRegression`, `test_kmip.py`, revalidation matrix |
| [PG-1959](https://perconadev.atlassian.net/browse/PG-1959) | [PR #442](https://github.com/percona/pg_tde/pull/442), [PR #492](https://github.com/percona/pg_tde/pull/492) | `TestVaultOpenBaoNamespaceRegression` |
| Customer report | Vault KMIP `register symmetric key: -2` | `test_vault_kmip.py` |

---

## 6. Remaining gaps (intentional)

| Item | Status |
|---|---|
| KMIP on every vendor lab (Fortanix, Thales, …) | Checklist exists; pass/fail is manual sign-off in `docs/kmip_revalidation.md` |
| Vault KMIP engine production support | Documented as **not** recommended vs Vault KV v2; test tracks customer issue |
| `pg_tde_key_info` / `pg_tde_verify_key` in OpenBao s4 | Omitted in pytest (smoke-only in bash) |
| Full Vault process restart in change-provider bash | Pytest uses KV delete + import equivalent |
| CI always-on | Jobs still opt-in: need Docker Vault/OpenBao/KMIP env |

---

## 7. Recommended CI jobs

```bash
cd postgresql/pytest
source .env.sh

# KMIP (PyKMIP Docker)
source scripts/setup_kmip_for_pytest.sh
./scripts/run_kmip_revalidation.sh

# HashiCorp Vault KV v2
source scripts/setup_vault_for_pytest.sh
pytest tests/test_vault_hashicorp_parity.py tests/test_vault_providers.py::TestHashicorpVaultKeyProvider -v

# OpenBao (+ KMIP for scenarios 2–8)
source scripts/setup_openbao_for_pytest.sh
source scripts/setup_kmip_for_pytest.sh
pytest tests/test_openbao_bash_parity.py tests/test_external_key_provider_regressions.py -v

# Skip sections when services unavailable
pytest tests/ --skip-sections=kmip,vault -v
```

---

## 8. Verification

```bash
cd postgresql/pytest
pytest tests/ --collect-only -q
# => 501 tests collected

pytest tests/test_kmip.py tests/test_vault_hashicorp_parity.py \
  tests/test_openbao_bash_parity.py tests/test_vault_kmip.py \
  tests/test_external_key_provider_regressions.py tests/test_vault_providers.py \
  --collect-only -q
# => 40 tests (external-key-provider focused modules)
```

---

## 9. Documentation index

| Doc | Path |
|---|---|
| KMIP pytest | `docs/kmip.md` |
| KMIP revalidation matrix | `docs/kmip_revalidation.md` |
| Vault / OpenBao | `docs/vault.md` |
| Vault KMIP engine | `docs/vault_kmip.md` |
| Test sections (`--skip-sections`) | `docs/test_sections.md` |
| Deep catalog (§18–24 added) | `coverage_reports/test_catalog_2026-05-14.md` |

---

*Generated from `postgresql/pytest/tests/test_{kmip,vault,openbao,external}*.py`, automation scripts under `postgresql/automation/tests/`, and `pytest tests/ --collect-only` on 2026-05-19.*
