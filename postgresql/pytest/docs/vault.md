# Vault and OpenBao — pytest guide

pg_tde stores encryption keys in **HashiCorp Vault** or **OpenBao** using the
`vault-v2` SQL API (`pg_tde_add_global_key_provider_vault_v2`, etc.). Both
products share the same HTTP API; OpenBao tests additionally set a
**namespace** and often use mount `pg_tde` instead of `secret`.

KMIP is separate — see [kmip.md](kmip.md).

**Vault KMIP engine** (not KV v2): customer ``register symmetric key: -2`` regression
in [vault_kmip.md](vault_kmip.md) / `tests/test_vault_kmip.py`.

## Test modules

| Module | Marker(s) | Server |
|--------|-----------|--------|
| `tests/test_vault_providers.py::TestHashicorpVaultKeyProvider` | `vault` | Vault dev / `setup_vault.sh` / Docker |
| `tests/test_vault_providers.py::TestOpenBaoKeyProvider` | `vault`, `openbao` | `install_openbao.sh` + `setup_openbao_for_pytest.sh` |
| `tests/test_openbao_bash_parity.py` | `vault`, `openbao` | same (+ KMIP for scenarios 4–8) |

Legacy smoke: `tests/test_encryption.py::TestKeyManagement::test_vault_key_provider`.

## Quick start — Docker Vault (fastest)

```bash
cd postgresql/pytest
docker compose up -d vault
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export VAULT_SECRET_MOUNT=secret

source .env.sh
pytest tests/test_vault_providers.py::TestHashicorpVaultKeyProvider -v
```

## Quick start — automation Vault (SSL)

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_vault_for_pytest.sh
pytest tests/test_vault_providers.py::TestHashicorpVaultKeyProvider -v
```

## Install OpenBao (Ubuntu / Debian)

Same package as **pg_tde** `ci_scripts/ubuntu-deps.sh` (v2.5.4). No Go build required.

```bash
cd postgresql/pytest
./scripts/install_openbao.sh
```

Or manually:

```bash
OPENBAO_VERSION=2.5.4
ARCH=$(dpkg --print-architecture)
wget "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb"
sudo dpkg -i "openbao_${OPENBAO_VERSION}_linux_${ARCH}.deb"
bao version
```

## OpenBao (namespace tests)

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_openbao_for_pytest.sh
./scripts/run_openbao_revalidation.sh
```

`setup_openbao_for_pytest.sh` starts `bao server -dev`, creates namespace `pg_tde_ns1`,
enables KV v2 mount `pg_tde`, and exports `VAULT_KV_ONLY_TOKEN_FILE` for PG-1959.

KMIP-backed scenarios (open_bao_tests 2–8): `run_openbao_revalidation.sh` auto-sources
`setup_cosmian_for_pytest.sh` when KMIP is not already configured.

```bash
pytest tests/test_vault_providers.py::TestOpenBaoKeyProvider -v
pytest tests/test_openbao_bash_parity.py -v
pytest -m openbao -v
```

**Legacy** source build (Go >= 1.25.4): `OPENBAO_BUILD_FROM_SOURCE=1 source scripts/setup_openbao_for_pytest.sh`

## Environment / CLI

| Variable | CLI flag | Default |
|----------|----------|---------|
| `VAULT_ADDR` | `--vault-addr` | (required) |
| `VAULT_TOKEN` | `--vault-token` | inline token |
| `VAULT_TOKEN_FILE` | `--vault-token-file` | preferred in bash (4th SQL arg) |
| `VAULT_SECRET_MOUNT` | `--vault-secret-mount` | `secret` (OpenBao: `pg_tde`) |
| `VAULT_CA_PATH` | `--vault-ca-path` | HTTPS automation Vault |
| `VAULT_NAMESPACE` | `--vault-namespace` | empty; OpenBao: `pg_tde_ns1/` |

```bash
pytest tests/ -m vault -v
pytest tests/ -m openbao -v
pytest tests/ --skip-sections=vault -v
```

## Bash parity

| Bash script | Pytest |
|-------------|--------|
| `pg_tde_hashicorp_vault_mount_permission_warning_test.sh` | `tests/test_vault_hashicorp_parity.py::TestHashicorpVaultMountPermissionWarning` |
| `pg_tde_change_database_key_provider_vault_v2.sh` | `tests/test_vault_hashicorp_parity.py::TestHashicorpVaultChangeDatabaseKeyProviderV2` |
| `pg_tde_openbao_vault_mount_permission_warning_test.sh` | `tests/test_external_key_provider_regressions.py::test_vault_kv_only_token_without_mount_metadata` |
| `pg_tde_open_bao_tests.sh` scenarios 1–3 | `tests/test_vault_providers.py::TestOpenBaoKeyProvider` |
| `pg_tde_open_bao_tests.sh` scenarios 4–10, 12 | `tests/test_openbao_bash_parity.py` |
| `pg_tde_open_bao_tests.sh` scenario 11 | `tests/test_external_key_provider_regressions.py::test_vault_delete_provider_after_server_key_on_file` |
| `pg_tde_functions_test.sh` (vault parts) | `tests/test_vault_providers.py::TestHashicorpVaultKeyProvider` |
| `t/064_delete_key_providers.pl` | `test_delete_*_vault_*` |

### Run parity suites

```bash
source scripts/setup_vault_for_pytest.sh
pytest tests/test_vault_hashicorp_parity.py -v

source scripts/setup_openbao_for_pytest.sh
source scripts/setup_cosmian_for_pytest.sh
pytest tests/test_openbao_bash_parity.py -v
```

## Jira regressions

| Jira | Fix | Pytest |
|------|-----|--------|
| [PG-1959](https://perconadev.atlassian.net/browse/PG-1959) | [PR #442](https://github.com/percona/pg_tde/pull/442) namespaces, [PR #492](https://github.com/percona/pg_tde/pull/492) JSON parser | `tests/test_external_key_provider_regressions.py::TestVaultOpenBaoNamespaceRegression` |

`setup_openbao_for_pytest.sh` exports `VAULT_KV_ONLY_TOKEN_FILE` when `bin/bao` is available.

## Jenkins / ppg-testing

Add optional stages:

1. **vault** — `docker compose up vault` or `setup_vault_for_pytest.sh`, then `pytest -m vault`.
2. **openbao** — `install_openbao.sh`, `setup_openbao_for_pytest.sh`, `run_openbao_revalidation.sh`.

Do not mix Vault SSL URLs with the Docker dev server without matching `VAULT_CA_PATH`.

## Troubleshooting

| Symptom | Action |
|---------|--------|
| `bao not found` | Run `./scripts/install_openbao.sh` |
| OpenBao tests skipped (`HTTP 400` on health) | Pull latest pytest — health check must not send `X-Vault-Namespace` |
| OpenBao tests skipped (other) | `source scripts/setup_openbao_for_pytest.sh` — needs `VAULT_NAMESPACE` |
| Stale `VAULT_*` from old server | `OPENBAO_FORCE_RESTART=1 source scripts/setup_openbao_for_pytest.sh` |
| SSH closes on setup error | Update repo — setup script is SSH-safe (no `set -e` when sourced) |
| KMIP scenarios skip in OpenBao suite | `source scripts/setup_cosmian_for_pytest.sh` |
| Old Go build path | Use deb install; or `OPENBAO_BUILD_FROM_SOURCE=1` for automation helper |
