# KMIP key provider — pytest guide

KMIP (Key Management Interoperability Protocol) is a **separate** key provider
from HashiCorp Vault / OpenBao. pg_tde talks to a KMIP server over TLS using
`pg_tde_add_global_key_provider_kmip` / `pg_tde_add_database_key_provider_kmip`.

**Automated KMIP testing uses Cosmian KMS**, not PyKMIP (abandoned upstream).
See [kmip_testing_strategy.md](kmip_testing_strategy.md) § Why Cosmian, not PyKMIP.

Recent pg_tde builds ([PR #595](https://github.com/percona/pg_tde/pull/595))
use the C++ **libkmip** submodule (`subprojects/libkmip`, `kmipclient::Kmip`)
for register / locate / get / validate instead of the legacy C libkmip BIO API.

**Full test catalog:** [kmip_test_coverage.md](kmip_test_coverage.md).

**Fortanix DSM lab setup:** [fortanix_kmip_setup.md](fortanix_kmip_setup.md).

## Prerequisites

1. **pg_tde with KMIP** — extension loads; SQL functions exist.
2. **Cosmian KMS** — local `cosmian_kms` binary (pg_tde CI) or remote `KMIP_COSMIAN_*` lab.
3. **Client certificates** — auto-generated locally, or from your Cosmian admin.

## Install Cosmian KMS (Ubuntu / Debian)

Same package as **pg_tde** `ci_scripts/ubuntu-deps.sh` (v5.21.0):

```bash
cd postgresql/pytest
./scripts/install_cosmian_kms.sh
```

Or manually on the VM:

```bash
COSMIAN_VERSION=5.21.0
ARCH=$(dpkg --print-architecture)
wget "https://package.cosmian.com/kms/${COSMIAN_VERSION}/deb/${ARCH}/non-fips/static/cosmian-kms-server-non-fips-static-openssl_${COSMIAN_VERSION}_${ARCH}.deb"
sudo dpkg -i "cosmian-kms-server-non-fips-static-openssl_${COSMIAN_VERSION}_${ARCH}.deb"
sudo chmod 0755 /usr/sbin/cosmian_kms
sudo chmod 0755 /usr/local/cosmian/lib/ossl-modules/legacy.so
```

Verify:

```bash
command -v cosmian_kms || ls -l /usr/sbin/cosmian_kms
```

Then:

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_cosmian_for_pytest.sh
./scripts/run_kmip_revalidation.sh
```

Build pg_tde from a tree that includes PR #595 (or `main` after merge) when
validating the new client:

```bash
cd postgresql/pytest
./build_from_source.sh --tde-ref libkmip-rework   # or main after merge
```

## Quick start

**CI / Cosmian (recommended):**

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_cosmian_for_pytest.sh   # local cosmian_kms or KMIP_COSMIAN_* from Jenkins
./scripts/run_kmip_revalidation.sh
```

**Local Cosmian only (pg_tde CI parity):**

```bash
source scripts/setup_cosmian_local_for_pytest.sh
pytest tests/test_kmip.py -v
```

Testing strategy: **[kmip_testing_strategy.md](kmip_testing_strategy.md)**.  
Advanced scenarios: **[kmip_advanced.md](kmip_advanced.md)** (classes in `tests/test_kmip.py`).

### Vendor lab (no local Cosmian)

When a KMIP server is already running (Fortanix, Thales, remote Cosmian, etc.):

```bash
export KMIP_SERVER_ADDRESS=127.0.0.1
export KMIP_SERVER_PORT=5696
export KMIP_CLIENT_CA=/path/to/client_certificate.pem
export KMIP_CLIENT_KEY=/path/to/client_key.pem
export KMIP_SERVER_CA=/path/to/root_ca.pem

./scripts/run_kmip_revalidation.sh
# or: pytest tests/test_kmip.py -v
```

Always **source** `setup_cosmian_for_pytest.sh` (not `./` in a subshell) so `KMIP_*` stays
in your shell before `pytest`. `run_kmip_revalidation.sh` sources it automatically when needed.

## Environment / CLI

| Variable | CLI flag | Meaning |
|----------|----------|---------|
| `KMIP_SERVER_ADDRESS` | `--kmip-server-address` | KMIP host |
| `KMIP_SERVER_PORT` | `--kmip-server-port` | Default `5696` (Cosmian local uses ephemeral port) |
| `KMIP_CLIENT_CA` | `--kmip-client-ca` | Client certificate PEM |
| `KMIP_CLIENT_KEY` | `--kmip-client-key` | Client private key PEM |
| `KMIP_SERVER_CA` | `--kmip-server-ca` | Server CA PEM (optional on 5-arg SQL builds) |

Tests are marked `@pytest.mark.kmip`. Without a reachable server and cert
files, they are **skipped** at collection (not failed).

```bash
pytest tests/ --skip-sections=kmip -v   # omit entire KMIP section
```

## What pytest covers

| Module | Bash / TAP reference | PR #595 operations exercised |
|--------|----------------------|------------------------------|
| `TestKmipKeyProviderBasics` | functions_test smoke | validate, register, locate+get, restart |
| `TestKmipBashParityScenarios` | functions_test §2–4, t/066 | multi-DB, default key, DB scope |
| `TestKmipDeleteKeyProvider` | t/064 | catalog delete rules |
| `TestKmipChangeKeyProviderCLI` | change_key_provider utility | offline KMIP connection update (keys on server) |
| `TestKmipLibkmipClientPr595` | — | bad host errors; `ldd` C++ link check |
| `TestKmipServerRevalidation` | — | **per-server matrix** after libkmip rewrite |

### Revalidate all supported KMIP servers

After PR #595, re-run the checklist on **every** documented KMIP backend
(Cosmian, Fortanix, Thales, Akeyless; Vault KMIP lab). See
**[kmip_revalidation.md](kmip_revalidation.md)** and:

```bash
./scripts/run_kmip_revalidation.sh
export KMIP_REVALIDATE_PROFILES=fortanix
pytest tests/test_kmip_server_revalidation.py -v
```

Vault / OpenBao: `tests/test_vault_providers.py` and [vault.md](vault.md).

Vault **KMIP engine** (customer ``register symmetric key: -2``): [vault_kmip.md](vault_kmip.md).

## Jenkins / ppg-testing

**Every build:** Cosmian via `setup_cosmian_for_pytest.sh` + `run_kmip_revalidation.sh`
(`KMIP_COSMIAN_*` Jenkins credentials).

**Scheduled / release:** one job per vendor (`KMIP_REVALIDATE_PROFILES=fortanix`, etc.).
See [kmip_testing_strategy.md](kmip_testing_strategy.md).

## Jira regressions

| Jira | Fix | Pytest |
|------|-----|--------|
| [PG-2125](https://perconadev.atlassian.net/browse/PG-2125) | [PR #595](https://github.com/percona/pg_tde/pull/595) C++ kmipclient | `tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression` |

## Troubleshooting

| Symptom | Action |
|---------|--------|
| `ERROR: no Cosmian KMIP available` | Run `./scripts/install_cosmian_kms.sh`, then re-source setup |
| SSH session closes after setup error | Fixed in current scripts (no `set -e` when sourced). Update repo and re-run `source scripts/setup_cosmian_for_pytest.sh` — you should stay logged in and see `return 1` only |
| Skip: cannot reach KMIP | Install `cosmian_kms` or set `KMIP_COSMIAN_*` |
| Skip: cert missing | Re-run `setup_cosmian_for_pytest.sh`; check cert paths under `/tmp/pg_tde_pytest_cosmian_local/` |
| ERROR on add provider | Wrong host — use `127.0.0.1` not `0.0.0.0` from Python |
| `ldd` test skipped | Old pg_tde without C++ kmipclient — rebuild with PR #595 |
