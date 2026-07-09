# Jira template — KMIP / Vault verification coverage

> Copy sections below into your Jira ticket. Adjust **Vendor**, **Environment**, and **Results** per run.  
> Full reference: [vendor-signoff.md](vendor-signoff.md) · [../vault.md](../vault.md)

---

## Paste into Jira — Summary

**Objective:** Revalidate pg_tde external key providers against Percona QA automation after libkmip C++ client (PR #595 / PG-2125).

**Harness:** `percona-qa/postgresql/pytest` — ephemeral PostgreSQL clusters, pytest.

**Note:** *KMIP* and *Vault KV v2* are **separate** provider types. Vault **KMIP engine** is lab-only (not production path).

---

## KMIP server verification (Fortanix / Thales / Akeyless / Cosmian)

### Layer A — Revalidation checklist (required per KMS)

Runs once per vendor profile. Exercises libkmip operations: **validate → register → locate → get → restart → rotate → database scope**.

| Step | KMIP / pg_tde operation | Scenario |
|------|-------------------------|----------|
| 1 | **Validate** | `pg_tde_add_global_key_provider_kmip` — mutual TLS connect to KMS |
| 2 | **Register** | Create + set global principal key on KMS |
| 3 | **Locate + Get** | `tde_heap` table, 100 rows INSERT/SELECT |
| 4 | **Restart** | Stop/start cluster; data still readable (decrypt from KMS) |
| 5 | **Register (rotate)** | Principal key rotation on same provider |
| 6 | **Restart (2nd)** | After rotation; INSERT + restart; data intact |
| 7 | **Database scope** | `pg_tde_add_database_key_provider_kmip` on second DB; DML + restart |

**Automation:** `./scripts/run_kmip_matrix.sh` with `KMIP_MATRIX_SUITE=checklist`  
**Profile env:** `KMIP_<VENDOR>_HOST`, `_PORT`, `_CLIENT_CERT`, `_CLIENT_KEY`, `_SERVER_CA`  
**Example:** `KMIP_PROFILE=thales` or `KMIP_REVALIDATE_PROFILES=fortanix,thales,akeyless`

---

### Layer B — Common KMIP matrix (required for vendor sign-off)

Same scenarios on **every** configured KMS profile:

| # | Scenario | What it validates |
|---|----------|-------------------|
| 1 | Global smoke + restart | Provider add, principal key, 120 encrypted rows, restart |
| 2 | Key rotation | Rotate principal key; data survives restart |
| 3 | Multi-DB file + KMIP | db1 file keyring + db2 KMIP key; both DBs after restart |
| 4 | Change DB provider (catalog) | `pg_tde_change_database_key_provider_kmip` updates options |
| 5 | Change global provider (catalog) | `pg_tde_change_global_key_provider_kmip` updates options |
| 6 | Change DB provider in use | Online reconfig with 50 encrypted rows; `pg_tde_verify_key` |
| 7 | Change global provider in use | Online reconfig with 80 rows; verify after restart |
| 8 | Change missing DB provider | Must fail for unknown provider name |
| 9 | Change missing global provider | Must fail for unknown provider name |

**Automation:** `./scripts/run_kmip_matrix.sh` (default `KMIP_MATRIX_SUITE=all`)

---

### Layer C — Extended KMIP (optional / Cosmian CI depth)

Run for full sign-off or CI parity on Cosmian:

| Area | Scenarios |
|------|-----------|
| Provider basics | Add provider, bad host rejected, extension load |
| Bash parity | Multi-DB, default key, database scope (legacy automation parity) |
| Delete provider | Catalog delete rules |
| Offline CLI | `pg_tde_change_key_provider` with KMIP PEM paths (server stopped) |
| Multi-DB isolation | Separate KMIP keys per database |
| Mixed topology | File + KMIP providers together |
| Key rotation churn | Repeated rotations under load |
| WAL / server key | Server key with WAL encryption |
| Failure cases | Unreachable host, auth errors |
| PG-2125 regression | Full libkmip C++ client lifecycle |

**Automation:** `pytest tests/test_kmip.py -v` + `tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression`  
**Cosmian CI:** `./scripts/run_kmip_revalidation.sh`

---

### Vault KMIP engine (lab only — not production)

Separate from KMIP vendors above. Customer regression: **Register symmetric key: -2**.

| Scenario | Purpose |
|----------|---------|
| Create key via global KMIP provider | Reproduces Vault Enterprise KMIP engine behaviour |
| Register -2 handling | Documented xfail until engine fixed |

**Automation:** `KMIP_PROFILE=vault_kmip pytest tests/test_vault_kmip.py -v`  
**Production path:** use Vault **KV v2** below, not KMIP engine.

---

## Vault KV v2 / OpenBao verification (production secret-store path)

### Shared Vault KV matrix (required)

| # | Scenario | What it validates |
|---|----------|-------------------|
| 1 | Global smoke + restart | `pg_tde_add_global_key_provider_vault_v2`, principal key, encrypted DML, restart |
| 2 | Key rotation | Rotate principal key; data after restart |
| 3 | Database-scoped provider | Per-DB vault provider + encrypted table |

**Automation:** `./scripts/run_vault_kv_matrix.sh`  
**Profiles:** `hashicorp`, `hashicorp_enterprise` (namespace + mount), `openbao`

---

### HashiCorp Vault — extended (Enterprise lab)

| Scenario | Purpose |
|----------|---------|
| Namespace + mount `pg_tde` | Enterprise KV layout |
| Mount permission warning | PG mount metadata edge case |
| Change DB provider vault_v2 | Online provider metadata update |

**Automation:** `VAULT_KV_INCLUDE_SPECIFIC=1 ./scripts/run_vault_kv_matrix.sh`

---

### OpenBao — extended

| Scenario | Purpose |
|----------|---------|
| Namespace `pg_tde_ns1` | KV v2 with namespace header |
| Bash parity scenarios 4–10, 12 | Legacy `pg_tde_open_bao_tests.sh` coverage |
| PG-1959 regression | Namespace token / mount isolation |
| KMIP-backed OpenBao scenarios | Scenarios 2–8 when Cosmian KMIP available |

**Automation:** `source scripts/setup_openbao_for_pytest.sh && ./scripts/run_openbao_revalidation.sh`

---

## Commands (lab VM)

```bash
cd percona-qa/postgresql/pytest
source .env.sh

# --- KMIP vendor (example: Thales) ---
export KMIP_THALES_HOST=...
export KMIP_THALES_PORT=5696
export KMIP_THALES_CLIENT_CERT=...
export KMIP_THALES_CLIENT_KEY=...
export KMIP_THALES_SERVER_CA=...
export KMIP_PROFILE=thales
./scripts/run_kmip_matrix.sh

# Checklist only (faster gate)
KMIP_MATRIX_SUITE=checklist KMIP_PROFILE=thales ./scripts/run_kmip_matrix.sh

# --- Vault KV ---
export VAULT_ADDR=...
export VAULT_TOKEN=...
export VAULT_SECRET_MOUNT=secret   # or pg_tde for OpenBao
./scripts/run_vault_kv_matrix.sh

# --- OpenBao ---
source scripts/setup_openbao_for_pytest.sh
./scripts/run_openbao_revalidation.sh
```

---

## Sign-off table (fill in Jira)

| Backend | Vendor / profile | pg_tde version | Build / branch | Checklist (Layer A) | Common matrix (Layer B) | Extended (Layer C) | Result | Date | QA |
|---------|------------------|----------------|----------------|---------------------|-------------------------|--------------------|--------|------|-----|
| KMIP | Cosmian | | | | | | | | |
| KMIP | Fortanix | | | | | | | | |
| KMIP | Thales CipherTrust | | | | | | | | |
| KMIP | Akeyless | | | | | | | | |
| KMIP | Vault KMIP engine | | | | | N/A | | | |
| Vault KV | HashiCorp (root) | | | | | | | | |
| Vault KV | HashiCorp Enterprise | | | | | | | | |
| OpenBao | namespace + pg_tde mount | | | | | | | | |

**Pass criteria:** Layer A + Layer B green for KMIP vendors; Vault KV matrix green for Vault/OpenBao sign-off.

---

## References

- [vendor-signoff.md](vendor-signoff.md)
- [ci-strategy.md](ci-strategy.md)
- [quickstart.md](quickstart.md)
- [../vault.md](../vault.md)
- [../key_provider_matrix.md](../key_provider_matrix.md)
