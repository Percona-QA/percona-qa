# Key provider test matrix

Same **core scenarios** for every backend; **server-specific** regressions stay in
separate modules.

## Layout

| Layer | KMIP | Vault KV v2 | File keyring |
|-------|------|-------------|--------------|
| **Shared matrix** | `tests/test_kmip_common_matrix.py` | `tests/test_vault_kv_common_matrix.py` | `tests/test_file_keyring_common_matrix.py` |
| **Full checklist** | `tests/test_kmip_server_revalidation.py` | *(in common matrix)* | *(in common matrix)* |
| **Server-specific** | `tests/test_vault_kmip.py` (Vault KMIP engine Register -2) | `tests/test_vault_hashicorp_parity.py`, `tests/test_openbao_bash_parity.py` | `tests/test_encryption.py` (extended) |
| **Extended / Cosmian-only** | `tests/test_kmip.py` (bash parity, advanced) | — | — |

## KMIP profiles

Configure via ``KMIP_REVALIDATE_PROFILES`` (env) or ``--kmip-revalidate-profiles``:

| Profile | Env prefix | Server |
|---------|------------|--------|
| `cosmian` | `KMIP_COSMIAN_*` or `KMIP_*` after setup | Cosmian KMS (CI) |
| `vault_kmip` | `KMIP_VAULT_*` | HashiCorp Vault **KMIP engine** |
| `fortanix` | `KMIP_FORTANIX_*` | Fortanix DSM |
| `thales` | `KMIP_THALES_*` | Thales CipherTrust |
| `akeyless` | `KMIP_AKEYLESS_*` | Akeyless |

```bash
# Cosmian
source scripts/setup_cosmian_for_pytest.sh
./scripts/run_kmip_matrix.sh

# Your Vault Enterprise KMIP lab
source /tmp/vault_kmip_pytest.env
KMIP_REVALIDATE_PROFILES=vault_kmip ./scripts/run_kmip_matrix.sh

# One profile at a time in CI/Jenkins
export KMIP_REVALIDATE_PROFILES=fortanix
pytest tests/test_kmip_common_matrix.py tests/test_kmip_server_revalidation.py -v
```

Shared scenarios (per profile):

1. Global provider smoke + restart  
2. Key rotation  
3. Multi-DB file + KMIP  
4. Full checklist (revalidation module): DB-scoped provider, rotation, restart  

## Vault KV profiles

Configure via ``VAULT_KV_PROFILES`` or ``--vault-kv-profile``:

| Profile | When to use |
|---------|-------------|
| `hashicorp` | Root Vault, mount `secret`, no namespace |
| `hashicorp_enterprise` | Namespaced KV (`ns1/`, mount `pg_tde`) — **your lab** |
| `openbao` | OpenBao namespace + `pg_tde` mount |
| `auto` | Detect from `VAULT_NAMESPACE` / mount (default) |

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_NAMESPACE=ns1/
export VAULT_SECRET_MOUNT=pg_tde
export VAULT_TOKEN_FILE=/tmp/token_ent
export VAULT_KV_PROFILES=hashicorp_enterprise

./scripts/run_vault_kv_matrix.sh
```

Vault **KMIP engine** is not Vault KV — use `KMIP_REVALIDATE_PROFILES=vault_kmip`.

## File keyring

No external server — always runs:

```bash
pytest tests/test_file_keyring_common_matrix.py -v
```

## Run everything configured

```bash
./scripts/run_key_provider_matrix.sh
KEY_PROVIDER_MATRIX=kmip ./scripts/run_key_provider_matrix.sh
```

## Markers

| Marker | Meaning |
|--------|---------|
| `kmip_matrix` | Shared KMIP scenarios (all profiles) |
| `kmip_revalidation` | Full KMIP checklist |
| `vault_kv_matrix` | Shared Vault KV scenarios |
| `vault_kmip` | Vault KMIP engine **specific** tests |
| `file_keyring` | Local file provider matrix |
| `kmip` | Any KMIP-tagged test (includes matrix + extended) |
| `vault` | Any Vault-tagged test |

## Jenkins pattern

One job per backend, same pytest modules, different secrets:

```bash
# Job: kmip-cosmian
KMIP_REVALIDATE_PROFILES=cosmian ./scripts/run_kmip_matrix.sh

# Job: kmip-vault-enterprise
KMIP_REVALIDATE_PROFILES=vault_kmip ./scripts/run_kmip_matrix.sh

# Job: vault-kv-enterprise
VAULT_KV_PROFILES=hashicorp_enterprise ./scripts/run_vault_kv_matrix.sh

# Job: file-keyring (no secrets)
pytest tests/test_file_keyring_common_matrix.py -v
```

See also: [kmip_revalidation.md](kmip_revalidation.md), [vault.md](vault.md), [vault_kmip.md](vault_kmip.md).
