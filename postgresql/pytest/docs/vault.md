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
| `tests/test_vault_providers.py::TestOpenBaoKeyProvider` | `vault`, `openbao` | `setup_openbao.sh` (+ KMIP for some tests) |

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

## OpenBao (namespace tests)

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_openbao_for_pytest.sh
# Scenarios 2–3 also need KMIP:
source scripts/setup_kmip_for_pytest.sh

pytest tests/test_vault_providers.py::TestOpenBaoKeyProvider -v
```

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
source scripts/setup_kmip_for_pytest.sh
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
2. **openbao** — `setup_openbao_for_pytest.sh` (+ KMIP if running full OpenBao suite), then `pytest -m openbao`.

Do not mix Vault SSL URLs with the Docker dev server without matching `VAULT_CA_PATH`.
