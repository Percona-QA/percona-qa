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
| `upgrade` | `upgrade` | `test_tde_pg_upgrade.py`, `test_upgrade.py` |
| `minor_upgrade` | `minor_upgrade` | Staged in-place pg_tde bump (`test_tde_minor_upgrade.py`) |
| `migration` | `migration` | `test_pdg_migration.py` |
| `encryption` | `encryption` | Core pg_tde SQL/API tests |
| `replication` | `replication` | `test_replication.py` |
| `backup` | `backup` | `test_pitr.py`, `test_pg_basebackup.py`, … |
| `recovery` | `recovery` | `test_recovery.py`, `test_unlogged_recovery.py` |
| `pgbackrest` | `pgbackrest` | `test_pgbackrest.py` |
| `vault` | `vault` | Vault/OpenBao provider tests |
| `kmip` | `kmip` | KMIP provider tests |
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
