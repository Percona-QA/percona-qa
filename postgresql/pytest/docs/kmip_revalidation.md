# KMIP server revalidation matrix (PR #595)

The pg_tde KMIP stack was rewritten ([PR #595](https://github.com/percona/pg_tde/pull/595),
[Jira PG-2125](https://perconadev.atlassian.net/browse/PG-2125)): legacy C **libkmip**
BIO calls were replaced by **subprojects/libkmip** and the C++ **kmipclient**
(`op_register_key`, `op_locate_by_name`, `op_get_key`, `kmip_run` errors, 10s timeout).

QA must **re-run the full KMIP surface** on every server Percona documents as a
supported KMIP provider.

## Supported profiles

| Profile ID | Vendor | Percona docs | Automation |
|------------|--------|--------------|------------|
| `cosmian` | Cosmian KMS | [Cosmian integration](https://docs.cosmian.com/key_management_system/integrations/databases/percona/) | **CI (every build)** — `setup_cosmian_for_pytest.sh` |
| `fortanix` | Fortanix DSM | [Fortanix](https://docs.percona.com/pg-tde/global-key-provider-configuration/fortanix.html) · [Lab setup](fortanix_kmip_setup.md) | Scheduled / manual sign-off |
| `thales` | Thales CipherTrust Manager | [Thales](https://docs.percona.com/pg-tde/global-key-provider-configuration/thales.html) | Scheduled / manual sign-off |
| `akeyless` | Akeyless | [Akeyless](https://docs.percona.com/pg-tde/global-key-provider-configuration/akeyless.html) | Scheduled / manual sign-off |
| `vault_kmip` | HashiCorp Vault KMIP engine | [Vault KMIP](https://developer.hashicorp.com/vault/docs/secrets/kmip) | On demand (not production path) |

See **[kmip_testing_strategy.md](kmip_testing_strategy.md)** for CI vs vendor-matrix workflow.

**HashiCorp Vault KMIP engine:** not a production target (use Vault KV v2 in
[vault.md](vault.md)). Lab regression: [vault_kmip.md](vault_kmip.md) and profile
`vault_kmip` (`KMIP_VAULT_*`).

## Checklist (per server)

Each profile runs `tests/test_kmip_server_revalidation.py`:

| Step | PR #595 operation | What pytest does |
|------|-------------------|------------------|
| 1 | **validate** | `add_global_key_provider_kmip` (TLS + KMIP connect) |
| 2 | **register** | `set_global_principal_key` |
| 3 | **locate + get** | Encrypted `tde_heap` table, 100 rows |
| 4 | — | Stop/start cluster; read data |
| 5 | **register** | Principal key rotation |
| 6 | — | Second restart after rotation |
| 7 | DB scope | `add_database_key_provider_kmip` + DML + restart |

Then run the **deeper** suites on at least one lab server per vendor:

- `tests/test_kmip_common_matrix.py` — shared scenarios including online
  ``pg_tde_change_*_key_provider_kmip`` (database + global scope)
- `tests/test_kmip.py` — bash parity, delete, offline `change_key_provider`, negatives
- `tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression` — PG-2125 lifecycle

Record build ref (`libkmip-rework` / `main`), pg_tde version, and pass/fail in your
release or Jira ticket.

## Environment

Copy `config/kmip_profiles.example.env` and export variables for each lab server.

| Profile | Env prefix | Example |
|---------|------------|---------|
| `cosmian` | `KMIP_COSMIAN_*` | `scripts/setup_cosmian_for_pytest.sh` (CI default) |
| `fortanix` | `KMIP_FORTANIX_*` | `HOST`, `PORT`, `CLIENT_CERT`, `CLIENT_KEY`, `SERVER_CA` |
| `thales` | `KMIP_THALES_*` | same |
| `akeyless` | `KMIP_AKEYLESS_*` | same |

Select profiles:

```bash
export KMIP_REVALIDATE_PROFILES=cosmian              # CI default
export KMIP_REVALIDATE_PROFILES=fortanix,thales      # vendor sign-off
export KMIP_REVALIDATE_PROFILES=all                  # full matrix (skips unconfigured)
```

Or CLI: `pytest --kmip-revalidate-profiles=fortanix tests/test_kmip_server_revalidation.py`

## Commands

**CI (Cosmian — automated):**

```bash
cd postgresql/pytest
source .env.sh
# Jenkins injects KMIP_COSMIAN_* credentials
source scripts/setup_cosmian_for_pytest.sh
./scripts/run_kmip_revalidation.sh
```

**Local dev (Cosmian, pg_tde CI parity):**

```bash
source scripts/setup_cosmian_local_for_pytest.sh
./scripts/run_kmip_revalidation.sh
```

**Vendor lab** (export `KMIP_*` to a running server first — see [kmip.md](kmip.md)):

```bash
export KMIP_SERVER_ADDRESS=...
export KMIP_CLIENT_CA=...
export KMIP_CLIENT_KEY=...
export KMIP_SERVER_CA=...
./scripts/run_kmip_revalidation.sh
```

**Single vendor lab:**

```bash
source .env.sh
# export KMIP_FORTANIX_* from your lab (see example env file)
export KMIP_REVALIDATE_PROFILES=fortanix
pytest tests/test_kmip_server_revalidation.py -v
pytest tests/test_kmip.py -v   # uses KMIP_* — map same certs to KMIP_SERVER_* or symlink
```

For `test_kmip.py`, the default fixture still reads `KMIP_*` / `--kmip-*`. Point
those at the same host/certs as the vendor prefix, or re-export after setup:

```bash
export KMIP_SERVER_ADDRESS="$KMIP_FORTANIX_HOST"
export KMIP_CLIENT_CA="$KMIP_FORTANIX_CLIENT_CERT"
# ...
```

**Full matrix (manual sign-off):**

```bash
export KMIP_REVALIDATE_PROFILES=all
pytest tests/test_kmip_server_revalidation.py -v --tb=short
# Configure each KMIP_* / KMIP_<VENDOR>_* in turn; re-run until all profiles pass
```

Skip entire section: `pytest --skip-sections=kmip`.

## QA sign-off table (template)

| Profile | Build / branch | Date | Checklist | test_kmip.py | PG-2125 regression | Sign-off |
|---------|----------------|------|-----------|--------------|-------------------|----------|
| fortanix | | | | | | |
| thales | | | | | | |
| cosmian | | | | | | |
| akeyless | | | | | | |
| vault_kmip | | | | | `test_vault_kmip.py` | |

## Related

- [kmip.md](kmip.md) — Cosmian setup, env vars, test map
- `lib/kmip_profiles.py` — profile definitions
- `lib/kmip_revalidation.py` — shared checklist implementation
