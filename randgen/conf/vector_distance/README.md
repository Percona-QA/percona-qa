# RQG Grammar Kit — `VECTOR_DISTANCE` / `DISTANCE` Fuzz Testing

Files in this directory:

- `vector_distance.yy` — the query grammar
- `vector_distance.zz` — a minimal companion gendata file
- `init_vectors.sql` — creates and populates the `VECTOR`-typed schema (`test.vt`)

## Layout

```
randgen/conf/vector_distance/vector_distance.yy
randgen/conf/vector_distance/vector_distance.zz
randgen/conf/vector_distance/init_vectors.sql
```

## Syntax basis

Grammar syntax follows `conf/examples/example.yy`:

- Rules are semicolon-terminated (`... ;`)
- Alternatives are `|`-separated and may span multiple lines
- Underscore-prefixed tokens (`_table`, `_field`, `_digit`) are RQG built-in generators tied to `--gendata`

RQG's built-in gendata generator cannot declare `VECTOR(n)` columns, so the `vt` table is created and populated by `init_vectors.sql` (passed via `--post-gendata-sql`) rather than by `--gendata` or a `query_init` rule. The grammar then references `vt` and its columns by literal name instead of `_table`/`_field`.

This grammar uses confirmed RQG tokens (`_digit`, etc.) and does not rely on undocumented bare tokens such as `digit`.

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

Start with a conservative first run (`--threads=1`, a few thousand `--queries`) to confirm the grammar parses and the schema builds correctly before scaling up.

## What this grammar covers

Rules provide regression coverage at scale for VECTOR_DISTANCE / DISTANCE behaviors across randomized inputs, concurrency, and unusual literal values.

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
| `select_aggregate` / `select_where_threshold` | Aggregate / filter coverage | `VECTOR_DISTANCE` used inside `GROUP BY`/`WHERE` |

The three vector widths (`v3`, `v8`, `v384`) are intentional: `v384` matches a realistic embedding dimension (e.g. `all-MiniLM-L6-v2`), while `v3`/`v8` keep small cases available for faster iteration and easier failure reproduction.
