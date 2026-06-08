# KMIP testing strategy (Percona engineering)

This document aligns **percona-qa pytest** with how **pg_tde** runs KMIP tests.

## Why Cosmian, not PyKMIP

**pg_tde engineering moved KMIP testing from PyKMIP to Cosmian KMS** because
[PyKMIP](https://github.com/PyKMIP/PyKMIP) is **completely abandoned** upstream.
Percona CI and percona-qa pytest use **Cosmian only** for automated KMIP regression:

- No Docker `mohitpercona/kmip` image
- No `pykmip` Python package as a test server
- No `pykmip_docker` revalidation profile

Local and CI entry point: `scripts/setup_cosmian_for_pytest.sh` (spawns
`cosmian_kms` like `t/CosmianKms.pm`, or uses `KMIP_COSMIAN_*` from Jenkins).

Vendor labs (Fortanix, Thales, Akeyless) remain for **scheduled sign-off**, not
as a PyKMIP substitute.

**Source of truth (pg_tde repo):**

| Artifact | Path | Role |
|----------|------|------|
| TAP KMIP test | `t/kmip.pl` | Cosmian lifecycle + negatives |
| Cosmian harness | `t/CosmianKms.pm` | Spawn `cosmian_kms`, gen TLS certs, free ports |
| CI install | `ci_scripts/ubuntu-deps.sh` | Installs `cosmian_kms` **5.21.0** `.deb` |
| CI gate | `.github/workflows/build-and-test.yml` | `PG_TEST_REQUIRE_COSMIAN_KMS=1` on Ubuntu |
| Test runner | `ci_scripts/test.sh` | `meson test` (includes `t/kmip.pl`) |

pg_tde CI starts **local** `cosmian_kms` on `127.0.0.1` with ephemeral SQLite +
generated certs (same as TAP).

## Two layers

| Layer | Purpose | When | Backend |
|-------|---------|------|---------|
| **1 — CI regression** | Catch regressions on every build | Every CI run | **Cosmian KMS** (automated) |
| **2 — Vendor matrix** | Prove PR #595 / libkmip works on **every** supported vendor | Major KMIP changes + **regular** cadence | Fortanix, Thales, Akeyless, Vault KMIP, Cosmian |

## Layer 1 — CI (Cosmian, automated)

Same model as pg_tde GitHub Actions: install `cosmian_kms`, spawn locally, run tests.

**pg_tde (meson TAP):**

```bash
cd pg_tde/build
# ubuntu-deps.sh already installed cosmian_kms
PG_TEST_REQUIRE_COSMIAN_KMS=1 meson test t/kmip.pl --print-errorlogs
```

**percona-qa (pytest parity):**

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_cosmian_for_pytest.sh   # auto: local cosmian_kms if installed
./scripts/run_kmip_revalidation.sh
```

`setup_cosmian_for_pytest.sh` order:

1. Reuse existing `KMIP_*` if already set  
2. If `cosmian_kms` on PATH → `setup_cosmian_local_for_pytest.sh` (mirrors `t/CosmianKms.pm`)  
3. Else if `KMIP_COSMIAN_HOST` set → remote lab Cosmian  
4. Else error with install/lab instructions

**Install Cosmian (same as pg_tde CI):** `./scripts/install_cosmian_kms.sh` or `pg_tde/ci_scripts/ubuntu-deps.sh` (Cosmian KMS **5.21.0** deb).

| Env (local spawn) | Set by |
|-------------------|--------|
| `COSMIAN_KMS_BIN` | Optional override (default `/usr/sbin/cosmian_kms`) |
| `KMIP_SERVER_ADDRESS` | `127.0.0.1` |
| `KMIP_SERVER_PORT` | Ephemeral free port |
| `KMIP_*` cert paths | Under `/tmp/pg_tde_pytest_cosmian_local/` |
| `KMIP_REVALIDATE_PROFILES` | `cosmian` |

**Remote lab Cosmian** (optional): set `KMIP_COSMIAN_HOST` + certs before sourcing setup script.

**Expected:** 15+ tests pass; profile `cosmian` only (not `all`).

## Layer 2 — Vendor matrix (manual sign-off → automate over time)

After a **major KMIP client change** (e.g. PR #595), engineering **manually** verifies all vendors, then records sign-off.

**Goal:** run the same matrix **on a schedule** (weekly/monthly) per vendor — not only on major changes.

### Per-vendor commands

```bash
source .env.sh
export KMIP_REVALIDATE_PROFILES=<profile>   # one vendor at a time

# Export KMIP_<VENDOR>_* — see config/kmip_profiles.example.env
# Map to KMIP_* for the full suite:
export KMIP_SERVER_ADDRESS="$KMIP_FORTANIX_HOST"   # example
export KMIP_SERVER_PORT="${KMIP_FORTANIX_PORT:-5696}"
export KMIP_CLIENT_CA="$KMIP_FORTANIX_CLIENT_CERT"
export KMIP_CLIENT_KEY="$KMIP_FORTANIX_CLIENT_KEY"
export KMIP_SERVER_CA="$KMIP_FORTANIX_SERVER_CA"

pytest tests/test_kmip_server_revalidation.py -v
pytest tests/test_kmip.py -v
pytest tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression -v
```

| Profile | Vendor | Env prefix | Extra tests |
|---------|--------|------------|-------------|
| `cosmian` | Cosmian KMS | `KMIP_COSMIAN_*` | CI default |
| `fortanix` | Fortanix DSM | `KMIP_FORTANIX_*` | checklist + full |
| `thales` | Thales CipherTrust | `KMIP_THALES_*` | checklist + full |
| `akeyless` | Akeyless | `KMIP_AKEYLESS_*` | checklist + full |
| `vault_kmip` | Vault KMIP engine | `KMIP_VAULT_*` | `test_vault_kmip.py` (not production path) |

### Full matrix (all configured vendors)

```bash
export KMIP_REVALIDATE_PROFILES=all
pytest tests/test_kmip_server_revalidation.py -v --tb=short
```

Unconfigured vendors **skip** — that is expected until secrets exist for each Jenkins job.

## Recommended Jenkins jobs

| Job | Schedule | `KMIP_REVALIDATE_PROFILES` | Credentials |
|-----|----------|------------------------------|-------------|
| `pg-tde-kmip-ci` | Every build | `cosmian` | `KMIP_COSMIAN_*` |
| `pg-tde-kmip-fortanix` | Weekly | `fortanix` | `KMIP_FORTANIX_*` |
| `pg-tde-kmip-thales` | Weekly | `thales` | `KMIP_THALES_*` |
| `pg-tde-kmip-akeyless` | Weekly | `akeyless` | `KMIP_AKEYLESS_*` |
| `pg-tde-vault-kmip` | On demand | N/A | Vault Enterprise + `test_vault_kmip.py` |

## Sign-off template

See [kmip_revalidation.md](kmip_revalidation.md) § QA sign-off table. Record pg_tde version, branch, date, and owner per vendor.

## Pytest layers (not TAP ports)

| Layer | Module | Focus |
|-------|--------|-------|
| Smoke + bash parity | `test_kmip.py` | functions_test slices, delete, offline CLI |
| **Advanced corner cases** | `test_kmip.py` (advanced classes) | Rotation churn, multi-DB, mixed providers, TOAST/partitions, WAL, dump/restore, failures |
| PG-2125 lifecycle | `TestKmipCppClientRegression` | Restarts, idempotent create, WAL |
| Vendor checklist | `test_kmip_server_revalidation.py` | Per-KMS sign-off |

See **[kmip_advanced.md](kmip_advanced.md)** for the full advanced scenario matrix (14 tests).

pg_tde `t/kmip.pl` remains upstream meson coverage; percona-qa pytest goes **deeper**
than TAP (multi-rotation, partitions, dump/restore, mixed topologies).

Vendor matrix (Fortanix, Thales, Akeyless) has no TAP in pg_tde — manual/scheduled pytest only.

## Related

- [kmip.md](kmip.md) — env vars, test map
- [kmip_revalidation.md](kmip_revalidation.md) — checklist steps
- `scripts/setup_cosmian_local_for_pytest.sh` — local `cosmian_kms` (pg_tde parity)
- `scripts/setup_cosmian_for_pytest.sh` — CI entry (local or remote)
- pg_tde: `t/kmip.pl`, `t/CosmianKms.pm`, `ci_scripts/ubuntu-deps.sh`
