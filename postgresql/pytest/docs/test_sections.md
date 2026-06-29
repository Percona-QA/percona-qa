# Test sections (`--skip-sections`)

Skip whole feature areas when a release or environment does not support them
(e.g. no `pg_rewind` in the package). This is **explicit and user-controlled**;
the harness does not auto-skip based on missing binaries.

## Usage

```bash
cd postgresql/pytest && source .env.sh

# Skip pg_rewind / pg_tde_rewind tests (~67 tests)
pytest tests/ --skip-sections=rewind -v

# Several sections (comma- or space-separated)
pytest tests/ --skip-sections=rewind,upgrade,vault -v

# Same via environment (CLI overrides env)
export SKIP_SECTIONS=rewind,pgbackrest
pytest tests/ -v

# List section names and their markers
pytest --list-test-sections
```

## Available sections

| Section | Pytest marker(s) | Typical content |
|---------|------------------|-----------------|
| `rewind` | `rewind` | `test_tde_rewind_advanced.py` |
| `upgrade` | `upgrade` | `test_tde_pg_upgrade.py`, `test_upgrade.py` — [`docs/major_upgrade.md`](major_upgrade.md), full catalog [`docs/upgrade_matrix.md`](upgrade_matrix.md) |
| `minor_upgrade` | `minor_upgrade` | Staged in-place pg_tde bump — [`docs/minor_upgrade.md`](minor_upgrade.md), full catalog [`docs/upgrade_matrix.md`](upgrade_matrix.md) |
| `migration` | `migration` | `test_pdg_migration.py` |
| `encryption` | `encryption` | Core pg_tde SQL/API tests |
| `replication` | `replication` | `test_replication.py` |
| `backup` | `backup` | `test_pitr.py`, `test_pg_basebackup.py`, … |
| `recovery` | `recovery` | `test_recovery.py`, `test_unlogged_recovery.py` |
| `pgbackrest` | `pgbackrest` | `test_pgbackrest.py` |
| `vault` | `vault`, `openbao` | Vault/OpenBao (`tests/test_vault_providers.py`; see `docs/vault.md`) |
| `kmip` | `kmip` | KMIP provider tests — see [kmip/README.md](kmip/README.md) |
| `waldump` | `waldump` | `test_waldump.py` |
| `docker` | `docker` | Docker-dependent tests |
| `bug` | `bug` | `test_bug_reproduction.py` |
| `slow` | `slow` | Long-running tests (any file) |

## Aliases

| Alias | Maps to |
|-------|---------|
| `pg_rewind`, `pg_tde_rewind` | `rewind` |
| `pg_upgrade`, `pg-upgrade` | `upgrade` |
| `minor-upgrade` | `minor_upgrade` |

## Equivalents

```bash
pytest tests/ --skip-sections=rewind     # framework switch (preferred)
pytest tests/ -m "not rewind"            # pytest marker expression
```

Conditional skips (missing `--old-install-dir`, Vault, pgBackRest, etc.) are
unchanged and independent of `--skip-sections`.

## `io_method` / `io_uring` (build **and** system)

On PostgreSQL 18+, packages may include io_uring support while the **host** still
blocks it (low `memlock` for `ec2-user`, `kernel.io_uring_disabled=2`, etc.).

The harness checks:

1. **Build** — `initdb --set io_method=io_uring` succeeds  
2. **System** — `ulimit -l` unlimited (memlock) and `kernel.io_uring_disabled=0`

Manual setup: **`docs/io_uring_system_setup.md`** (limits.conf, sysctl, re-login).

```bash
# After system fixes, confirm from pytest directory:
python3 -c "
from pathlib import Path
from lib.cluster import io_uring_status_lines
for l in io_uring_status_lines(Path('$INSTALL_DIR')): print(l)
"

pytest tests/ --io-method-matrix -v   # includes io_uring only when both checks pass
pytest tests/ --io-method=io_uring -v
```
