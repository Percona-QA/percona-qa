# RQG Grammar Kit — `VECTOR_DISTANCE` / `DISTANCE` Fuzz Testing

Two files, meant to be dropped into your own RQG checkout:

- `vector_distance.yy` — the query grammar
- `vector_distance.zz` — a minimal companion gendata file

## Where to put them

```
<your-randgen-checkout>/conf/vector_distance/vector_distance.yy
<your-randgen-checkout>/conf/vector_distance/vector_distance.zz
```

## Syntax basis

This grammar's syntax was aligned against `conf/examples/example.yy` from your actual checkout, which confirmed:
- Rules are semicolon-terminated (`... ;`)
- Alternatives are `|`-separated, and may span multiple lines
- Underscore-prefixed tokens (`_table`, `_field`, `_digit`) are RQG's built-in generators, tied to whatever `--gendata` builds

Since this grammar needs `VECTOR`-typed columns (which `--gendata`'s built-in generator doesn't produce), it defines its own literal table (`vt`) with explicit columns in `query_init`, rather than using `_table`/`_field`. This is consistent with how `example.yy` itself falls back to literal SQL identifiers where the built-in generators don't fit.

One thing I could not confirm from the reference file: `example.yy` uses a bare `digit` token (no underscore) once, which isn't defined locally — it likely resolves via a base rule bundled elsewhere in your RQG's grammar library. This grammar avoids relying on that same undocumented behavior and sticks to confirmed tokens (`_digit`, etc.) throughout.

## How to run it

```bash
perl runall-new.pl \
  --basedir=<percona-server-basedir> \
  --grammar=conf/vector_distance/vector_distance.yy \
  --gendata=conf/vector_distance/vector_distance.zz \
  --post-gendata-sql=$PWD/conf/vector_distance/init_vectors.sql \
  --threads=4 \
  --queries=50000 \
  --duration=600 \
  --reporter=Shutdown,Backtrace,ErrorLog,QueryTimeout
```

Start conservative (`--threads=1`, a few thousand `--queries`) on a first run to confirm the grammar parses cleanly and the schema builds correctly, before scaling up to a longer stress run.

## What this grammar covers

Every rule maps to something already confirmed by hand in our manual testing session, so this grammar's real job is **regression coverage at scale** — running thousands of randomized variations of the same confirmed behaviors, across random data, to catch anything that only shows up under volume, concurrency, or unusual literal values.

| Grammar rule | Maps to | What a failure here would mean |
|---|---|---|
| `select_valid` | Phase 1 correctness (F-7, F-8, F-9, F-10, F-11) | A metric computed a wrong value, or errored on valid input |
| `select_ranking` | Phase 2/3 ranking tests | Ranking crashed, hung, or produced inconsistent ordering |
| `select_synonym_pair` | Section 7.1 (synonym equivalence) | `DISTANCE` and `VECTOR_DISTANCE` diverged on some input |
| `select_error_arity` | F-1 | Wrong arity didn't error, or the error code changed |
| `select_error_type` | F-2 | A non-vector type didn't error, or errored differently |
| `select_error_metric` | F-3 | An invalid/computed/NULL metric argument was silently accepted |
| `select_error_dimension` | F-5 | Mismatched dimensions didn't error (or crashed instead of erroring cleanly) |
| `select_error_bytelen` | F-6 | Malformed byte-length input didn't error, or crashed |
| `select_null_propagation` | F-4 | NULL input didn't propagate to a NULL result |
| `select_zero_vector_cosine` | F-9 zero-norm case | Cosine on a zero vector didn't return NULL, or crashed instead |
| `select_metadata_check` | F-13/F-14 | `CREATE TABLE ... SELECT` produced an unexpected column type |
| `select_aggregate` / `select_where_threshold` | New coverage | `VECTOR_DISTANCE` used inside `GROUP BY`/`WHERE` — not manually tested yet; this grammar is the first coverage of that combination |

The three vector widths (`v3`, `v8`, `v384`) are deliberate — `v384` matches a realistic embedding dimension (e.g. `all-MiniLM-L6-v2`), while `v3`/`v8` keep small cases in the mix for cheap, fast iterations and easier failure reproduction.

## Extending this further

- **Add `EUCLIDEAN_SQUARED` rank-order cross-checks at scale**: add a rule that runs the same `ORDER BY` query twice (once per metric) and use an RQG **Validator** (e.g. a custom one, or `ResultsetComparator`-style logic) to diff the returned row order automatically — this automates Section 7.2 rather than checking by eye.
- **Add a Transformer** to automatically re-run every generated query through both `DISTANCE` and `VECTOR_DISTANCE` and diff results — turns the manual synonym-equivalence check into a standing regression gate rather than a one-off test.
- **Widen `_bad_byte_literal`** with more boundary values (6, 7, 9, 10 bytes) if you want denser coverage of the "not a multiple of 4" boundary.
- **Add a vector-index variant**: duplicate the grammar, add `CREATE VECTOR INDEX ...` (syntax depends on your Percona build) in `query_init`, and compare result sets against this index-free version — this is the SQL-level way to automate the exact-vs-ANN question (TC23) we flagged as still open in the manual testing report.
- **Feed real embeddings instead of random floats**: replace the `_vector384` Perl block with logic that reads from a pre-generated file of real sentence-embedding vectors (e.g. the ones from the earlier semantic-ranking test kit), if you want the fuzzer exercising realistic embedding distributions rather than uniform random floats.

## Remaining uncertainty

Two things I still can't confirm without running this against your actual checkout:
- Whether `{ perl }` embedded-code blocks (used here to generate random vector literals for `_vector3`/`_vector8`/`_vector384`) are supported the same way in your specific RQG version — this is a long-standing, widely-used RQG feature, but I only had `example.yy` to check against, and that file doesn't use one.
- Whether `query_init` behaves as "runs once before the query loop" in your version — this is standard RQG behavior across forks, but again wasn't visible in the one reference file available.

If either turns out not to work as expected on a first test run, the fix is usually small (e.g. replacing the `{ perl }` vector-literal generation with a fixed pool of pre-written literal alternatives, `'[1,2,3]' | '[4,5,6]' | ...`, which sacrifices randomness in the vector *contents* but keeps everything else in the grammar working).
