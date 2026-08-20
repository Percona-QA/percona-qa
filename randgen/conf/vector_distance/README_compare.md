# Using RQG's Native Two-Server Comparison Mode

Source: https://github.com/RQG/RQG-Documentation/wiki/RandomQueryGeneratorComparison

This is RQG's own built-in mechanism for exactly what we've been building
manually -- running one grammar against two servers and diffing the
results. It replaces the need for the standalone `cross_engine_diff.py`
script (for MySQL-family comparisons specifically) and simplifies the
two-file `--redefine` approach down to one file.

## How it differs from what we built earlier

| | Custom Python script | `--redefine` (2 files) | Native comparison (this) |
|---|---|---|---|
| Runs both engines automatically | No -- separate runs | No -- separate runs | **Yes, one command** |
| Diffs results automatically | Custom code | Custom (none built) | **Built-in `ResultsetComparator`** |
| Auto-minimizes found bugs | No | No | **Yes, via `ResultsetComparatorSimplify`** |
| Works cross-product (Postgres etc.) | Yes (that's what it's for) | No (MySQL-family only) | Yes, via `gentest.pl --dsn1/--dsn2/--dsn3` |
| Files needed | 1 script + config + cases | 2 grammar files | **1 grammar file** |

Given this, the recommendation is: **use native comparison mode for
MySQL-family engines (Percona vs MariaDB, and HeatWave too)**, and keep the
Python script only for pgvector, since `gentest.pl` can technically reach
Postgres via a `dbi:Pg:...` DSN but the whole grammar dialect (auto_increment,
`STRING_TO_VECTOR`, etc.) still assumes MySQL-family syntax throughout --
native mode doesn't remove that translation burden for a genuinely
different SQL dialect, only for two engines that already share most of
their SQL surface.

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

Prefer a MariaDB **official tarball or build prefix** as `--basedir2` (e.g.
`mariadb-*-linux-systemd-x86_64` with `bin/mariadbd`, `scripts/mariadb-install-db`,
and `share/.../errmsg.sys`). A raw distro `--basedir2=/usr` is often awkward.

`runall-new.pl` detects MariaDB and initializes with `mariadb-install-db` /
`--bootstrap` instead of MySQL/Percona's `--initialize-insecure`.

After GenTest succeeds, `runall-new.pl` normally diffs `mysqldump` output from
both servers. If **any server is MariaDB**, that dump step is **skipped
automatically**: MariaDB dump preamble and `VECTOR` `--hex-blob` encoding are
not comparable to MySQL/Percona even when query results match.
`ResultsetComparator` remains the authoritative check. Use
`--skip-dump-compare` to force-skip dumps for MySQL/Percona-only dual-server
runs too.

`--threads=1` is a hard recommendation from the docs for any workload that
isn't pure SELECT-only -- multi-threaded comparisons are prone to false
positives from timing differences. Since this grammar is entirely
read-only SELECTs against pre-loaded static data, you're in the safe case,
but there's no real benefit to raising thread count here anyway since the
goal is correctness comparison, not load/concurrency testing.

If your servers are already running rather than started by RQG itself, use
`gentest.pl --dsn1=... --dsn2=...` instead of `runall.pl --basedir1/2`.

## How the syntax difference is handled: `/*executorN ... */`

Instead of a separate redefine file overriding whole rules, the syntax
difference is now inlined directly in the query text using RQG's
`/*executor1 ... */` / `/*executor2 ... */` comment convention. Content
inside an `/*executorN ... */` block is sent to server N only -- the other
server treats it as an ordinary SQL comment and ignores it entirely. Since
both servers still see the identical `_vector_source`-generated literals,
the actual data being compared is guaranteed identical -- only the
function-call wrapper differs:

```sql
SELECT id,
    /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
    _vector_source , _vector_source
    /*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
    AS d
FROM vt WHERE id = _existing_id ;
```
Percona (executor1) receives: `SELECT id, VECTOR_DISTANCE( <a> , <b> , 'EUCLIDEAN' ) AS d FROM vt WHERE id = <n> ;`
MariaDB (executor2) receives: `SELECT id, VEC_DISTANCE_EUCLIDEAN( <a> , <b> ) AS d FROM vt WHERE id = <n> ;`

If `ResultsetComparator` reports a mismatch on one of these, that's now a
genuinely meaningful finding -- both engines were asked to compute the same
distance metric on the same data, through their own native syntax, and got
different answers.

## Scope of `vector_distance_compare.yy`

Deliberately restricted to `EUCLIDEAN` and `COSINE` only -- the two metrics
with a confirmed MariaDB function name
(`VEC_DISTANCE_EUCLIDEAN`/`VEC_DISTANCE_COSINE`). Extend this the same way
as the `--redefine` file once `EUCLIDEAN_SQUARED`/`DOT`/`MANHATTAN`
equivalents are confirmed by hand on your MariaDB build -- don't guess at
function names here either, for the same reason noted in the earlier
`--redefine` files: a guessed function name that doesn't exist would
produce two servers failing for unrelated reasons, which `ResultsetComparator`
might report as "both errored, no mismatch" even though nothing meaningful
was actually tested.

Note also: `_vector_source` includes both 3-dim (`v3`, `STRING_TO_VECTOR(_vector3)`)
and 8-dim (`v8`, `STRING_TO_VECTOR(_vector8)`) alternatives, and
`select_valid` picks it independently for both arguments -- meaning it can
occasionally generate a genuine dimension mismatch (e.g. `v3` vs `v8`) on
both sides. This isn't a bug: it's useful additional coverage, since
`ResultsetComparator` also compares error codes, not just successful
results, so a dimension-mismatch case tells you whether both engines treat
that condition the same way, not just whether their happy-path math agrees.

## What to watch for in the output

- **Any `ResultsetComparator` mismatch report** -- the primary signal.
- **Exit status** -- GenTest `STATUS_OK (0)` is the success criterion for
  this suite. Runs that include MariaDB log that dump comparison was
  skipped; do not treat a missing dump diff as a failure.
- If you want automatic bug minimization, add
  `--validators=ResultsetComparatorSimplify` -- be aware this runs extra
  queries against both servers to simplify each found case, which can
  itself introduce side effects, so don't combine it with a long
  high-volume run; use it on a targeted rerun once you already suspect a
  specific discrepancy.
