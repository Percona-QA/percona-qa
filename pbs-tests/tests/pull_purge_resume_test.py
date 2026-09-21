#!/usr/bin/env python3
"""pull kill -> purge_binlogs -> resume test for percona-binlog-server.

With continuous sysbench load running and `pull` streaming concurrently,
repeats the following `--iterations` (default 10) times:

  1. Let `pull` run for a random `--kill-wait-min-seconds` to
     `--kill-wait-max-seconds` and then kill it (SIGKILL, simulating a
     crash rather than a graceful stop).
  2. `purge_binlogs` everything except the single most recent (tail)
     record. `purge_binlogs <config> <name>` purges `[oldest, name]`
     *inclusive* and refuses to purge the current tail (there must always
     be at least one record left to resume from), so "purge all but the
     latest" means passing the *second-to-last* record's name, not the
     last one; if fewer than 2 records exist yet, the purge is skipped for
     that iteration (logged, not a failure) and the cycle still runs
     kill+restart. After purging, verifies exactly one record remains.
  3. Restart `pull` and verify it actually resumes receiving *new* binlogs
     (storage byte size growing beyond its post-purge baseline), plus that
     `search_by_gtid_set` covers everything generated since the restart.
     Coverage is checked with `GTID_SUBTRACT(@@GLOBAL.gtid_executed,
     <tail's previous_gtids>)`, not the server's full historical GTID set
     -- the whole point of the purge is that older history is gone, so
     asking storage to still cover it would be checking the wrong thing.

Once all iterations finish, the background sysbench run is awaited, `pull`
is stopped gracefully (SIGTERM), and a final `search_by_gtid_set` (using
the same GTID_SUBTRACT approach against the final tail) confirms
completeness.

GTID mode, no rewrite (rewrite would change file naming/chunking; this
test is about resuming after purge_binlogs, not about naming). basedir,
binlog_server_bin, and storage settings come from --config (default:
config.json in pbs-tests/), not from command-line flags.
--max-binlog-size defaults to 4096 bytes -- mysqld's documented minimum --
so the server rotates aggressively and multiple binlog files accumulate
quickly, giving every iteration a real, multi-file purge to exercise
instead of "nothing yet" or a single file.

--resume-timeout is not a flag: it's always --kill-wait-max-seconds + 80,
computed fresh each run, so it scales automatically with whatever
--kill-wait-max-seconds (or its pull_purge_resume_test.config override,
see below) ends up being -- a longer kill-wait window means more backlog
can build up while pull is dead, so the resume/catch-up budget needs to
grow with it rather than being tuned separately.

An optional pull_purge_resume_test.config file next to this script (a
flat "key=value" file, blank lines and "#" comments ignored) can override
two of the defaults above -- unset, empty, or 0 for either key just keeps
the CLI default, and an explicit --iterations/--kill-wait-max-seconds on
the command line always wins over both:

  number_of_iterations=<n>   overrides --iterations.
  max_pull_time=<seconds>    overrides --kill-wait-max-seconds.
"""

from __future__ import annotations

import argparse
import random
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# util.py/servers.py/setup.py live in pbs-tests/, one level up from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import setup
from servers import gtid_since_baseline, run_binlog_command_with_recovery, start_pull_with_recovery, wait_for_pull_catch_up
from util import LOG, TestFailure, assert_response_ok, load_key_value_config, tail_log_file, total_bytes

NAME = "pull-purge-resume"

TEST_CONFIG_PATH = Path(__file__).resolve().parent / "pull_purge_resume_test.config"

# resume_timeout is always derived from kill_wait_max_seconds (see the
# module docstring); this is that formula's fixed offset.
RESUME_TIMEOUT_MARGIN = 80


def apply_test_config_overrides(p: argparse.ArgumentParser) -> None:
    """Reads TEST_CONFIG_PATH (a no-op if it doesn't exist) and, for any
    key that's actually set to a valid non-zero value, replaces that
    flag's argparse default -- so an explicit CLI flag still overrides the
    file, and the file still overrides the hardcoded default."""
    values = load_key_value_config(TEST_CONFIG_PATH)
    overrides = {}

    raw_iterations = values.get("number_of_iterations", "").strip()
    if raw_iterations and raw_iterations != "0":
        try:
            iterations = int(raw_iterations)
        except ValueError:
            sys.exit(f"{TEST_CONFIG_PATH}: 'number_of_iterations' must be an integer, got {raw_iterations!r}")
        if iterations < 0:
            sys.exit(f"{TEST_CONFIG_PATH}: 'number_of_iterations' must be positive, got {iterations}")
        overrides["iterations"] = iterations

    raw_max_pull_time = values.get("max_pull_time", "").strip()
    if raw_max_pull_time and raw_max_pull_time != "0":
        try:
            max_pull_time = float(raw_max_pull_time)
        except ValueError:
            sys.exit(f"{TEST_CONFIG_PATH}: 'max_pull_time' must be a number, got {raw_max_pull_time!r}")
        if max_pull_time < 0:
            sys.exit(f"{TEST_CONFIG_PATH}: 'max_pull_time' must be positive, got {max_pull_time}")
        overrides["kill_wait_max_seconds"] = max_pull_time

    if overrides:
        LOG.info("%s: overriding defaults: %s", TEST_CONFIG_PATH, overrides)
        p.set_defaults(**overrides)


