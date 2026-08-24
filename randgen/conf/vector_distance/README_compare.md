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
| Auto-minimizes found bugs | No | No | Yes, via `ResultsetComparatorSimplify` |
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
`_vector_source`-generated literals, so only the function-call wrapper differs:

```sql
SELECT id,
    /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
    _vector_source , _vector_source
    /*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
    AS d
FROM vt WHERE id = _existing_id ;
```

Percona (executor1): `SELECT id, VECTOR_DISTANCE( <a> , <b> , 'EUCLIDEAN' ) AS d FROM vt WHERE id = <n> ;`

MariaDB (executor2): `SELECT id, VEC_DISTANCE_EUCLIDEAN( <a> , <b> ) AS d FROM vt WHERE id = <n> ;`

A `ResultsetComparator` mismatch on such a query means both engines computed
the same distance metric on the same data through native syntax and returned
different answers.

## Scope of `vector_distance_compare.yy`

Restricted to `EUCLIDEAN` and `COSINE` — the metrics with confirmed MariaDB
function names (`VEC_DISTANCE_EUCLIDEAN` / `VEC_DISTANCE_COSINE`). Extend the
same way as the `--redefine` files once `EUCLIDEAN_SQUARED` / `DOT` /
`MANHATTAN` equivalents are verified on the target MariaDB build. Do not invent
function names: a missing function can make both servers fail for unrelated
reasons, which `ResultsetComparator` may report as "both errored, no mismatch"
without testing meaningful behavior.

`_vector_source` includes both 3-dim (`v3`, `STRING_TO_VECTOR(_vector3)`) and
8-dim (`v8`, `STRING_TO_VECTOR(_vector8)`) alternatives. `select_valid` picks
each argument independently, so occasional dimension mismatches (for example
`v3` vs `v8`) are intentional coverage. `ResultsetComparator` compares error
codes as well as successful results, so those cases check whether both engines
treat the error condition the same way.

## Interpreting output

- Any `ResultsetComparator` mismatch report is the primary signal.
- Exit status: GenTest `STATUS_OK (0)` is the success criterion. Runs that
  include MariaDB log that dump comparison was skipped; a missing dump diff is
  not a failure.
- For automatic bug minimization, add
  `--validators=ResultsetComparatorSimplify`. That validator runs extra queries
  against both servers and can introduce side effects; use it on a targeted
  rerun after a specific discrepancy is suspected, not on a long high-volume
  run.
