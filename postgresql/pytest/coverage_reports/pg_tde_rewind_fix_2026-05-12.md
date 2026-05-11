# pg_tde Rewind Fix — Test Coverage Validation Report

**Date:** 2026-05-12
**Trigger:** Andrew's latest commit on the pg_tde branch fixing `pg_tde_rewind` semantics.
**Test file:** `pytest/tests/test_tde_rewind_advanced.py`

---

## Summary

| Metric | Before fix | After fix |
|---|---|---|
| Total pg_tde_rewind scenarios | 54 | 54 |
| Passed | 38 | **54** |
| **Failed** | **16** | **0** |
| Pass rate | 70 % | **100 %** |

All 16 previously failing scenarios now pass on Andrew's branch. The fix
addresses correctness of `pg_tde_rewind` across the full pg_tde feature
matrix — TOAST, partitioning, indexes, key rotation, WAL encryption,
multi-database setups, and full HA failback cycles.

---

## Failure → fix mapping

The 16 fixed tests cluster into seven semantic groups. Each group exercises
a different pg_tde × pg_rewind interaction that was broken before the fix.

### 1. TOAST and partitioning (`TestTdeRewindExtended`) — 4 tests

| Test | What it exercises |
|---|---|
| `test_rewind_after_toast_heavy_workload` | TOAST-heavy diverged data (≈32 KB rows from `repeat(md5, 1000)`) — `pg_tde_rewind` must handle large encrypted TOAST pages |
| `test_rewind_after_partitioned_table_workload` | RANGE-partitioned `tde_heap` table with two partitions + 10 k rows created post-promotion |
| `test_rewind_after_partial_and_expression_indexes` | Partial (`WHERE id > 100`) and expression (`(id*2)`) indexes on diverged side |
| `test_rewind_after_wal_pressure` | 200 k-row bulk INSERT followed by CHECKPOINT — high WAL pressure scenario |

### 2. Checkpoint + large workload (`TestTdeRewindWithCheckpoint`) — 1 test

| Test | What it exercises |
|---|---|
| `test_rewind_large_insert_workload_after_checkpoint` | 100-table sysbench-style insert prepare on primary, CHECKPOINT, promote standby, then long divergence workload before rewind |

### 3. Source-side state preservation (`TestTdeRewindRandomized`) — 2 tests

| Test | What it exercises |
|---|---|
| `test_rewind_target_only_table_is_preserved` | A table created on the **promoted standby (rewind source)** must survive — rewind synchronises target → source |
| `test_rewind_minimal_divergence` | Single INSERT + CHECKPOINT — fast-path rewind where minimal WAL replay is needed |

### 4. WAL encryption (`TestTdeRewindWalEncryption`) — 1 test

| Test | What it exercises |
|---|---|
| `test_rewind_wal_key_overlap_when_target_segments_are_kept` | Encrypted WAL + rewind where the target retains tail segments — must handle overlapping WAL key generations |

### 5. Full HA failback (`TestTdeRewindFullHaCycle`) — 1 test

| Test | What it exercises |
|---|---|
| `test_rewind_then_reconnect_as_standby` | End-to-end failback: promote → rewind old primary → reattach as standby of new primary → assert replication resumes + data is consistent |

### 6. Multi-tenant key providers (`TestTdeRewindKeyProviderEdges`) — 1 test

| Test | What it exercises |
|---|---|
| `test_rewind_multiple_databases_different_keys` | Two databases each with their own database-level principal key — both must remain queryable after divergence on db2 and rewind |

### 7. Schema complexity on `tde_heap` (`TestTdeRewindDataStructures`) — 2 tests

| Test | What it exercises |
|---|---|
| `test_rewind_with_gist_index_on_tde_heap` | GiST index on a `tsvector` column in a tde_heap table |
| `test_rewind_with_foreign_key_cascade` | Parent/child FK with `ON DELETE CASCADE` between two tde_heap tables — must remain enforced post-rewind |

### 8. High-volume relfilenode churn (`TestTdeRewindMultiRound`) — 4 tests

| Test | What it exercises |
|---|---|
| `test_rewind_ddl_storm_divergence` | 50 × CREATE TABLE + DROP TABLE on diverged server — large number of relfilenode creations/deletions in WAL |
| `test_rewind_large_number_of_tde_heap_files` | 200 tde_heap tables on diverged server — hundreds of encrypted heap files must sync correctly |
| `test_rewind_with_wal_encryption_multi_key_rotation` | Server key rotated 5× on the diverged server with WAL encryption active — multiple key generations in `pg_tde/` |
| `test_rewind_then_promote_again` | Full HA cycle: promote → rewind → reconnect as standby → **promote again** — second promotion must produce a valid primary with all data intact |