def build_parser() -> argparse.ArgumentParser:
    p = setup.build_common_parser(__doc__)
    setup.add_background_duration_arg(p)
    setup.add_catch_up_args(p)

    p.add_argument("--iterations", type=int, default=10, help="kill+purge+resume cycles (default: %(default)s)")
    p.add_argument(
        "--kill-wait-min-seconds", type=float, default=3,
        help="min seconds to let pull run before killing it each iteration (default: %(default)s)",
    )
    p.add_argument(
        "--kill-wait-max-seconds", type=float, default=20,
        help="max seconds to let pull run before killing it each iteration (default: %(default)s)",
    )
    p.add_argument("--resume-poll-interval", type=int, default=2, help="seconds between resume checks (default: %(default)s)")
    # mysqld's documented minimum for max_binlog_size is 4096 bytes; using
    # the lowest possible value (instead of build_common_parser()'s usual 4M
    # default) forces rotation aggressively so multiple binlog files
    # accumulate quickly and every iteration has a real, multi-file purge to
    # exercise; still overridable via --max-binlog-size.
    p.set_defaults(max_binlog_size="4096")

    apply_test_config_overrides(p)
    return p


def select_purge_target(listing: dict) -> Optional[str]:
    """The name to pass to purge_binlogs so that only the tail survives, or
    None if there are fewer than 2 records (nothing safe to purge yet)."""
    records = listing.get("result", [])
    if len(records) < 2:
        return None
    return records[-2]["name"]


def wait_for_growth(binlog_srv, config_path, baseline_bytes: int, *, timeout: float, poll_interval: float) -> bool:
    """Each list() call below is capped at whatever's left of `timeout`,
    not BinlogServer's own fixed per-command default (120s) -- see
    wait_for_pull_catch_up()'s docstring in servers.py for why that matters."""
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return False
        listing = binlog_srv.list(config_path, timeout=remaining)
        if listing.get("status") in ("success", "warning") and total_bytes(listing) > baseline_bytes:
            return True
        if time.time() >= deadline:
            return False
        time.sleep(poll_interval)


def coverage_target_gtid_set(server, tail_previous_gtids: Optional[str], gtid_baseline: str) -> str:
    """The GTID set storage should be able to cover right now: everything
    executed so far, minus whatever was already gone before the surviving
    tail file began (i.e. the history a purge intentionally discarded).

    Before this test's own first purge (no record has a tail yet),
    falls back to gtid_since_baseline() rather than the server's raw,
    full @@GLOBAL.gtid_executed -- under SKIP_SERVER_SETUP=1, that full
    set can include historical transactions already purged before this
    test ever started, which this run's storage could never cover
    either (same reasoning as the purge-discarded history above, just
    from before the scenario began instead of during it)."""
    if not tail_previous_gtids:
        return gtid_since_baseline(server, gtid_baseline)
    return server.sql(
        f"SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '{tail_previous_gtids}')"
    ).strip()


def describe_gtid_gap(binlog_srv, config_path, server, target_gtid_set: str) -> str:
    """Best-effort diagnostics for a catch-up timeout: what we were waiting
    for, what the last actual response was, and where storage currently
    stands, so a timeout message says *why*, not just *that*, it failed."""
    try:
        last_result = binlog_srv.search_by_gtid_set(config_path, target_gtid_set)
    except Exception as exc:  # noqa: BLE001 - diagnostics only, must never mask the real failure
        last_result = {"status": "error", "message": f"<search_by_gtid_set itself raised: {exc}>"}
    try:
        listing = binlog_srv.list(config_path)
        stored = listing.get("result", [])
        storage_summary = f"{len(stored)} file(s), {total_bytes(listing)} bytes"
    except Exception as exc:  # noqa: BLE001
        storage_summary = f"<list() itself raised: {exc}>"
    try:
        gtid_now = server.gtid_executed()
    except Exception as exc:  # noqa: BLE001
        gtid_now = f"<gtid_executed() itself raised: {exc}>"
    return (
        f"target_gtid_set={target_gtid_set!r}; last search_by_gtid_set response={last_result}; "
        f"storage now: {storage_summary}; server @@GLOBAL.gtid_executed now: {gtid_now!r}"
    )


