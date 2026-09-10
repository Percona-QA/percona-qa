# RQG Native Two-Server Comparison Mode

Source: https://github.com/RQG/RQG-Documentation/wiki/RandomQueryGeneratorComparison

RQG's built-in two-server comparison runs one grammar against two servers and
diffs the results via `ResultsetComparator`. For MySQL-family comparisons it
replaces a standalone cross-engine diff script and reduces the two-file
`--redefine` approach to a single grammar file.

## Comparison approaches

| | Custom Python script | `--redefine` (2 files) | Native comparison (this) |
|---|---|---|---|
| Runs both engines automatically | No — separate runs | No — separate runs | Yes, one command |
| Diffs results automatically | Custom code | Custom (none built-in) | Built-in `ResultsetComparator` |
| Auto-minimizes found bugs | No | No | Yes, via `ResultsetComparatorCrossDBSimplify` |
| Works cross-product (Postgres etc.) | Yes | No (MySQL-family only) | Yes, via `gentest.pl --dsn1/--dsn2/--dsn3` |
| Files needed | 1 script + config + cases | 2 grammar files | 1 grammar file |

**Recommendation:** use native comparison for MySQL-family engines (Percona vs
MariaDB, and HeatWave). Keep a custom Python path for pgvector: `gentest.pl`
can use a `dbi:Pg:...` DSN, but this grammar assumes MySQL-family syntax
(`auto_increment`, `STRING_TO_VECTOR`, etc.). Native mode does not remove the
dialect translation burden for a different SQL surface.

## Running it

```bash
perl runall-new.pl \
  --basedir1=/path/to/percona-server/bld \
  --basedir2=/path/to/mariadb-server/bld \
  --vardir1=/tmp/rqg_var_ps \
  --vardir2=/tmp/rqg_var_mdb \
  --grammar=conf/vector_distance/vector_distance_compare.yy \
  --gendata=conf/vector_distance/vector_distance.zz \
  --post-gendata-sql=conf/vector_distance/init_vectors_comp.sql \
  --threads=1 \
  --queries=10000 \
  --duration=300 \
  --reporter=Shutdown,Backtrace \
  --sqltrace
```

Prefer a MariaDB official tarball or build prefix as `--basedir2` (for example
`mariadb-*-linux-systemd-x86_64` with `bin/mariadbd`,
`scripts/mariadb-install-db`, and `share/.../errmsg.sys`). A raw distro
`--basedir2=/usr` is often awkward.

`runall-new.pl` detects MariaDB and initializes with `mariadb-install-db` /
`--bootstrap` instead of MySQL/Percona's `--initialize-insecure`.

After GenTest succeeds, `runall-new.pl` normally diffs `mysqldump` output from
both servers. If any server is MariaDB, that dump step is skipped
automatically: MariaDB dump preamble and `VECTOR` `--hex-blob` encoding are not
comparable to MySQL/Percona even when query results match.
`ResultsetComparator` remains the authoritative check. Use
`--skip-dump-compare` to force-skip dumps for MySQL/Percona-only dual-server
runs as well.

`--threads=1` is recommended for any workload that is not pure SELECT-only;
multi-threaded comparisons are prone to false positives from timing
differences. This grammar is read-only SELECTs against pre-loaded static data
(safe for multi-thread), but raising thread count adds little value for
correctness comparison versus load/concurrency testing.

For already-running servers, use `gentest.pl --dsn1=... --dsn2=...` instead of
`runall.pl --basedir1/2`.

## Syntax differences: `/*executorN ... */`

Dialect differences are inlined with RQG's `/*executor1 ... */` /
`/*executor2 ... */` convention instead of a separate redefine file. Content
inside an `/*executorN ... */` block is sent to server N only; the other server
treats it as an ordinary SQL comment. Both servers still see identical
equal-width literals from `_vector_3d` / `_vector_8d`, so only the
function-call wrapper differs:

```sql
SELECT id,
    FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
    _vector_3d , _vector_3d
    /*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
FROM vt WHERE id = _existing_id ;
```

Percona (executor1): `SELECT id, FLOOR(GREATEST(0, (VECTOR_DISTANCE( <a> , <b> , 'EUCLIDEAN' ))) * 10) / 10 AS d FROM vt WHERE id = <n> ;`

MariaDB (executor2): `SELECT id, FLOOR(GREATEST(0, (VEC_DISTANCE_EUCLIDEAN( <a> , <b> ))) * 10) / 10 AS d FROM vt WHERE id = <n> ;`

A `ResultsetComparator` mismatch on such a query means both engines computed
the same distance metric on the same data through native syntax and returned
different answers.

## Scope of `vector_distance_compare.yy`

Restricted to shared happy-path coverage:

- Metrics with confirmed MariaDB names: `EUCLIDEAN`, `COSINE`
  (`VEC_DISTANCE_EUCLIDEAN` / `VEC_DISTANCE_COSINE`)
- Equal dimensions only (3d/3d, 4d/4d, 8d/8d, 384d/384d) via `_vector_3d` /
  `_vector_8d` and matching column pairs
- Float distances emitted as `FLOOR(GREATEST(0, dist) * 10) / 10` (one
  decimal). Coarser than cent-level truncation to absorb float32 ULP noise
  that still flipped `0.01` bins (for example `72.7` vs `72.71`); `GREATEST`
  clamps tiny negative cosine float noise
