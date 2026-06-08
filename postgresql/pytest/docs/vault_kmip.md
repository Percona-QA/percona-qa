# HashiCorp Vault KMIP engine — pytest regression

## Customer issue

Users configuring pg_tde with **HashiCorp Vault via the KMIP secrets engine** (not
Vault KV v2) may see:

```sql
SELECT pg_tde_create_key_using_global_key_provider(
    'kmip-key-12012025',
    'kmip-provider-1'
);
```

```text
ERROR:  KMIP server reported error on register symmetric key: -2
```

Percona documents **Vault KV v2** for HashiCorp production use. The KMIP engine is
a separate integration surface; these tests track compatibility and regressions.

## Tests

| Test | Purpose |
|------|---------|
| `test_vault_kmip_add_global_provider_connects` | `add_global_key_provider_kmip` / TLS validate |
| `test_vault_kmip_create_key_register_symmetric_key_customer_repro` | Customer `create_key` SQL |

File: `tests/test_vault_kmip.py`  
Markers: `kmip`, `vault_kmip`, `bug`

**Default behaviour:** if Register fails with **-2**, the test **xfails** (known issue).
After engineering fixes the stack:

```bash
export VAULT_KMIP_REQUIRE_REGISTER_SUCCESS=1
pytest tests/test_vault_kmip.py -v
```

## Setup (lab)

Requires **Vault Enterprise** with the KMIP secrets engine.

```bash
cd postgresql/pytest
source .env.sh

# Vault API (KV tests use the same server)
source scripts/setup_vault_for_pytest.sh

# KMIP listener + client certs → KMIP_VAULT_*
source scripts/setup_vault_kmip_for_pytest.sh

pytest tests/test_vault_kmip.py -v
```

Manual / HCP Vault: export `KMIP_VAULT_*` from your environment (see
`config/kmip_profiles.example.env`) and run pytest in the same shell.

## Environment

| Variable | Meaning |
|----------|---------|
| `KMIP_VAULT_HOST` | KMIP listener host (often `127.0.0.1`) |
| `KMIP_VAULT_PORT` | Default `5696` |
| `KMIP_VAULT_CLIENT_CERT` | Client certificate PEM |
| `KMIP_VAULT_CLIENT_KEY` | Client private key PEM |
| `KMIP_VAULT_SERVER_CA` | Vault KMIP CA chain PEM |
| `VAULT_KMIP_TEST_PROVIDER_NAME` | Default `kmip-provider-1` |
| `VAULT_KMIP_TEST_KEY_NAME` | Default `kmip-key-12012025` |
| `VAULT_KMIP_REQUIRE_REGISTER_SUCCESS` | If `1`, create_key must pass (no xfail) |
| `VAULT_KMIP_SCOPE` / `VAULT_KMIP_ROLE` | Vault KMIP scope/role for setup script |

## Related

- [vault.md](vault.md) — Vault KV v2 / OpenBao
- [kmip.md](kmip.md) — Cosmian and enterprise KMS revalidation matrix
- `lib/vault_kmip.py` — env helpers and error matching
