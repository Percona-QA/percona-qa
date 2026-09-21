# PBS QA

Scripts and tests for QA of [percona-binlog-server](https://github.com/Percona-Lab/percona-binlog-server)
(branch `0.4`), Percona's utility for streaming and archiving MySQL binary logs.

## Project Structure

```text
pbs-tests/
├── README.md
├── pbs_test_runner.py
├── config.json
├── util.py
├── servers.py
├── setup.py
├── scripts/
│   ├── generate_config.py
│   └── pbs_env.sh
└── tests/
    ├── gtid_rewrite_test.py
    ├── nogtid_norewrite_test.py
    ├── rewrite_mode_transition_test.py
    ├── pull_restart_resilience_test.py
    ├── pull_restart_resilience_test.config
    ├── pull_purge_resume_test.py
    ├── pull_purge_resume_test.config
    └── binlog_event_diversity_test.py
```

`util.py`, `servers.py`, and `setup.py` are the shared framework every
test imports (see below) — they live in `pbs-tests/` itself, not under
`tests/`, so `tests/` holds only the test scripts and their own optional
`*_test.config` files. Each test script adds `pbs-tests/` to `sys.path` at
import time (it's always exactly one directory up from the script's own
location), so every test still runs standalone from anywhere, e.g.
`./tests/gtid_rewrite_test.py` or `python3 tests/gtid_rewrite_test.py`,
without needing `PYTHONPATH` set.

## `scripts/generate_config.py`

Generates a `main_config.json` for the `binlog_server` utility from MySQL
connection credentials and server settings, matching the schema documented
in the [percona-binlog-server README](https://github.com/Percona-Lab/percona-binlog-server/blob/0.4/README.md)
and enforced by its config parser (`src/binsrv/*_config.*`,
`src/easymysql/*_config.*`).

It supports:

* Interactive prompts for host/port, user, and a hidden password prompt
  when run from a terminal, or fully non-interactive use via `--non-interactive`
  for CI. `--user` defaults to `root` and `--port` defaults to `3306` when not
  set (and not using `--dns-srv-name`).
* Credentials via CLI flags, environment variables (`MYSQL_*`), or
  `--password-env`/`--s3-secret-access-key-env` to avoid putting secrets on
  the command line or in shell history.
* Optional `connection.ssl` / `connection.tls` sections, including
  `--ssl-auto-detect` (see below) to fill them in from the server itself.
* `replication.rewrite` (GTID mode only), `keyring`, and `storage.encryption`
  sections.
* `file` or `s3` storage backends. For `file`, `--storage-path` and
  `--keyring-path` take a local path — absolute or relative, `~` allowed —
  and the script resolves it to an absolute path and builds the `file://` URI
  the config needs. For `s3`, use `--storage-uri` or the `--s3-*` helper
  flags to build one (including `/`-in-secret-key URL-encoding).
* `--encryption` turns on `storage.encryption` with sensible defaults
  (`kek_id=alpha`, `cipher=AES-256-CTR`) when `--encryption-kek-id`/
  `--encryption-cipher` aren't given explicitly (still requires
  `--keyring-path`).
* Validation mirroring the server's own rules (e.g. `host`+`port` XOR
  `dns_srv_name`, rewrite requires GTID mode, size/interval formats,
  `verify_ca`/`verify_identity` require a CA, cert requires a key,
  encryption cipher must be CTR-mode).

The written config file is created with `0600` permissions since it embeds
plaintext credentials. The console summary always masks the MySQL password
and any storage URI userinfo.

### Usage

Minimal, file-backed storage:

```bash
./scripts/generate_config.py \
  --host 127.0.0.1 --port 3306 \
  --user repl --password-env MYSQL_REPL_PASSWORD \
  --storage-backend file --storage-path /var/lib/pbs/vault \
  -o main_config.json
```

Interactive (prompts for anything not supplied, hides the password):

```bash
./scripts/generate_config.py --storage-backend file --storage-path /var/lib/pbs/vault
```

Full-featured example (SSL, GTID rewrite, encrypted storage with defaults, keyring):

```bash
./scripts/generate_config.py --non-interactive \
  --host 127.0.0.1 --port 3306 --user repl --password-env MYSQL_REPL_PASSWORD \
  --ssl-mode verify_identity --ssl-ca /etc/mysql/ca.pem \
  --ssl-cert /etc/mysql/client-cert.pem --ssl-key /etc/mysql/client-key.pem \
  --replication-mode gtid --rewrite-base-file-name binlog --rewrite-file-size 128M \
  --keyring-path /var/lib/pbs/keyring/keyring_data.json \
  --storage-backend file --storage-path /var/lib/pbs/vault \
  --encryption \
  -o main_config.json
```

S3 backend, built from access key / secret / bucket instead of a full URI:

```bash
./scripts/generate_config.py --non-interactive \
  --host 127.0.0.1 --port 3306 --user repl --password-env MYSQL_REPL_PASSWORD \
  --storage-backend s3 \
  --s3-access-key-id "$AWS_ACCESS_KEY_ID" --s3-secret-access-key-env AWS_SECRET_ACCESS_KEY \
  --s3-bucket my-binlog-bucket --s3-region us-east-1 \
  -o main_config.json
```

`--ssl-auto-detect`: connect to the server first and mirror its own SSL
configuration instead of specifying it by hand:

```bash
./scripts/generate_config.py --non-interactive \
  --host 127.0.0.1 --port 3306 --user repl --password-env MYSQL_REPL_PASSWORD \
  --ssl-auto-detect \
  --storage-backend file --storage-path /var/lib/pbs/vault \
  -o main_config.json
```