---

## Failure signatures (before the fix)

Most failures surfaced as `psql failed` (port=NNNNN) — the rewound target
could not be started or could not serve queries — except for two that
failed at the rewind step itself:

| Test | Failure point | Signature |
|---|---|---|
| `test_rewind_with_wal_encryption_multi_key_rotation` | `pg_tde_rewind` invocation | `AssertionError: pg_tde_rewind: servers diverged at WAL location 0/5020D10 on timeline 1` |
| `test_rewind_then_promote_again` | `pg_tde_rewind` invocation | `AssertionError: pg_tde_rewind: servers diverged at WAL location 0/3020CE8 on timeline 1` |

These two were the most diagnostic — `pg_tde_rewind` declared divergence
at a point where the actual on-disk state should have allowed
synchronisation. Andrew's fix repairs the divergence detection and the
subsequent block-level copy across all 16 scenarios.

---

## What the fix verifies in production-shape terms

After Andrew's fix, `pg_tde_rewind` is verified to handle:

- **Large encrypted payloads** — TOAST, GiST tsvector, partitioned tables
- **Index variants on `tde_heap`** — partial, expression, GiST, primary key, foreign key
- **High-churn DDL** — DDL storms with relfilenode creations/deletions
- **Many encrypted files** — 200 tde_heap tables sync cleanly
- **WAL key generations** — multiple server-key rotations during divergence
- **Multi-database keys** — per-database key providers survive rewind
- **Full HA cycles** — promote / rewind / reattach / promote-again all complete
- **Edge cases** — minimal divergence (fast path), CHECKPOINT-after-promote ordering, WAL pressure

---

## How to reproduce these results

```bash
source ~/pgwork/pg_env.sh
cd ~/pgwork/percona-qa/postgresql/pytest
source .env.sh

# Run the rewind suite
pytest tests/test_tde_rewind_advanced.py -v --tb=short 2>&1 | tee /tmp/rewind_run.log

# Count results
grep -E "passed|failed" /tmp/rewind_run.log | tail -5
```

**Expected outcome on Andrew's branch:** all 54 tests pass.

Compare against the previous build:

```bash
# Switch to pre-fix commit
cd ~/pgwork/postgres
git checkout <previous-commit>
git submodule update --init --recursive
bash ~/pgwork/percona-qa/postgresql/build_from_source.sh --tde-only

# Re-run — expect the 16 listed failures
pytest tests/test_tde_rewind_advanced.py -v 2>&1 | tee /tmp/rewind_prev.log
diff <(grep "FAILED\|PASSED" /tmp/rewind_run.log | sort) \
     <(grep "FAILED\|PASSED" /tmp/rewind_prev.log | sort)
```

---

## Full list of fixed tests

For convenience when pasting into the merge commit, PR description, or
release notes:

```
TestTdeRewindExtended::test_rewind_after_toast_heavy_workload
TestTdeRewindExtended::test_rewind_after_partitioned_table_workload
TestTdeRewindExtended::test_rewind_after_partial_and_expression_indexes
TestTdeRewindExtended::test_rewind_after_wal_pressure
TestTdeRewindWithCheckpoint::test_rewind_large_insert_workload_after_checkpoint
TestTdeRewindRandomized::test_rewind_target_only_table_is_preserved
TestTdeRewindRandomized::test_rewind_minimal_divergence
TestTdeRewindWalEncryption::test_rewind_wal_key_overlap_when_target_segments_are_kept
TestTdeRewindFullHaCycle::test_rewind_then_reconnect_as_standby
TestTdeRewindKeyProviderEdges::test_rewind_multiple_databases_different_keys
TestTdeRewindDataStructures::test_rewind_with_gist_index_on_tde_heap
TestTdeRewindDataStructures::test_rewind_with_foreign_key_cascade
TestTdeRewindMultiRound::test_rewind_ddl_storm_divergence
TestTdeRewindMultiRound::test_rewind_large_number_of_tde_heap_files
TestTdeRewindMultiRound::test_rewind_with_wal_encryption_multi_key_rotation
TestTdeRewindMultiRound::test_rewind_then_promote_again
```

---

*Generated against `tests/test_tde_rewind_advanced.py`. Save additional
runs to `pytest/coverage_reports/` for week-over-week comparison.*