- High-signal integer/boolean checks: relative closer-anomaly order,
  Euclidean/Cosine order agreement, commutativity flags, CASE buckets,
  self-distance-is-zero, UNION lookups, subquery distance filters
- Ranking / top-k without raw floats in the SELECT list
- NULL propagation where both engines return NULL (both EUCLIDEAN and COSINE)
- Modern SQL surface: window functions (`RANK() OVER (ORDER BY ...)`), CTEs
  (`WITH ... AS`), self-joins and correlated-subquery nearest-neighbor lookups
  -- these compute distance column-to-column via a join instead of
  column-vs-literal, which is a distinct code path from every other query in
  this grammar
- `>=`, `!=`, `IS NOT NULL` predicates and `DISTINCT` over a distance
  expression (previously only `<` and `BETWEEN` were covered)
- Precision at large magnitude (self-distance-is-zero for identical literals
  scaled to 1e6..1e12), complementing the existing near-zero check

Intentionally excluded (known or expected divergence / Percona-only paths):

- Cosine vs zero vector
- Dimension mismatch, wrong arity/type
- Percona-only metrics (`DOT`, `MANHATTAN`) and the `DISTANCE` synonym

Extend with additional metrics only after MariaDB function names are verified
on the target build. Do not invent function names: a missing function can make
both servers fail for unrelated reasons, which `ResultsetComparator` may report
as "both errored, no mismatch" without testing meaningful behavior.

When triageing mismatches: prefer integer/boolean column diffs. A lone
`±0.1` gap on a truncated float column can still be residual IEEE noise.

## Auto-minimizing a mismatch: `ResultsetComparatorCrossDBSimplify`

RQG's stock `ResultsetComparatorSimplify` validator does **not** work for any
grammar built on `/*executorN ... */` dialect tags, including this one. Its
shrinking oracle re-sends `$results->[0]->query()` -- the query text already
resolved to executor 0's own dialect (its own tag unwrapped, every other
executor's tag stripped) -- to *every* executor, including executor 2. That
is correct only when both servers share one SQL dialect. As soon as the two
sides genuinely differ (any grammar comparing two engines that each spell a
feature with their own function name/syntax), sending executor 0's resolved
text to executor 1 verbatim fails outright -- typically a "function/procedure
does not exist" or syntax error from the second server. `simplify()` then
aborts on its very first check with *"Could not simplify failure, appears to
be sporadic"*, without ever attempting a single reduction, no matter how
reproducible the mismatch actually is.

`ResultsetComparatorCrossDBSimplify` (`lib/GenTest/Validator/ResultsetComparatorCrossDBSimplify.pm`)
is a fork of that validator for this general case: it simplifies each
executor's own query against its own baseline result, so it never sends one
server's SQL to another. It logs a separately-minimized query per executor
instead of one shared text, since the two dialects' minimal reproducers are
not expected to be textually identical.

It is not specific to this grammar -- use it for any RQG dual/multi-server
comparison where the executors are different database engines or dialects,
not just this one.

Known limitation it does **not** fix: the SQL parser
`GenTest::Simplifier::SQL` uses to build a prunable tree (`DBIx::MyParsePP`)
predates window functions and CTEs, so it cannot parse `RANK() OVER (...)` or
`WITH ... AS (...)` at all. A mismatch on `select_window_rank` or
`select_cte_filter` will still fail to simplify with this validator too --
triage those by hand from the plain mismatch report instead.

Example -- rerun a targeted, low-volume pass with it once a mismatch is
suspected (it runs extra queries against both servers per candidate
reduction, so avoid it on a long high-volume run):

```bash
perl runall-new.pl \
  --basedir1=/path/to/percona-server/bld \
  --basedir2=/path/to/mariadb-server/bld \
  --vardir1=/tmp/rqg_var_ps \
  --vardir2=/tmp/rqg_var_mdb \
  --grammar=conf/vector_distance/vector_distance_compare.yy \
  --gendata=conf/vector_distance/vector_distance.zz \
  --post-gendata-sql=conf/vector_distance/init_vectors_comp.sql \
  --threads=1 \
  --queries=2000 \
  --duration=120 \
  --validators=ResultsetComparatorCrossDBSimplify \
  --sqltrace
```

Or against already-running servers, with `gentest.pl --dsn1=/--dsn2=`:

```bash
perl gentest.pl \
  --dsn1="dbi:mysql:host=127.0.0.1:port=<ps_port>:user=root:database=test" \
  --dsn2="dbi:mysql:host=127.0.0.1:port=<mdb_port>:user=root:database=test" \
  --grammar=conf/vector_distance/vector_distance_compare.yy \
  --threads=1 \
  --queries=2000 \
  --duration=120 \
  --validators=ResultsetComparatorCrossDBSimplify
```

## Interpreting output

- Any `ResultsetComparator` mismatch report is the primary signal.
- Exit status: GenTest `STATUS_OK (0)` is the success criterion. Runs that
  include MariaDB log that dump comparison was skipped; a missing dump diff is
  not a failure.
- For automatic bug minimization, add `--validators=ResultsetComparatorCrossDBSimplify`
  (see above) -- not the stock `ResultsetComparatorSimplify`, which cannot
  simplify a genuinely cross-dialect mismatch on this grammar.