It runs `SHOW VARIABLES` on the target server for `ssl_ca`, `ssl_capath`,
`ssl_crl`, and `ssl_crlpath`, and sets the matching `--ssl-*` option to
whatever the server reports — a variable the server reports empty is treated
as unset and left alone. **This overwrites explicitly supplied values for
those four options; `ssl_cert`, `ssl_key`, and `ssl_cipher` are never copied.**
`--ssl-mode` defaults to `required` when this flag is used and you didn't
pass `--ssl-mode` yourself; pass `--ssl-mode` explicitly (any of `disabled`,
`preferred`, `required`, `verify_ca`, `verify_identity`) to use that value
instead — it's kept as-is rather than being forced. (`have_ssl` isn't
queried — modern MySQL/Percona Server builds support SSL by default and
some no longer expose that variable at all.) This mode requires the `mysql`
client binary on `PATH` and network access to the server.

Run `./scripts/generate_config.py --help` for the full list of flags, or see
`--stdout` to print the config without writing a file.

### `scripts/pbs_env.sh`

A template listing every environment variable `generate_config.py` reads,
all left empty. Edit it to fill in the values you use often, then source it
(don't execute it — exported variables only persist in the shell that
sources them) so you don't have to repeat those flags on every run:

```bash
source scripts/pbs_env.sh
./scripts/generate_config.py --non-interactive --encryption
```

CLI flags always override a value set this way, and anything left empty
falls back to the script's own defaults. Don't commit real credentials in
it — see the security note at the top of the file for the recommended way
to keep secrets out of it while still using `--password-env`/
`--s3-secret-access-key-env`.

## `tests/` — fetch/pull streaming tests

Six end-to-end tests that drive `binlog_server`'s `fetch` and `pull`
modes against a throwaway mysqld built from a given basedir:

* `gtid_rewrite_test.py`: `replication.mode=gtid`, server `gtid_mode=ON`,
  `replication.rewrite` enabled. Uses sysbench to generate load.
* `nogtid_norewrite_test.py`: `replication.mode=position`, server
  `gtid_mode=OFF`, no rewrite. Uses sysbench to generate load.
* `rewrite_mode_transition_test.py`: starts in non-rewrite GTID mode,
  `fetch`es some data, then switches the *same* config/storage to rewrite
  mode and `fetch`es again — see its own section below.
* `pull_restart_resilience_test.py`: repeatedly kills and restarts `pull`
  (`SIGKILL`, simulating a crash) under continuous load — see its own
  section below.
* `pull_purge_resume_test.py`: repeatedly kills `pull`, purges everything
  but the latest binlog, and verifies it resumes cleanly — see its own
  section below.
* `binlog_event_diversity_test.py`: varies the server's binlog-related
  settings and runs deliberately varied SQL (DDL, savepoints, rollbacks,
  large BLOBs, ...) to confirm nothing gets lost — see its own section
  below.

`gtid_rewrite_test.py` and `nogtid_norewrite_test.py` each, on their own,
run the full scenario:

1. sysbench prepare (initial load), then `fetch` once and checks storage
   grew.
2. A short bounded sysbench run for new transactions, then `fetch` again
   and checks storage grew further.