class PullPurgeResumeScenario(setup.ScenarioRunner):
    gtid_mode = True

    def scenario(self) -> None:
        args, test_config = self.args, self.test_config
        storage_dir, binsrv_log_path = self.storage_dir, self.binsrv_log_path
        config_path, server, sysbench, binlog_srv = self.config_path, self.server, self.sysbench, self.binlog_srv

        # Captured before any workload runs -- see coverage_target_gtid_set()
        # and gtid_since_baseline()'s docstrings -- as the fallback floor for
        # iterations where this test hasn't purged anything of its own yet.
        gtid_baseline = server.gtid_executed()

        # Always derived from kill_wait_max_seconds (see the module
        # docstring), not an independently configurable flag.
        resume_timeout = args.kill_wait_max_seconds + RESUME_TIMEOUT_MARGIN
        LOG.info(
            "[%s] resume_timeout = kill_wait_max_seconds(%s) + %s = %ss",
            NAME, args.kill_wait_max_seconds, RESUME_TIMEOUT_MARGIN, resume_timeout,
        )

        LOG.info("[%s] preparing sysbench data (initial load)", NAME)
        sysbench.prepare()

        setup.generate_binsrv_config(
            args, test_config, output_path=config_path, log_path=binsrv_log_path,
            replication_mode="gtid", use_rewrite=False,
            storage_dir=storage_dir, buffer_dir=self.buffer_dir, keyring_path=self.keyring_path,
            host=self.host, port=self.port, user=setup.REPL_USER, password=setup.REPL_PASSWORD,
        )

        required_duration = int(
            args.iterations * (args.kill_wait_max_seconds + resume_timeout + 5) + 30
        )
        background_duration = max(required_duration, args.background_duration)
        LOG.info("[%s] starting continuous background sysbench load for ~%ss", NAME, background_duration)
        self.sysbench_bg = sysbench.run_background(background_duration)

        self.pull_process = binlog_srv.start_pull(config_path)
        time.sleep(2)
        if self.pull_process.poll() is not None:
            raise TestFailure(
                f"pull exited immediately (code {self.pull_process.returncode}); "
                f"last lines of {binsrv_log_path}:\n{tail_log_file(binsrv_log_path)}"
            )

        tail_previous_gtids: Optional[str] = None
        for i in range(1, args.iterations + 1):
            wait = random.uniform(args.kill_wait_min_seconds, args.kill_wait_max_seconds)
            LOG.info("[%s] iteration %d/%d: letting pull run for %.1fs before killing it", NAME, i, args.iterations, wait)
            time.sleep(wait)

            LOG.info("[%s] iteration %d: killing pull (pid %s)", NAME, i, self.pull_process.pid)
            # Popen.kill() on an already-exited child is a silent no-op (it
            # just signals a zombie), and the immediately-following wait()
            # would then simply reap it -- so an unrelated crash sometime
            # during the sleep above would otherwise go completely
            # undetected, credited as a normal scheduled kill instead of
            # the real bug it is.
            exit_code = self.pull_process.poll()
            if exit_code is not None:
                raise TestFailure(
                    f"pull (pid {self.pull_process.pid}) exited on its own (code {exit_code}) before "
                    f"the scheduled kill on iteration {i}; last lines of {binsrv_log_path}:\n"
                    f"{tail_log_file(binsrv_log_path)}"
                )
            self.pull_process.kill()
            try:
                self.pull_process.wait(timeout=15)
            except subprocess.TimeoutExpired as exc:
                raise TestFailure(
                    f"pull (pid {self.pull_process.pid}) did not die within 15s of SIGKILL on iteration {i}"
                ) from exc
            self.pull_process = None

            # A prior hard kill can land between binlog_server writing a new
            # rotated file's metadata and it committing the updated index --
            # self-heals by removing that one orphaned file and retrying, if
            # that's what happened.
            listing = run_binlog_command_with_recovery(
                lambda: binlog_srv.list(config_path), storage_dir, f"list before purge on iteration {i}"
            )
            assert_response_ok(listing, f"list before purge on iteration {i}")
            target = select_purge_target(listing)
            if target is None:
                LOG.warning(
                    "[%s] iteration %d: only %d record(s) in storage, nothing safe to purge yet "
                    "(need at least 2); skipping the purge this round",
                    NAME, i, len(listing.get("result", [])),
                )
            else:
                LOG.info(
                    "[%s] iteration %d: purging everything up to and including %r (keeping only the tail)",
                    NAME, i, target,
                )
                purge_result = run_binlog_command_with_recovery(
                    lambda: binlog_srv.purge_binlogs(config_path, target), storage_dir, f"purge_binlogs on iteration {i}"
                )
                assert_response_ok(purge_result, f"purge_binlogs on iteration {i}")

                after_purge = binlog_srv.list(config_path)
                assert_response_ok(after_purge, f"list after purge on iteration {i}")
                remaining = after_purge.get("result", [])
                if len(remaining) != 1:
                    raise TestFailure(
                        f"iteration {i}: expected exactly 1 record after purging down to the "
                        f"tail, found {len(remaining)}"
                    )
                tail_previous_gtids = remaining[0].get("previous_gtids")
                LOG.info(
                    "[%s] iteration %d: only the tail file (%r) remains after purge, as expected",
                    NAME, i, remaining[0]["name"],
                )

            bytes_before_restart = total_bytes(binlog_srv.list(config_path))

            LOG.info("[%s] iteration %d: restarting pull", NAME, i)
            self.pull_process = start_pull_with_recovery(binlog_srv, config_path, storage_dir, binsrv_log_path)
            if self.pull_process.poll() is not None:
                raise TestFailure(
                    f"pull failed to restart on iteration {i} (exit {self.pull_process.returncode}); "
                    f"last lines of {binsrv_log_path}:\n{tail_log_file(binsrv_log_path)}"
                )

            LOG.info(
                "[%s] iteration %d: waiting up to %ss for pull to resume receiving new binlogs",
                NAME, i, resume_timeout,
            )
            resumed = wait_for_growth(
                binlog_srv, config_path, bytes_before_restart,
                timeout=resume_timeout, poll_interval=args.resume_poll_interval,
            )
            if not resumed:
                raise TestFailure(
                    f"iteration {i}: pull did not resume receiving new data within "
                    f"{resume_timeout}s after restart"
                )
            LOG.info("[%s] iteration %d: pull resumed and is receiving new binlogs", NAME, i)

            # Poll, don't check once: under continuous background load the
            # target GTID set keeps moving, so a single search_by_gtid_set
            # call right after confirming byte growth is inherently racy --
            # pull is virtually always still a little behind a live target.
            target_gtid_set = coverage_target_gtid_set(server, tail_previous_gtids, gtid_baseline)
            LOG.info(
                "[%s] iteration %d: waiting up to %ss for storage to cover %r",
                NAME, i, resume_timeout, target_gtid_set,
            )
            covered = wait_for_pull_catch_up(
                binlog_srv, config_path, use_rewrite=True, gtid_target=target_gtid_set, server_binlogs=[],
                timeout=resume_timeout, poll_interval=args.resume_poll_interval,
            )
            if not covered:
                raise TestFailure(
                    f"iteration {i}: pull did not cover the target GTID set within "
                    f"{resume_timeout}s; {describe_gtid_gap(binlog_srv, config_path, server, target_gtid_set)}"
                )
            LOG.info("[%s] iteration %d: GTID coverage confirmed", NAME, i)

        LOG.info("[%s] waiting for the background sysbench run to finish", NAME)
        try:
            self.sysbench_bg.wait(timeout=background_duration + 120)
        except subprocess.TimeoutExpired as exc:
            raise TestFailure(f"background sysbench run did not finish within {background_duration + 120}s") from exc
        if self.sysbench_bg.returncode != 0:
            raise TestFailure(f"background sysbench run failed (exit {self.sysbench_bg.returncode})")
        self.sysbench_bg = None

        final_target_gtid_set = coverage_target_gtid_set(server, tail_previous_gtids, gtid_baseline)

        LOG.info(
            "[%s] waiting up to %ss for the final pull to catch up (target %r)",
            NAME, args.catch_up_timeout, final_target_gtid_set,
        )
        caught_up = wait_for_pull_catch_up(
            binlog_srv, config_path, use_rewrite=True, gtid_target=final_target_gtid_set, server_binlogs=[],
            timeout=args.catch_up_timeout, poll_interval=args.catch_up_poll_interval,
        )
        if not caught_up:
            raise TestFailure(
                f"pull did not catch up with the server within {args.catch_up_timeout}s at the end; "
                f"{describe_gtid_gap(binlog_srv, config_path, server, final_target_gtid_set)}"
            )

        rc = binlog_srv.stop_pull(self.pull_process, timeout=args.pull_stop_timeout)
        self.pull_process = None
        if rc != 0:
            raise TestFailure(
                f"final pull did not shut down cleanly (exit {rc}); "
                f"last lines of {binsrv_log_path}:\n{tail_log_file(binsrv_log_path)}"
            )

        LOG.info("[%s] verifying final GTID coverage via search_by_gtid_set", NAME)
        final_result = binlog_srv.search_by_gtid_set(config_path, final_target_gtid_set)
        assert_response_ok(final_result, "final search_by_gtid_set")

        LOG.info("[%s] PASSED", NAME)


def main() -> int:
    args = build_parser().parse_args()
    ok = PullPurgeResumeScenario(args, name=NAME).run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
