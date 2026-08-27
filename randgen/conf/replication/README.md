# Replication Testing

Grammars in this directory drive `runall-new.pl`'s built-in master/slave
replication mode: one grammar runs against a master, statements replicate to
a slave, and `runall-new.pl` diffs both servers' data at the end.

## Grammars

| Grammar | Gendata | What it exercises |
|---|---|---|
| `replication_simple.yy` | `replication_single_engine.zz` | Plain UPDATE/INSERT/DELETE against standard `--gendata` tables. Good first smoke test. |
| `replication.yy` | `replication_single_engine.zz` | DDL (`CREATE TRIGGER`/`EVENT`/`PROCEDURE`), manual `SET BINLOG_FORMAT` switching around risky statements, `ROLLBACK TO SAVEPOINT`, recursive procedure calls, background `EVENT`s that fire independently of the query loop. Deliberately adversarial. |
| `replication_basic.yy`, `rpl_transactions.yy`, `replication-ddl_sql.yy`, `replication-dml_sql.yy`, `WL5092_sql_*.yy` | matching `.zz` in this dir | Other replication-focused scenarios; not covered by the testing below but follow the same invocation pattern. |

## Running a test

`--rpl_mode` is required to actually get a master+slave pair — without it
`runall-new.pl` just runs a single standalone server.

```bash
perl runall-new.pl \
  --basedir=<percona-or-mysql-basedir> \
  --vardir1=/tmp/rqg_var_rpl_master \
  --vardir2=/tmp/rqg_var_rpl_slave \
  --rpl_mode=row \
  --grammar=conf/replication/replication_simple.yy \
  --gendata=conf/replication/replication_single_engine.zz \
  --threads=2 \
  --queries=500 \
  --duration=120 \
  --validators=ReplicationSlaveStatus \
  --reporter=Backtrace,ErrorLog,QueryTimeout
```

`--validators=ReplicationSlaveStatus` checks slave health (`Last_Error`/
`Last_IO_Error`/`Last_SQL_Error`) during the run, not just at the end.

On success, `runall-new.pl` waits for the slave to catch up and diffs a
`mysqldump` of both servers, printing `No differences were found between
servers.` For extra confidence beyond that dump diff, verify independently:

```bash
mysql -h127.0.0.1 -P<slave_port> -uroot -e "SHOW REPLICA STATUS\G" \
  | grep -E "Exec_Source_Log_Pos|Read_Source_Log_Pos|Last_.*Error"
mysql -h127.0.0.1 -P<port> -uroot <db> -e "CHECKSUM TABLE <table>;"
```
`Read_Source_Log_Pos == Exec_Source_Log_Pos` with empty error fields, plus
matching checksums on both servers, is the strongest confirmation that the
slave genuinely applied the same changes -- not just that a summary diff
happened to match.

## `--rpl_mode`: row / statement / mixed

- **row** (recommended default) -- slave applies row images from the
  binlog, never re-executes SQL text. Safe against non-deterministic
  functions by construction.
- **statement** -- slave re-executes the actual SQL. More revealing (catches
  real divergence bugs row-based replication is immune to), but grammars
  using `RAND()`/`UUID()`/etc. need their own safety handling.
  `replication.yy`'s manual `SET BINLOG_FORMAT='ROW'` wrapping around risky
  statements is exactly that -- and it does not work under a pure
  `statement` global default (see below).
- **mixed** -- statement by default, automatically/manually switches to row
  for whatever needs it. `replication.yy` requires this or `row`; it fails
  under pure `statement` mode with a real, reproducible error:
  `Cannot execute statement: impossible to write to binary log since
  statement is in row format and BINLOG_FORMAT = STATEMENT` -- the grammar's
  manual row-format override conflicts with a slave that also binlogs and is
  globally pinned to statement format. This is expected, not a harness bug.

## Version compatibility

MySQL/Percona 8.0.23 introduced `REPLICA`/`SOURCE` replication terminology as
accepted aliases for the original `SLAVE`/`MASTER` terms; 8.4.0 removed the
original terms outright (`STOP SLAVE`, `CHANGE MASTER TO`, `SHOW MASTER
STATUS`, `SHOW SLAVE STATUS`, `SHOW SLAVE HOSTS`, `MASTER_POS_WAIT()` are hard
syntax errors from 8.4 onward). MariaDB never made this change. All
replication-related code in this repo (`ReplMySQLd.pm`, the replication
Reporters/Validators, `runall.pl`/`runall-new.pl`) selects the correct
vocabulary per-server via `GenTest::ReplicationTerms`, based on the
connected server's version string -- no manual flag needed either way.

## Known issue: `CloneSlave` / `CloneSlaveXtrabackup` reporters

Not exercised by the testing above, and currently broken on modern MySQL/
Percona: `CloneSlave::monitor()` creates the cloned slave's datadir with a
bare `mkdir()` and starts `mysqld` directly against it, with no
`--initialize-insecure` bootstrap step. MySQL 8.0+ requires that step before
a normal startup will succeed against an empty datadir; confirmed failure:
`InnoDB: File ./ibdata1: 'open' returned OS error 71`. Avoid
`--reporter=CloneSlave`/`CloneSlaveXtrabackup` until this is fixed.

## Other gotcha

Don't combine `--reporter=Shutdown` with `--rpl_mode`. The `Shutdown`
reporter tears down both servers as its own coverage check, which can race
with `runall-new.pl`'s own post-run master/slave comparison (which needs
both connections alive). The comparison step already handles clean shutdown
itself -- `Shutdown` is redundant here, not complementary.
