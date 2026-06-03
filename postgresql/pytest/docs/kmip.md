# KMIP key provider — pytest guide

KMIP (Key Management Interoperability Protocol) is a **separate** key provider
from HashiCorp Vault / OpenBao. pg_tde talks to a KMIP server over TLS using
`pg_tde_add_global_key_provider_kmip` / `pg_tde_add_database_key_provider_kmip`.

Recent pg_tde builds ([PR #595](https://github.com/percona/pg_tde/pull/595))
use the C++ **libkmip** submodule (`subprojects/libkmip`, `kmipclient::Kmip`)
for register / locate / get / validate instead of the legacy C libkmip BIO API.

## Prerequisites

1. **pg_tde with KMIP** — extension loads; SQL functions exist.
2. **KMIP test server** — Docker image `mohitpercona/kmip:latest` (port **5696**).
3. **Client certificates** — copied to `/tmp/certs/` by the setup script.

Build pg_tde from a tree that includes PR #595 (or `main` after merge) when
validating the new client:

```bash
cd postgresql/pytest
./build_from_source.sh --tde-ref libkmip-rework   # or main after merge
```

## Quick start

```bash
cd postgresql/pytest
source .env.sh                    # INSTALL_DIR, venv
source scripts/setup_kmip_for_pytest.sh   # needs Docker, unless KMIP_* is already set

pytest tests/test_kmip.py -v
pytest tests/ -m kmip -v
pytest --list-test-sections       # section name: kmip
```

### Without Docker

Use this when Docker is not installed (common on bare-metal build VMs) but a KMIP
server is already running (lab PyKMIP, Fortanix, etc.):

```bash
export KMIP_SERVER_ADDRESS=127.0.0.1
export KMIP_SERVER_PORT=5696
export KMIP_CLIENT_CA=/path/to/client_certificate.pem
export KMIP_CLIENT_KEY=/path/to/client_key.pem
export KMIP_SERVER_CA=/path/to/root_ca.pem

./scripts/run_kmip_revalidation.sh
# or: pytest tests/test_kmip.py -v
```

`setup_kmip_for_pytest.sh` and `run_kmip_revalidation.sh` skip Docker when
`KMIP_*` is set, cert files exist, and the host:port accepts TCP.

## Environment / CLI

| Variable | CLI flag | Meaning |
|----------|----------|---------|
| `KMIP_SERVER_ADDRESS` | `--kmip-server-address` | KMIP host (`127.0.0.1` if Docker published `0.0.0.0`) |
| `KMIP_SERVER_PORT` | `--kmip-server-port` | Default `5696` |
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
(PyKMIP Docker, Fortanix, Thales, Cosmian, Akeyless). See
**[kmip_revalidation.md](kmip_revalidation.md)** and:

```bash
./scripts/run_kmip_revalidation.sh
export KMIP_REVALIDATE_PROFILES=fortanix
pytest tests/test_kmip_server_revalidation.py -v
```

Vault / OpenBao: `tests/test_vault_providers.py` and [vault.md](vault.md).

## Jenkins / ppg-testing

Run KMIP as an **opt-in** job stage after `setup_kmip_for_pytest.sh` (or the
equivalent Ansible/docker step in [ppg-testing](https://github.com/Percona-QA/ppg-testing)),
then pass the env vars above to pytest. Molecule/pg_tde installcheck does not
replace these integration tests.

## Jira regressions

| Jira | Fix | Pytest |
|------|-----|--------|
| [PG-2125](https://perconadev.atlassian.net/browse/PG-2125) | [PR #595](https://github.com/percona/pg_tde/pull/595) C++ kmipclient | `tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression` |

## Troubleshooting

| Symptom | Action |
|---------|--------|
| Skip: cannot reach KMIP | `docker ps`, re-run `setup_kmip_for_pytest.sh`, wait ~30s |
| Skip: cert missing | Check `/tmp/certs/*.pem` after `docker cp` from container |
| ERROR on add provider | Wrong host — use `127.0.0.1` not `0.0.0.0` from Python |
| `ldd` test skipped | Old pg_tde without C++ kmipclient — rebuild with PR #595 |
