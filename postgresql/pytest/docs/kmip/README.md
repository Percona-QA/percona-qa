# KMIP documentation — start here

All KMIP guides for **pg_tde pytest** live in this folder. Each filename states
**who it is for** and **what you do with it**.

---

## Pick your path

| I want to… | Read this |
|------------|-----------|
| Run KMIP tests locally (Cosmian, default CI path) | **[quickstart.md](quickstart.md)** |
| Set up **Fortanix DSM** and run pytest against it | **[vendor-lab-fortanix.md](vendor-lab-fortanix.md)** |
| Sign off a vendor KMS after pg_tde / libkmip changes | **[vendor-signoff.md](vendor-signoff.md)** |
| Understand CI vs vendor-lab testing (why Cosmian in CI) | **[ci-strategy.md](ci-strategy.md)** |
| Find which pytest file covers which KMIP scenario | **[test-catalog.md](test-catalog.md)** |
| Run deep / corner-case tests in `test_kmip.py` | **[advanced-scenarios.md](advanced-scenarios.md)** |
| Debug HashiCorp Vault **KMIP engine** (Register -2) | **[vault-kmip-engine.md](vault-kmip-engine.md)** |
| Compare KMIP vs Vault KV vs file keyring layouts | [../key_provider_matrix.md](../key_provider_matrix.md) |

---

## Document map

| File | Audience | Purpose |
|------|----------|---------|
| **[quickstart.md](quickstart.md)** | Developer / CI | Install Cosmian, env vars, `./scripts/run_kmip_matrix.sh`, troubleshooting |
| **[vendor-lab-fortanix.md](vendor-lab-fortanix.md)** | QA lab engineer | Fortanix trial account, certs, TLS, pg_tde SQL, Fortanix pytest profile |
| **[vendor-signoff.md](vendor-signoff.md)** | Release QA | Per-vendor revalidation checklist (Fortanix, Thales, Akeyless, …) |
| **[ci-strategy.md](ci-strategy.md)** | Engineering / Jenkins | Why Cosmian in every build; when to run vendor matrix |
| **[test-catalog.md](test-catalog.md)** | QA / onboarding | Full inventory of KMIP test modules and commands |
| **[advanced-scenarios.md](advanced-scenarios.md)** | Deep regression | Class-by-class map of `tests/test_kmip.py` |
| **[vault-kmip-engine.md](vault-kmip-engine.md)** | Vault Enterprise lab | Vault KMIP secrets engine — **not** production Vault KV v2 |

---

## Quick commands

**Default (Cosmian — no vendor license):**

```bash
cd postgresql/pytest
source .env.sh
source scripts/setup_cosmian_for_pytest.sh
./scripts/run_kmip_matrix.sh
```

**Fortanix (after [vendor-lab-fortanix.md](vendor-lab-fortanix.md)):**

```bash
source ~/fortanix_kmip_pytest.env
KMIP_PROFILE=fortanix ./scripts/run_kmip_matrix.sh
```

**Vault KMIP engine (after [vault-kmip-engine.md](vault-kmip-engine.md)):**

```bash
source /tmp/vault_kmip_pytest.env
KMIP_PROFILE=vault_kmip ./scripts/run_kmip_matrix.sh
```

---

## Related (outside this folder)

| Topic | Location |
|-------|----------|
| HashiCorp Vault **KV v2** (production path) | [../vault.md](../vault.md) |
| Key provider test layout (KMIP + Vault + file) | [../key_provider_matrix.md](../key_provider_matrix.md) |
| Profile env template | [../../config/kmip_profiles.example.env](../../config/kmip_profiles.example.env) |

---

## Legacy filenames

Older links used generic names (`kmip.md`, `kmip_revalidation.md`, …). Stub
redirects remain at `docs/kmip*.md` and `docs/vault_kmip.md` pointing here.
