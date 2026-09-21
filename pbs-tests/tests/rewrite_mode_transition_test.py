#!/usr/bin/env python3
"""Non-rewrite -> rewrite mode transition test for percona-binlog-server.

Verifies that switching an existing storage directory from non-rewrite to
rewrite mode (GTID mode unchanged throughout, since rewrite requires it)
resumes cleanly instead of losing data or failing to continue:

  1. sysbench prepare (initial load).
  2. Generate a GTID, non-rewrite config and `fetch` once against it.
  3. A short bounded sysbench run for new transactions.
  4. Regenerate the *same* config path, same storage dir, now with
     replication.rewrite enabled, and `fetch` again.
  5. Verify: fetch #2 succeeds, storage grew, every record `fetch` #1 wrote
     is still present, and the server's GTID set as of the mode switch is
     fully covered (via search_by_gtid_set).

basedir, binlog_server_bin, and storage settings come from --config
(default: config.json in pbs-tests/), not from command-line flags.
This test only drives `fetch` (no `pull`), so it has no
--background-duration/--catch-up-*/--pull-stop-timeout flags.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# util.py/servers.py/setup.py live in pbs-tests/, one level up from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import setup
from servers import gtid_since_baseline
from util import LOG, TestFailure, assert_response_ok, total_bytes


class RewriteModeTransitionScenario(setup.ScenarioRunner):
    """Fetch-only scenario: verify that switching an existing storage
    directory from non-rewrite to rewrite mode (GTID mode unchanged
    throughout, since rewrite requires it) resumes cleanly -- fetch keeps
    working against the same storage, previously-downloaded records are
    still there, and newly-downloaded data is covered. Never touches
    pull_process/sysbench_bg (fetch-only, no background load), so the
    base class's teardown for those is a no-op here."""

    gtid_mode = True

    def scenario(self) -> None:
        args, test_config, name = self.args, self.test_config, self.name

        # Captured before any workload runs -- see gtid_since_baseline()'s
        # docstring -- so the mode-switch coverage check below only ever
        # requires what this run itself generated, never anything that
        # predates it and may be unfetchable under SKIP_SERVER_SETUP=1.
        gtid_baseline = self.server.gtid_executed()

        LOG.info("[%s] preparing sysbench data (initial load)", name)
        self.sysbench.prepare()

        LOG.info("[%s] generating a non-rewrite GTID config", name)
        setup.generate_binsrv_config(
            args, test_config, output_path=self.config_path, log_path=self.binsrv_log_path,
            replication_mode="gtid", use_rewrite=False,
            storage_dir=self.storage_dir, buffer_dir=self.buffer_dir, keyring_path=self.keyring_path,
            host=self.host, port=self.port, user=setup.REPL_USER, password=setup.REPL_PASSWORD,
        )

        LOG.info("[%s] fetch #1 (non-rewrite mode, initial load)", name)
        self.binlog_srv.fetch(self.config_path, timeout=test_config["fetch_timeout"])
        listing_1 = self.binlog_srv.list(self.config_path)
        assert_response_ok(listing_1, "list after fetch #1 (non-rewrite)")
        bytes_1 = total_bytes(listing_1)
        if bytes_1 <= 0:
            raise TestFailure("fetch #1 (non-rewrite) stored no data")
        names_1 = {r["name"] for r in listing_1.get("result", [])}
        LOG.info(
            "[%s] fetch #1 stored %d bytes across %d file(s): %s",
            name, bytes_1, len(names_1), sorted(names_1),
        )

        LOG.info(
            "[%s] sysbench run (%ss) for new transactions before switching to rewrite mode",
            name, args.short_run_duration,
        )
        self.sysbench.run_blocking(args.short_run_duration)
        gtid_before_switch = gtid_since_baseline(self.server, gtid_baseline)

        LOG.info("[%s] switching the same config to rewrite mode (same storage dir)", name)
        setup.generate_binsrv_config(
            args, test_config, output_path=self.config_path, log_path=self.binsrv_log_path,
            replication_mode="gtid", use_rewrite=True,
            storage_dir=self.storage_dir, buffer_dir=self.buffer_dir, keyring_path=self.keyring_path,
            host=self.host, port=self.port, user=setup.REPL_USER, password=setup.REPL_PASSWORD,
        )

        LOG.info("[%s] fetch #2 (rewrite mode, same storage dir, must resume cleanly)", name)
        self.binlog_srv.fetch(self.config_path, timeout=test_config["fetch_timeout"])
        listing_2 = self.binlog_srv.list(self.config_path)
        assert_response_ok(listing_2, "list after fetch #2 (rewrite)")
        bytes_2 = total_bytes(listing_2)
        names_2 = {r["name"] for r in listing_2.get("result", [])}
        LOG.info(
            "[%s] fetch #2 stored %d bytes across %d file(s)", name, bytes_2, len(names_2),
        )
        if bytes_2 <= bytes_1:
            raise TestFailure(
                f"fetch #2 after switching to rewrite mode did not grow storage "
                f"({bytes_2} <= {bytes_1} bytes); the transition may not have resumed correctly"
            )

        # Switching to rewrite mode must not lose or rename what was already
        # downloaded under the non-rewrite config.
        missing = names_1 - names_2
        if missing:
            raise TestFailure(
                f"records present before the rewrite-mode switch are missing afterwards: {sorted(missing)}"
            )

        LOG.info("[%s] verifying full GTID coverage as of the mode switch via search_by_gtid_set", name)
        search_result = self.binlog_srv.search_by_gtid_set(self.config_path, gtid_before_switch)
        assert_response_ok(search_result, "search_by_gtid_set for the GTID set executed as of the mode switch")

        LOG.info("[%s] PASSED", name)


def build_parser() -> argparse.ArgumentParser:
    p = setup.build_common_parser(__doc__)
    p.add_argument(
        "--rewrite-file-size", default="1M",
        help="replication.rewrite.file_size once switched to rewrite mode (default: %(default)s)",
    )
    return p


def main() -> int:
    args = build_parser().parse_args()
    ok = RewriteModeTransitionScenario(args, name="rewrite-mode-transition").run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
