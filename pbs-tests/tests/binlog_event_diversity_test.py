#!/usr/bin/env python3
"""binlog event-diversity parsing test for percona-binlog-server.

binlog_server's job is to correctly delimit and archive whatever event
stream the source produces; this test tries to make that stream as varied
as realistically possible and confirms nothing gets lost or breaks it.
Across several phases, each first changes one or more of the *server's*
binlog-related settings (`binlog_format`, `binlog_row_image`, and, where
supported, `binlog_transaction_compression`), then runs a battery of
deliberately varied SQL against it:

  * DDL: CREATE/ALTER/TRUNCATE/RENAME/DROP TABLE (always statement-based,
    even under ROW format; each is also an implicit-commit boundary).
  * DML: single-row and bulk INSERT, bulk UPDATE, single and bulk DELETE.
  * An explicit multi-statement transaction (several DML statements
    between BEGIN and COMMIT -- one GTID/transaction spanning many
    events).
  * A SAVEPOINT with a partial ROLLBACK TO it (the discarded statement
    must not surface after the surrounding transaction still commits).
  * A full ROLLBACK with no COMMIT at all (must produce no visible data --
    row-based binlogging only flushes a transaction's cached events to
    the actual binlog on COMMIT).
  * A large BLOB payload (`--large-payload-mb`, default 2) via a
    server-side REPEAT(), to exercise big-row event handling without
    blowing up the command line.

After each of the earlier phases, `fetch` must succeed and storage must
grow. The final phase instead starts `pull` *before* running its SQL
battery (streaming live) to also exercise the pull path: once the battery
finishes, it polls `search_by_gtid_set` against *that phase's own* final
GTID set (not just "storage grew at all", which under normal lag can be
satisfied long before later events -- especially the large BLOB insert --
have actually arrived) until pull has genuinely caught up, only then
stopping it gracefully. The last check is the strongest one:
`search_by_gtid_set` against everything generated since a baseline GTID
set captured at the very start of the scenario (`GTID_SUBTRACT(@@GLOBAL.
gtid_executed, baseline)` -- not the raw, full `@@GLOBAL.gtid_executed`,
which under SKIP_SERVER_SETUP=1 can include historical transactions
already purged before this test ran, which fresh storage could never
cover) must succeed -- i.e. genuinely everything generated across every
phase and every settings combination made it into storage, not just
"fetch/pull didn't crash".

GTID mode, no rewrite (this test is about event content, not storage
naming/chunking). basedir, binlog_server_bin, and storage settings come
from --config (default: config.json in pbs-tests/), not from
command-line flags. Reuses the shared `sbtest` database/admin connection
setup.py already sets up; sysbench itself is not used here since its
canned workloads don't cover DDL/rollback/savepoint/BLOB diversity.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Optional

# util.py/servers.py/setup.py live in pbs-tests/, one level up from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import setup
from servers import gtid_since_baseline, wait_for_pull_catch_up
from util import LOG, TestFailure, assert_response_ok, tail_log_file, total_bytes

NAME = "binlog-event-diversity"

# (label, binlog_format, binlog_row_image, binlog_transaction_compression or None to leave unset)
PHASES = [
    ("row_full", "ROW", "FULL", None),
    ("row_minimal", "ROW", "MINIMAL", None),
    ("row_noblob", "ROW", "NOBLOB", None),
    ("mixed_full", "MIXED", "FULL", None),
    ("statement", "STATEMENT", "FULL", None),
    ("row_compressed", "ROW", "FULL", "ON"),  # last: run under `pull` instead of `fetch`
]


def build_parser() -> argparse.ArgumentParser:
    p = setup.build_common_parser(__doc__)
    setup.add_catch_up_args(p)
    p.add_argument(
        "--large-payload-mb", type=int, default=2,
        help="size of the BLOB payload generated server-side each phase, in MiB (default: %(default)s)",
    )
    p.set_defaults(max_binlog_size="16M")
    return p


def try_set_global(server, name: str, value: str) -> bool:
    """Best-effort SET GLOBAL for settings that may not exist on every
    server version (e.g. binlog_transaction_compression needs 8.0.20+)."""
    try:
        server.sql(f"SET GLOBAL {name} = '{value}'")
        return True
    except TestFailure as exc:
        LOG.warning("[%s] SET GLOBAL %s=%s not supported on this server, skipping: %s", NAME, name, value, exc)
        return False


def try_read_global(server, name: str) -> Optional[str]:
    """Best-effort read of @@GLOBAL.<name>, for a setting that may not exist
    on every server version (mirrors try_set_global())."""
    try:
        return server.sql(f"SELECT @@GLOBAL.{name}").strip()
    except TestFailure as exc:
        LOG.warning("[%s] @@GLOBAL.%s not supported on this server, skipping: %s", NAME, name, exc)
        return None


def run_diverse_transactions(server, label: str, large_payload_mb: int) -> None:
    table = f"diverse_{label}"
    scratch = f"{table}_scratch"

    server.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {table} (
            id INT PRIMARY KEY AUTO_INCREMENT,
            small_int TINYINT,
            big_num BIGINT,
            price DECIMAL(10,2),
            note VARCHAR(255) UNIQUE,
            description TEXT,
            payload LONGBLOB,
            created_at DATETIME,
            flags JSON
        ) ENGINE=InnoDB
        """,
        database=setup.SBTEST_DB,
    )

    # single-row insert (autocommit)
    server.sql(
        f"INSERT INTO {table} (small_int, big_num, price, note, description, created_at, flags) "
        f"VALUES (1, 9223372036854775807, 12345.67, 'row-{label}-1', REPEAT('x', 500), NOW(), "
        f"JSON_OBJECT('k', 'v'))",
        database=setup.SBTEST_DB,
    )

    # bulk insert (many rows, one statement -> one Write_rows event with many rows)
    values = ", ".join(
        f"(2, {i}, {i}.50, 'bulk-{label}-{i}', REPEAT('y', 50), NOW(), JSON_ARRAY({i}))" for i in range(1, 21)
    )
    server.sql(
        f"INSERT INTO {table} (small_int, big_num, price, note, description, created_at, flags) VALUES {values}",
        database=setup.SBTEST_DB,
    )

    # explicit multi-statement transaction (one transaction, several DML events)
    server.sql(
        f"""
        START TRANSACTION;
        INSERT INTO {table} (small_int, note, created_at) VALUES (3, 'txn-{label}-a', NOW());
        UPDATE {table} SET price = price + 1 WHERE note = 'row-{label}-1';
        COMMIT;
        """,
        database=setup.SBTEST_DB,
    )

    # savepoint + partial rollback: the "-discard" row must not survive
    server.sql(
        f"""
        START TRANSACTION;
        INSERT INTO {table} (small_int, note, created_at) VALUES (4, 'sp-{label}-keep', NOW());
        SAVEPOINT sp1;
        INSERT INTO {table} (small_int, note, created_at) VALUES (4, 'sp-{label}-discard', NOW());
        ROLLBACK TO SAVEPOINT sp1;
        COMMIT;
        """,
        database=setup.SBTEST_DB,
    )

    # full rollback: must leave no trace in the binlog at all
    server.sql(
        f"""
        START TRANSACTION;
        INSERT INTO {table} (small_int, note, created_at) VALUES (5, 'rollback-{label}', NOW());
        ROLLBACK;
        """,
        database=setup.SBTEST_DB,
    )

    # bulk update / bulk delete / single delete
    server.sql(f"UPDATE {table} SET small_int = small_int + 100 WHERE small_int = 2", database=setup.SBTEST_DB)
    server.sql(f"DELETE FROM {table} WHERE note = 'bulk-{label}-1'", database=setup.SBTEST_DB)
    server.sql(f"DELETE FROM {table} WHERE small_int = 102 AND big_num > 15", database=setup.SBTEST_DB)

    # large payload: exercises big-row event handling
    payload_bytes = large_payload_mb * 1024 * 1024
    server.sql(
        f"INSERT INTO {table} (small_int, note, payload, created_at) "
        f"VALUES (6, 'large-{label}', REPEAT('Z', {payload_bytes}), NOW())",
        database=setup.SBTEST_DB,
    )

    # more DDL, each an implicit-commit boundary
    server.sql(f"ALTER TABLE {table} ADD COLUMN extra_flag TINYINT DEFAULT 0", database=setup.SBTEST_DB)
    server.sql(f"CREATE TABLE {scratch} LIKE {table}", database=setup.SBTEST_DB)
    server.sql(f"INSERT INTO {scratch} SELECT * FROM {table} LIMIT 1", database=setup.SBTEST_DB)
    server.sql(f"TRUNCATE TABLE {scratch}", database=setup.SBTEST_DB)
    server.sql(f"RENAME TABLE {scratch} TO {scratch}_renamed", database=setup.SBTEST_DB)
    server.sql(f"DROP TABLE {scratch}_renamed", database=setup.SBTEST_DB)