3. sysbench in the background for `--background-duration` (default 300s /
   5 minutes) with `pull` streaming concurrently. Once sysbench finishes,
   it polls (every `--catch-up-poll-interval`, up to `--catch-up-timeout`)
   until storage actually has everything the server has — for
   `nogtid_norewrite_test.py`, the set of binlog file names in storage
   (via `list`) matching `SHOW BINARY LOGS` on the server exactly; for
   `gtid_rewrite_test.py` (names don't match 1:1 after rewriting),
   `search_by_gtid_set` against everything generated since a baseline GTID
   set captured at the very start of the scenario (`GTID_SUBTRACT(@@GLOBAL.
   gtid_executed, baseline)` — not the server's raw, full
   `@@GLOBAL.gtid_executed`, which under `SKIP_SERVER_SETUP=1` can include
   historical transactions already purged before this test ran, which this
   run's fresh storage could never cover) succeeding — before stopping
   `pull` (`SIGTERM`, so it shuts down gracefully and flushes; killed only
   if it doesn't exit within `--pull-stop-timeout`), and then re-verifies
   completeness once more (reusing the same pre-stop target, not a fresh
   re-read, so a transaction some other client commits on a shared server
   in the gap after `pull` stops can't cause a false failure either).
   `--read-timeout` (default 10s) is kept short in the generated config so
   `pull` unblocks from an idle network read and notices the shutdown
   signal quickly, rather than only checking it once every ~60s.

All six share their infrastructure across three framework modules (in
`pbs-tests/`, not `tests/` — see Project Structure above), none of which are
test entry points on their own:

- **`util.py`** — stateless helpers with no scenario/server-process
  state (`assert_response_ok`, `total_bytes`, `tail_log_file`,
  `find_free_port`, `load_key_value_config`, the orphaned-binlog repair
  primitive, `TestFailure`). The leaf module: imports nothing else from
  this project.
- **`servers.py`** — the mysqld/sysbench/binlog_server process
  wrapper classes (`MysqldServer`, `ExistingServer`, `Sysbench`,
  `BinlogServer`), plus the resilience helpers layered on top of
  `BinlogServer` (`start_pull_with_recovery`,
  `run_binlog_command_with_recovery`, `wait_for_pull_catch_up`,
  `gtid_since_baseline` — `GTID_SUBTRACT(@@GLOBAL.gtid_executed,
  baseline)`, used everywhere a test builds a GTID coverage target, so it
  only ever requires what that test itself generated, never history that
  predates it and may be unfetchable under `SKIP_SERVER_SETUP=1`). Only
  imports `util.py`. `BinlogServer.list()`/`search_by_gtid_set()`/
  `search_by_timestamp()`/`purge_binlogs()` all take an optional
  `timeout`, which `wait_for_pull_catch_up()` (and `wait_for_growth()` in
  `pull_purge_resume_test.py`) fills in with whatever's left of their own
  overall `timeout` on each poll iteration, instead of each individual
  command call defaulting to a fixed 120s regardless — otherwise a
  single slow/hung call could by itself block well past a much shorter
  `--catch-up-timeout`.
- **`setup.py`** — test config loading/validation, generating
  binlog_server's `main_config.json`, the shared `./logs` layout, the
  argparse flags common to every test, and `ScenarioRunner`: the base
  class each test's own scenario class inherits from for the
  setup/teardown lifecycle every test shares (load config, start the
  server, prepare sysbench data, run the subclass's `scenario()`, then —
  no matter how it exits — stop any still-running background sysbench
  run, stop `pull` if still running, stop the server, log where the logs
  live). A subclass overrides just `scenario()` with its test-specific
  steps. `FetchPullStreamingScenario`, the one scenario shared by two
  tests (see below), also lives here.

Each `*_test.py` file owns its own scenario class (or, for the two
gtid_rewrite/nogtid_norewrite tests, just instantiates the shared
`FetchPullStreamingScenario` with different parameters) with only the
steps specific to that test.

### `tests/rewrite_mode_transition_test.py`

Verifies that switching an *existing* storage directory from non-rewrite
to rewrite mode resumes cleanly instead of losing data or failing to
continue — a scenario the other two tests don't cover, since each of them
only ever runs with one fixed mode for its whole lifetime. GTID mode is
kept on throughout (rewrite requires it); only whether
`replication.rewrite` is set changes.

1. sysbench prepare (initial load).
2. Generate a GTID, non-rewrite config and `fetch` once against it.
3. A short bounded sysbench run (`--short-run-duration`) for new
   transactions.
4. Regenerate the *same* config path and storage dir, now with
   `replication.rewrite` enabled (`--rewrite-file-size`, default `1M`),
   and `fetch` again.
5. Verify: fetch #2 succeeds, storage grew, every record fetch #1 wrote is
   still present under its original name (switching modes must not lose
   or rename what's already downloaded), and everything generated since a
   baseline GTID set captured at the very start of the scenario is covered
   as of the mode switch (`search_by_gtid_set`; not the server's raw, full
   `@@GLOBAL.gtid_executed` — see `gtid_since_baseline()` above).

This test only drives `fetch`, never `pull`, so it has no
`--background-duration`/`--catch-up-*`/`--pull-stop-timeout` flags.

```bash
./rewrite_mode_transition_test.py
```

### `tests/pull_restart_resilience_test.py`

With continuous sysbench load running and `pull` streaming concurrently,
repeatedly kills `pull` with `SIGKILL` (simulating a crash, not a graceful
stop) and restarts it, to verify it always resumes cleanly:

1. **Phase 1** — `--rapid-restart-count` (default 5) kill+restart cycles
   with no gap between the kill and the restart (just a short
   `--rapid-work-seconds` pause beforehand to let it do some work).
2. **Phase 2** — `--gapped-restart-count` (default 5) cycles, killed and
   restarted with no gap in between, but with a random
   `--gap-min-seconds`–`--gap-max-seconds` (default 5–60s) pause after each
   restart before the next kill (`--gapped-work-seconds` only applies once,
   before the first phase-2 kill).

After every restart in both phases, `list`, `search_by_timestamp` (current
time), and `search_by_gtid_set` (server's current GTID set) are all
exercised: `list` must always succeed, while the other two are only
logged (not asserted) during the storm, since "not yet covered"/"storage
empty" is an expected transient state while `pull` keeps getting killed.

Once both phases finish, it awaits the background sysbench run, polls
until the final `pull` has genuinely caught up (not a fixed sleep), stops
it gracefully (`SIGTERM`), and only then hard-asserts the real correctness
gates: `list` matching `SHOW BINARY LOGS` by name, `search_by_gtid_set`
covering everything generated since a baseline GTID set captured at the
very start of the scenario (not the server's raw, full
`@@GLOBAL.gtid_executed` — see `gtid_since_baseline()` above), and a final
`search_by_timestamp` succeeding too.

GTID mode, no rewrite. The background sysbench duration is computed from
the phase parameters (long enough to cover both phases plus the final
catch-up); `--background-duration` acts as a floor on top of that for
extra soak time.

```bash
./pull_restart_resilience_test.py
```

An optional `tests/pull_restart_resilience_test.config` file (a flat
`key=value` file, blank lines and `#` comments ignored) can override two
of the defaults above; an explicit CLI flag always wins over both the
file and the hardcoded default, and the file is a no-op if it doesn't
exist. A template is checked in with both keys empty (so both keys are
easy to find when you want to override one), which is the same as the
file not existing at all:

```
restart_counts=100
max_restart_time_interval=45
```

- `restart_counts` is split in half between `--rapid-restart-count` and
  `--gapped-restart-count` (an odd count's extra kill goes to the gapped
  half); must be positive, truncated to a maximum of 200. Unset, empty,
  or `0` keeps the CLI defaults (5 and 5).
- `max_restart_time_interval` overrides `--gap-max-seconds`. Unset,
  empty, or `0` keeps the CLI default (60s).

### `tests/pull_purge_resume_test.py`

With continuous sysbench load running and `pull` streaming concurrently,
repeats `--iterations` (default 10) times:

1. Let `pull` run for a random `--kill-wait-min-seconds`–`--kill-wait-max-seconds`
   (default 3–20s), then kill it (`SIGKILL`, a crash, not a graceful stop).
2. `purge_binlogs` everything except the single most recent (tail) record.
   `purge_binlogs <config> <name>` purges `[oldest, name]` *inclusive* and
   refuses to purge the current tail — there must always be at least one
   record left to resume from — so "purge all but the latest" means
   passing the **second-to-last** record's name, not the last one. If
   fewer than 2 records exist yet, the purge is skipped for that iteration
   (logged, not a failure); the kill+restart still happens. After purging,
   verifies exactly one record remains.
3. Restart `pull` and verify it actually resumes receiving *new* binlogs
   (storage byte size growing past its post-purge baseline within a
   resume timeout — see below), plus that `search_by_gtid_set` covers
   everything generated since the restart — checked via
   `GTID_SUBTRACT(@@GLOBAL.gtid_executed, <tail's previous_gtids>)` once
   this test has purged at least once, since the whole point of a purge is
   that older history is gone and asking storage to still cover it would
   be checking the wrong thing; before that first purge (fewer than 2
   records exist yet), falls back to `gtid_since_baseline()` (a baseline
   captured at the very start of the scenario) instead of the server's
   raw, full `@@GLOBAL.gtid_executed` — same reasoning, just for history
   that predates this test run entirely rather than history this test
   itself just purged.

Once all iterations finish, the background sysbench run is awaited, `pull`
is stopped gracefully (`SIGTERM`), and a final `search_by_gtid_set` (same
`GTID_SUBTRACT` approach against the final tail) confirms completeness.

There is no `--resume-timeout` flag: the resume timeout used in step 3 is
always `--kill-wait-max-seconds + 80`, recomputed every run, so it scales
automatically with whatever `--kill-wait-max-seconds` (or its
`pull_purge_resume_test.config` override) ends up being — a longer
kill-wait window means more backlog can build up while `pull` is dead, so
the budget to wait for it to catch up needs to grow with it rather than
being tuned separately.

GTID mode, no rewrite. Uses `--max-binlog-size` `4096` (mysqld's documented
minimum) so the server rotates aggressively and multiple binlog files
accumulate quickly, giving every iteration a real, multi-file purge to
exercise. The background
sysbench duration is computed from the phase parameters, with
`--background-duration` acting as a floor for extra soak time (same as
`pull_restart_resilience_test.py`).

```bash
./pull_purge_resume_test.py
```

An optional `tests/pull_purge_resume_test.config` file (a flat
`key=value` file, blank lines and `#` comments ignored) can override two
of the defaults above; an explicit CLI flag always wins over both the
file and the hardcoded default, and the file is a no-op if it doesn't
exist. A template is checked in with both keys empty (so both keys are
easy to find when you want to override one), which is the same as the
file not existing at all:

```
number_of_iterations=25
max_pull_time=15
```

- `number_of_iterations` overrides `--iterations`. Unset, empty, or `0`
  keeps the CLI default (10).
- `max_pull_time` overrides `--kill-wait-max-seconds`. Unset, empty, or
  `0` keeps the CLI default (20s). This also feeds the resume-timeout
  formula above, since that's derived from `--kill-wait-max-seconds`.

#### Self-healing after a hard kill: orphaned binlog files

A `SIGKILL` can land between `binlog_server` writing a newly rotated
binlog file's metadata and it committing the updated `binlog.index` (these
are two separate atomic writes, not one atomic pair). The next operation
against that storage then fails with `binlog_server`'s own hard error:

```
storage contains an object that is not referenced in the binlog index
```

Both `pull_restart_resilience_test.py` and `pull_purge_resume_test.py`
kill `pull` this way on purpose, so both self-heal from exactly this
signature: after a `pull`/`list`/`purge_binlogs` call fails, they tail
`binsrv.log` for that message and, only if **all** of the following hold,
remove the orphaned file and its `.json` metadata companion, log a
`WARNING`, and retry the failed operation once:

- Exactly one binlog payload file in the local storage directory is
  unreferenced by `binlog.index` (zero means something else is wrong;
  more than one is a bigger inconsistency not to guess at).
- Its name follows the `<base>.<digits>` pattern every binlog_server
  naming scheme (plain or rewrite-mode) uses.
- It's also the highest-sequence file *on disk* sharing that base name —
  i.e. it really is the newest rotation attempt, not an older, unrelated
  gap sitting next to a more recent file.
- Its sequence number is exactly one more than the highest sequence
  number among same-base files `binlog.index` *does* reference —
  confirming it's the very next rotation, with no gap.
- That last-referenced file is itself present on disk and has a valid,
  parseable `.json` metadata file — the index's own last entry has to be
  intact and trustworthy before anything gets deleted on the strength of
  it.

If any check fails or the error doesn't match, no action is taken and the
original failure/result is returned as-is — this is a narrow,
well-understood repair for one specific crash signature, not a
general-purpose retry. This logic (`find_and_repair_orphaned_binlog()` in
`util.py`; `start_pull_with_recovery()` and
`run_binlog_command_with_recovery()` in `servers.py`) only applies
to the local filesystem backend; it's a no-op for S3 storage.

### `tests/binlog_event_diversity_test.py`

The other tests mostly rely on sysbench's canned OLTP workload for load;
this one instead crafts a deliberately varied SQL battery directly (no
sysbench) to exercise as many different *kinds* of binlog events as
practical — `binlog_server`'s job is to correctly delimit and archive
whatever event stream the source produces, so this test tries to make
that stream as varied as realistically possible and confirms nothing gets
lost or breaks it.

Runs several phases, each first changing one or more of the *server's*
binlog-related settings, then running the same SQL battery:

* `binlog_format`: `ROW`, `MIXED`, `STATEMENT` (DDL is always
  statement-based even under `ROW`; the point is to also exercise
  row-based and statement-based DML events).
* `binlog_row_image`: `FULL`, `MINIMAL`, `NOBLOB` (changes what a row
  event actually contains for `UPDATE`/`DELETE`).
* `binlog_transaction_compression` (the last phase): compressed
  transaction payload events, where supported (8.0.20+) — skipped with a
  warning rather than failing the test on older servers.

The SQL battery itself covers: `CREATE`/`ALTER`/`TRUNCATE`/`RENAME`/`DROP
TABLE` (each an implicit-commit boundary); single-row and bulk `INSERT`;
bulk `UPDATE`; single and bulk `DELETE`; an explicit multi-statement
transaction; a `SAVEPOINT` with a partial `ROLLBACK TO` it (the discarded
statement must not survive); a full `ROLLBACK` with no `COMMIT` (must
leave no trace at all); and a large BLOB payload (`--large-payload-mb`,
default 2) built server-side via `REPEAT()`.

Every phase but the last uses `fetch` and checks it succeeds and storage
grows; the last phase instead starts `pull` *before* running its SQL
battery (streaming live) to also exercise that path, then stops it
gracefully — covering "fetches or pulls" both ways. The final, strongest
check is `search_by_gtid_set` against every GTID generated since the
scenario-start baseline: everything generated across every phase and
every settings combination must be provably in storage, not just
"fetch/pull didn't crash".

GTID mode, no rewrite. Uses a larger `--max-binlog-size` (default `16M`)
than the other tests so a single transaction's events, including the
large BLOB, comfortably fit without excessive mid-transaction rotation.

The original `binlog_format`/`binlog_row_image`/`binlog_transaction_compression`
values are captured before the first phase and restored from a `finally`
once all phases are done, however the test exits (pass, fail, or an
unexpected exception) — otherwise, under `SKIP_SERVER_SETUP=1`, the last
phase's settings would stay changed on that persistent server for every
other client after this test exits.

```bash
./binlog_event_diversity_test.py
```

### `config.json`

Where `basedir`, the `binlog_server` binary, existing-server connection
details, and storage/S3 settings live — a checked-in template with empty
values, the same pattern as `scripts/pbs_env.sh`. Lives in the `pbs-tests/`
directory itself (not under `tests/`), since it's read by
`pbs_test_runner.py` as well as every test. Edit it before running
either test:

```json
{
  "basedir": "/usr/local/mysql-8.0",
  "binlog_server_bin": "/path/to/build/binlog_server",
  "sysbench_bin": "",
  "sysbench_table_count": "",
  "sysbench_threads_count": "",
  "sysbench_table_size": "",
  "sysbench_script": "",
  "sysbench_run_time": "",
  "fetch_timeout": "",
  "encryption": "",
  "encryption_kek_id": "",
  "encryption_cipher": "",
  "keyring_file_cipher": "",
  "connection": {
    "host": "",
    "port": 3306,
    "user": "",
    "password": ""
  },
  "s3": {
    "access_key_id": "",
    "secret_access_key": "",
    "secret_access_key_env": "",
    "bucket": "",
    "region": "",
    "endpoint": ""
  }
}
```

`binlog_server_bin` is always required. `sysbench_bin`, `sysbench_table_count`,
`sysbench_threads_count`, `sysbench_table_size`, `sysbench_script`, and
`fetch_timeout` are all optional — when empty or unset, each falls back to
a default (`sysbench` on `PATH`; `4` tables; `4` threads; `10000` rows per
table; `oltp_read_write`; `300` seconds for `fetch`, raise this for a
slow/debug `binlog_server` build or a large amount of data to download).

`sysbench_run_time` is also optional — unset, empty, or `0` (the default)
changes nothing: every scenario keeps using its own `--background-duration`
(default 300s, or an explicit CLI value) for the background/soak sysbench
run that runs concurrently with `pull`. Set it to override that duration
across every scenario that has one (`gtid_rewrite_test.py`,
`nogtid_norewrite_test.py`, `pull_restart_resilience_test.py`,
`pull_purge_resume_test.py`) in one place — applied before each
scenario's own logic runs, so e.g. `pull_restart_resilience_test.py`'s
`required_duration` floor (see its own section above) still applies on
top of it exactly as it would on top of `--background-duration`. It has
no effect on `--short-run-duration` (the short blocking bursts in
`rewrite_mode_transition_test.py` and the two fetch/pull streaming
tests), which stays CLI-only, or on `binlog_event_diversity_test.py`
(doesn't use sysbench at all).

`encryption` turns on `storage.encryption` for every generated config —
unset, empty, `0`, `false`, and the string `"0"` all mean disabled (the
default); any other value means enabled. When enabled, `encryption_kek_id`
is an optional override — left empty, it gets `generate_config.py`'s own
`--encryption` default (`kek_id=alpha`).

`encryption_cipher` (the cipher `binlog_server` uses to encrypt binlog
*data*; must be a CTR-mode cipher — a real requirement of `binlog_server`
itself, confirmed directly against its source) and `keyring_file_cipher`
(a separate, unrelated setting — see below) are also optional overrides,
but work a little differently from the rest of this file: left empty,
each one is **randomly chosen** — once per test run, not once for the
whole test suite — instead of always falling back to one fixed default.
This is deliberate: it exercises more of the supported cipher
combinations across runs over time instead of a QA suite silently only
ever testing the same single pairing. The chosen values are logged
(`"... not set in test config; randomly using ... for this run"`) and
stay fixed for that entire run — including across a test like
`rewrite_mode_transition_test.py` that regenerates the config more than
once — since changing either mid-run would break decryption of data
already written under the first choice. Set either field explicitly in
this file to pin it instead of leaving it to chance.

`keyring.uri` always points at `keyring_data.json` inside that run's
`./logs` (alongside `binsrv_data`/`binsrv_tmp`), and that file is
auto-created (a single random key under the resolved `kek_id`, `0600`
permissions) the first time a run needs it — you don't need to supply one
yourself. `keyring_file_cipher` is the cipher *that auto-generated key
itself is recorded under inside the keyring file* — unrelated to
`encryption_cipher` above (this is about how the keyring stores its own
key, not how binlog data gets encrypted). Unlike `encryption_cipher`,
`binlog_server` doesn't restrict this to CTR mode: its keyring code
accepts `ECB`, `CBC`, `CTR`, or `GCM` (verified directly against its
source), and in principle allows all twelve
`AES-{128,192,256}-{ECB,CBC,CTR,GCM}` combinations.

**But `encryption_cipher` and `keyring_file_cipher` aren't fully
independent**: `binlog_server` only allows an `ECB`/`CBC`-mode keyring
cipher to wrap a file key (the actual per-binlog data key, sized by
`encryption_cipher`) whose length is a multiple of its 16-byte block
size. `AES-128` (16 bytes) and `AES-256` (32 bytes) satisfy that;
`AES-192` (24 bytes) does **not** (24 isn't a multiple of 16) — pairing
an `ECB`/`CBC` `keyring_file_cipher` with an `AES-192-CTR`
`encryption_cipher` fails deep inside `binlog_server`'s storage
initialization with `"active data cipher key length is not compatible
with the active KEK cipher block size"`. `CTR`/`GCM`-mode keyring ciphers
have no such restriction. To avoid ever hitting this: when only one of
the two fields is left empty, its random choice is restricted to values
compatible with whatever the other one resolved to (explicit or
already-randomly-chosen); when *both* are explicitly set to an
incompatible pair, the test fails fast with a clear message — before
`mysqld` is even started — instead of surfacing this error. (A cipher
name `ensure_keyring_file()` itself doesn't recognize at all is a
separate, later failure: after `mysqld` has already started and sysbench
data prepared, since the keyring file itself isn't created until then.)

`basedir` (containing `bin/mysqld` and `bin/mysql`) is required unless
`SKIP_SERVER_SETUP=1` (see below), in which case `connection` is required
instead. Storage defaults to local
file-backed storage unless `s3.bucket` is set, in which case the S3
backend is used and the rest of the `s3` fields apply (same meaning as
`generate_config.py`'s `--s3-*` flags — use `secret_access_key_env`
instead of `secret_access_key` to keep a real secret out of this
checked-in file). Don't commit real credentials here.

There is no `s3.path` field: the storage prefix within the bucket is
always set automatically, directly at the bucket root, to
`pbs-qa-<server_uuid>` (direct/sequential runs) or
`pbs-qa-w<N>-<server_uuid>` (running under `pbs_test_runner.py`'s
parallel mode, in worker slot `w<N>`) — never a fixed or configurable
base prefix — so separate test runs never share the same S3 objects.
`pbs-qa` is a fixed namespace every prefix this suite generates starts
with, for easy identification in a bucket shared with other projects and
as a stable target if you ever want to add your own bucket lifecycle
rule as a backstop, independent of whatever `server_uuid` a given run
happens to produce. Nothing purges
a leftover S3 prefix between runs the way `./logs`/`binsrv_data` gets
wiped locally, so without the per-run uniqueness, either two
`pbs_test_runner.py --parallel` workers or two merely separate/repeated
runs would silently race on and corrupt each other's storage.
`<server_uuid>` is that run's own server's `@@GLOBAL.server_uuid` — for a
self-managed mysqld (the common case) that's freshly generated by MySQL
itself every time `server.initialize()` creates a new datadir, so it's
already unique per run on its own, and stays fixed for that server's
whole lifetime. This is resolved once per run, after the server is up
(logged as `"s3.path resolved to ... for this run"`), and stays fixed
even across a test that regenerates the config more than once (e.g.
`rewrite_mode_transition_test.py`) — every regeneration computes the same
value independently, since it no longer depends on anything already
written to the config.

Caveat under `SKIP_SERVER_SETUP=1` (an already-running, persistent
server): `server_uuid` does *not* change between separate test
invocations. `--parallel` is already rejected in that mode (see below),
so this can't race with a concurrent sibling run, but two separate
*sequential* runs against that same server will resolve to the same
S3 path and can still collide with each other's leftover objects.

At the end of every run, every object under that run's own resolved
`s3.path` prefix is deleted — never the whole bucket, and never another
run's prefix. This needs `boto3` installed (see Requirements); without
it, cleanup is skipped with a one-line warning and the test's result is
unaffected either way. It authenticates with the exact same
credentials/endpoint/region `config.json`'s `s3` section already has —
the same account that wrote the data, cleaning up its own data, so no
extra permissions are needed beyond what running the test already
required. A cleanup failure for any other reason (network blip, a
delete-denied bucket policy, etc.) is likewise just a warning, logged
but never turned into a test failure.

### Databases and accounts the tests create

Every test, regardless of scenario, uses the same fixed set of MySQL-level
names — shared setup/teardown code in `servers.py`, not anything
test-specific:

* Database `sbtest` — holds everything a scenario's workload writes,
  whether that's sysbench's own tables or a raw-SQL test's (e.g.
  `binlog_event_diversity_test.py`'s `diverse_*` tables).
* Accounts `'repl_test'@'%'` (used for the `binlog_server` replication
  connection — `REPLICATION SLAVE` only) and `'sbtest_test'@'%'` (used by
  sysbench and raw-SQL workloads — full privileges on `sbtest.*` only).

These are (re)created idempotently at the start of every run (`CREATE
DATABASE`/`CREATE USER ... IF NOT EXISTS`) and dropped again at the end
(`DROP DATABASE`/`DROP USER ... IF EXISTS`) — see below for what that
means in each of the two server modes.

### Using an already-running server instead of starting one

By default (`SKIP_SERVER_SETUP` unset or `0`), each test starts and stops
its own throwaway mysqld from `basedir`, as described above — a fresh
datadir every run, so the `sbtest` database/accounts above can never
collide with anything, and the create-at-start/drop-at-end dance is
essentially a formality (the whole datadir is wiped at the start of the
next run regardless; see below).

Set the environment variable `SKIP_SERVER_SETUP=1` to instead target a
server that is already running, using the admin credentials from
`config.json`'s `connection` section (`host`, `port`, `user`, `password`)
— `basedir` is then not required, but the `mysql` client must be on
`PATH`. Everything else runs as usual: the `repl_test`/`sbtest_test`
accounts are still created via that admin connection (idempotently —
`CREATE USER IF NOT EXISTS`, so re-running against the same server is
safe), and `binlog_server` connects with `repl_test` exactly as it would
against a self-managed server.

**This mode is meant only for temporary, disposable testing — never point
it at a server whose data you care about.** Unlike the throwaway-mysqld
default, this server isn't ours: at the end of the run, the `sbtest`
database (every table a scenario put in it) and the `repl_test`/
`sbtest_test` accounts are **unconditionally** dropped again via that same
admin connection, even if a database or accounts with those exact names
already existed on that server *before* this test ever ran. Setup can
safely use `CREATE ... IF NOT EXISTS` because creating something that's
already there is harmless either way, but teardown has no way to tell
"this was already here" apart from "this run created it" — so it drops
them regardless. Running the test suite a second time will also start
*running the workload against it* before it's torn down, and the
database won't contain whatever it had before. The test logs a warning
to this effect every time it detects `SKIP_SERVER_SETUP=1`. Teardown
itself is best-effort, like the S3 cleanup above: a failure (e.g. the
admin account lacks `DROP`) is logged as a warning and never affects the
test's recorded result. A self-managed throwaway `mysqld`'s entire
datadir, by contrast, is already disposed of the same way regardless
(wiped at the start of the next run), so no equivalent risk exists there.

```bash
SKIP_SERVER_SETUP=1 ./gtid_rewrite_test.py
```

You're responsible for that server already being configured the way the
scenario expects (`gtid_mode`/binary logging) — the test only connects to
and drives it, it never checks or changes those settings. Since the test
doesn't manage the server's binlog lifecycle either, storage still starts
empty each run (`./logs` is always recreated), so `fetch`/`pull` will
re-download the server's *entire* available binlog history on each run,
not just what this run generated.

`pbs_test_runner.py --parallel=N` (N > 0) refuses to run under
`SKIP_SERVER_SETUP=1`: every test would target the same already-running
server instead of its own throwaway mysqld, so concurrent workers would
race on the same accounts, tables, and binlogs instead of being isolated
from each other. Run those sequentially (`--parallel` not given, or `0`)
instead.

### Running

```bash
cd tests
./gtid_rewrite_test.py
./nogtid_norewrite_test.py
./rewrite_mode_transition_test.py
./pull_restart_resilience_test.py
./pull_purge_resume_test.py
./binlog_event_diversity_test.py
```

Test logs, the generated `main_config.json`, `binsrv.log`, the mysqld
datadir, and storage all land under `./logs`, relative to wherever you run
the test from — specifically `./logs/binsrv_data` (local storage),
`./logs/binsrv_tmp` (`fs_buffer_directory`, used for the S3 backend), and
`./logs/keyring_data.json` (auto-created when `encryption` is enabled).
`./logs` is cleared and recreated at the start of each run and always left
in place afterward for inspection, pass or fail.

Useful flags: `--config` to point at a different test config file;
`--background-duration 30` for a quick smoke run instead of the full 5
minutes; `--catch-up-timeout`/`--catch-up-poll-interval`/`--pull-stop-timeout`
to tune how long the post-run catch-up wait and graceful shutdown are given
before giving up; `--verbose` for debug logging; `gtid_rewrite_test.py`
also has `--rewrite-file-size`. Run `--help` on either script for the rest
(`--max-binlog-size`, `--read-timeout`, `--checkpoint-size`/
`--checkpoint-interval`). Sysbench sizing and `fetch_timeout` come from
`config.json`, not CLI flags — see above.

Any command that times out (`fetch`, sysbench, mysqld setup, admin SQL,
etc.) fails the test cleanly with a `[scenario] FAILED: ... timed out
after Ns` message and preserved logs, rather than crashing with a raw
Python traceback.

Requires `sysbench` on `PATH` unless `sysbench_bin` points somewhere else
in `config.json`; the basedir and `binlog_server` binary also come from
`config.json` as described above. `binlog_event_diversity_test.py` is the
one exception — it generates its whole load via raw SQL and never drives
sysbench at all, so it doesn't require a `sysbench` binary to exist
(`ScenarioRunner.needs_sysbench = False` for that scenario skips the
check).

The tests create their own `repl_test`/`sbtest_test` MySQL accounts with
`mysql_native_password`, falling back to the server's default auth plugin
with a warning if that plugin isn't available (in which case a TCP
connection without SSL may fail against `caching_sha2_password` — see the
warning text for what to do).

## `pbs_test_runner.py`

Runs one or more of the `tests/*.py` scripts above — the same way you'd
invoke one directly — either sequentially or across a small pool of
parallel workers, and prints a pass/fail summary (also written as
`summary.json` in the log directory).

```bash
./pbs_test_runner.py --tests=gtid_rewrite_test,pull_purge_resume_test
```

- **`--tests`** (alias **`--test`**) — comma-separated test names. `.py`
  is appended automatically unless already present, so
  `pull_restart_resilience_test` and `pull_restart_resilience_test.py`
  both resolve to `tests/pull_restart_resilience_test.py`. Every named
  test must exist under `tests/` as its own script (`util.py`,
  `servers.py`, and `setup.py` are shared framework modules, not runnable
  tests) — if any doesn't, the run fails immediately, before anything is
  executed, naming every test that couldn't be found. `--tests=all` (or
  any name list that includes `all`) runs every `*_test.py` under
  `tests/`, same as `--run-all-tests` below.
- **`--run-all-tests`** — runs every `*_test.py` under `tests/`,
  regardless of `--tests`/`--test`: whether it was given at all, and
  regardless of what value it was given. Either `--tests`/`--test` or
  `--run-all-tests` must be given.
- **`-e`/`--encryption`** — forces storage encryption on for every test in
  the run, regardless of `config.json`'s `"encryption"` setting (it only
  ever turns encryption *on*; it never turns it off). Implemented by
  writing a copy of the config file (`effective_config.json`, under the
  log directory, `0600` permissions since it carries over the source
  file's plaintext credentials verbatim) with `"encryption"` forced to `1`
  and pointing every test at that copy via `--config`; without `-e`, each
  test is pointed at `--config` (or its own default) unmodified.
- **`--parallel=N`** — `0` (the default) means parallel mode is not set:
  tests run sequentially, all sharing the log directory itself as their
  working directory (each test's own `setup_scenario()` wipes/recreates
  `./logs` there at the start of its own run) — not one permanent
  subdirectory per test, which would otherwise pile up indefinitely as
  more tests get added, most of it for tests that passed and left
  nothing worth keeping. Any other value turns parallel mode on and is
  clamped to `[1, 4]` (`1` is the minimum once it's on, `4` the maximum
  no matter how high `N` is): up to `N` tests run concurrently across
  worker slots `w1..wN` under the log directory, each slot reused as a
  working directory across the run — as soon as a test occupying a slot
  finishes, the next queued test claims that slot (and thus that slot's
  `./logs`, including the mysqld datadir under `./logs/data`) for its
  own run.
- **`--config`** — test config file forwarded to every test as `--config`
  (default: `pbs-tests/config.json`). Rejected if it resolves to a path
  located under `--log-dir`: that directory is deleted and recreated at
  the very start of the run (see below), which would otherwise delete the
  config file out from under itself before it's even read.
- **`--log-dir`** — main log directory, cleared and recreated at the
  start of the run (default: `pbs-tests/runner_logs`).

Everything this runner itself logs to the console (not each test's own
captured output, which goes to its own log file — see below) is also
copied to `test_runner.log` under the log directory, so the whole run's
narrative, including the final summary, is preserved on disk exactly as
it appeared on screen.

Each test's own console output is captured to a per-run log file rather
than streamed live to the terminal — with parallel workers, interleaved
live output from multiple tests would be unreadable. Tail a specific
test's log file (`<log-dir>/<test-name>.log` sequentially,
`<log-dir>/w<N>/<test-name>.log` in parallel mode) for a live view of
that test while the run is in progress.

In both modes, a test's working directory (the log directory itself in
sequential mode, a `w<N>` slot in parallel mode) is reused by whichever
test runs there next, so a **failing** test's `./logs` and its own
per-test log file are copied to
`<working-directory>/failed_logs/<test-name>/` before that directory is
reused — otherwise the next test to run there would wipe/overwrite that
evidence before anyone could look at it. This copy is best-effort and
never affects the test's recorded result; its path (when there is one)
is included in the console summary and `summary.json`
(`failed_logs_path`, `null` for a passing test).

## Requirements

* Python 3.7+
* The `mysql` client binary on `PATH`, only when using `--ssl-auto-detect`
* `boto3` (`pip install -r requirements.txt`), only for automatic S3
  cleanup after a test run — every other feature needs nothing installed
  beyond the standard library, and S3-backend tests still run correctly
  without it, just without cleanup (see below)