class BinlogEventDiversityScenario(setup.ScenarioRunner):
    """Never touches sysbench_bg (sysbench isn't used here at all -- the
    diversity battery is raw SQL), so the base class's teardown for it is
    a no-op here. pull_process is only live during the final phase."""

    gtid_mode = True
    needs_sysbench = False  # raw-SQL load battery; never drives sysbench at all

    def scenario(self) -> None:
        args, test_config = self.args, self.test_config

        # See gtid_since_baseline()'s docstring: captured before any
        # workload runs so every GTID-coverage check below only ever
        # requires what this run itself generated, never anything that
        # predates it (and may be unfetchable under SKIP_SERVER_SETUP=1).
        gtid_baseline = self.server.gtid_executed()

        setup.generate_binsrv_config(
            args, test_config, output_path=self.config_path, log_path=self.binsrv_log_path,
            replication_mode="gtid", use_rewrite=False,
            storage_dir=self.storage_dir, buffer_dir=self.buffer_dir, keyring_path=self.keyring_path,
            host=self.host, port=self.port, user=setup.REPL_USER, password=setup.REPL_PASSWORD,
        )

        LOG.info("[%s] fetch #0 (baseline, before any diversity phases)", NAME)
        self.binlog_srv.fetch(self.config_path, timeout=test_config["fetch_timeout"])
        bytes_before = total_bytes(self.binlog_srv.list(self.config_path))

        # Every phase below changes these via SET GLOBAL. Under
        # SKIP_SERVER_SETUP=1 (an already-running, persistent, possibly
        # shared server) nothing else ever puts them back, so without this
        # the test would leave binlog_format/binlog_row_image/
        # binlog_transaction_compression changed for every other client
        # against that server after this test exits -- including on
        # failure. Captured once, up front, and restored in the finally
        # below no matter how the phase loop exits.
        original_binlog_format = self.server.sql("SELECT @@GLOBAL.binlog_format").strip()
        original_binlog_row_image = self.server.sql("SELECT @@GLOBAL.binlog_row_image").strip()
        original_txn_compression = try_read_global(self.server, "binlog_transaction_compression")

        try:
            for index, (label, binlog_format, binlog_row_image, txn_compression) in enumerate(PHASES):
                is_last = index == len(PHASES) - 1
                LOG.info(
                    "[%s] phase %r: binlog_format=%s binlog_row_image=%s%s%s",
                    NAME, label, binlog_format, binlog_row_image,
                    f" binlog_transaction_compression={txn_compression}" if txn_compression else "",
                    " (via pull)" if is_last else " (via fetch)",
                )

                self.server.sql(f"SET GLOBAL binlog_format = '{binlog_format}'")
                self.server.sql(f"SET GLOBAL binlog_row_image = '{binlog_row_image}'")
                if txn_compression:
                    try_set_global(self.server, "binlog_transaction_compression", txn_compression)

                if is_last:
                    self.pull_process = self.binlog_srv.start_pull(self.config_path)
                    time.sleep(2)
                    if self.pull_process.poll() is not None:
                        raise TestFailure(
                            f"pull exited immediately (code {self.pull_process.returncode}); "
                            f"last lines of {self.binsrv_log_path}:\n{tail_log_file(self.binsrv_log_path)}"
                        )

                run_diverse_transactions(self.server, label, args.large_payload_mb)

                if is_last:
                    # "Storage grew at all" only proves pull picked up *some*
                    # of this phase's events -- under normal lag it can be
                    # satisfied by the very first one, long before the rest
                    # (especially the large BLOB insert) has actually arrived.
                    # Capture this phase's own final GTID (relative to the
                    # scenario-start baseline -- see gtid_since_baseline())
                    # and poll until pull has genuinely caught up to *all*
                    # of it before stopping pull; otherwise the final
                    # search_by_gtid_set assertion below is racing pull and
                    # fails nondeterministically under load.
                    gtid_phase_target = gtid_since_baseline(self.server, gtid_baseline)
                    caught_up = wait_for_pull_catch_up(
                        self.binlog_srv, self.config_path, use_rewrite=True, gtid_target=gtid_phase_target,
                        server_binlogs=[], timeout=args.catch_up_timeout, poll_interval=args.catch_up_poll_interval,
                    )
                    if not caught_up:
                        raise TestFailure(
                            f"pull did not catch up with phase {label!r}'s GTID set within "
                            f"{args.catch_up_timeout}s"
                        )
                    rc = self.binlog_srv.stop_pull(self.pull_process, timeout=args.pull_stop_timeout)
                    self.pull_process = None
                    if rc != 0:
                        raise TestFailure(
                            f"pull did not shut down cleanly (exit {rc}) after phase {label!r}; "
                            f"last lines of {self.binsrv_log_path}:\n{tail_log_file(self.binsrv_log_path)}"
                        )
                else:
                    self.binlog_srv.fetch(self.config_path, timeout=test_config["fetch_timeout"])

                listing = self.binlog_srv.list(self.config_path)
                assert_response_ok(listing, f"list after phase {label!r}")
                bytes_after = total_bytes(listing)
                if bytes_after <= bytes_before:
                    raise TestFailure(f"phase {label!r} did not grow storage ({bytes_after} <= {bytes_before} bytes)")
                LOG.info("[%s] phase %r captured OK, storage now %d bytes", NAME, label, bytes_after)
                bytes_before = bytes_after
        finally:
            LOG.info(
                "[%s] restoring original binlog_format=%s binlog_row_image=%s%s",
                NAME, original_binlog_format, original_binlog_row_image,
                f" binlog_transaction_compression={original_txn_compression}"
                if original_txn_compression is not None else "",
            )
            try_set_global(self.server, "binlog_format", original_binlog_format)
            try_set_global(self.server, "binlog_row_image", original_binlog_row_image)
            if original_txn_compression is not None:
                try_set_global(self.server, "binlog_transaction_compression", original_txn_compression)

        LOG.info("[%s] verifying every generated transaction across all phases was captured", NAME)
        # Reuses gtid_phase_target as-is -- the same target already
        # confirmed caught-up *before* pull was stopped above -- rather
        # than re-reading @@GLOBAL.gtid_executed now. On a shared,
        # already-running server (SKIP_SERVER_SETUP=1), any transaction
        # some other client commits between stop_pull() and here would
        # otherwise get pulled into a fresh read's target even though pull
        # was no longer running to ever capture it, failing this assertion
        # for a transaction this test never generated and had no chance of
        # archiving.
        search_result = self.binlog_srv.search_by_gtid_set(self.config_path, gtid_phase_target)
        assert_response_ok(search_result, "final search_by_gtid_set across all diversity phases")

        LOG.info("[%s] PASSED", NAME)


def main() -> int:
    args = build_parser().parse_args()
    ok = BinlogEventDiversityScenario(args, name=NAME).run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
