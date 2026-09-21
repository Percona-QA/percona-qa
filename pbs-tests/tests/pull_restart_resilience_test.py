#!/usr/bin/env python3
"""pull kill/restart resilience test for percona-binlog-server.

With continuous sysbench load running against the server and `pull`
streaming concurrently, repeatedly kill `pull` (SIGKILL, simulating a crash
rather than a graceful stop) and restart it:

  1. Phase 1 -- `--rapid-restart-count` cycles, killed and restarted with no
     gap in between (just a short `--rapid-work-seconds` pause to let it do
     some work first).
  2. Phase 2 -- `--gapped-restart-count` cycles, killed and restarted with
     no gap in between, but with a random `--gap-min-seconds` to
     `--gap-max-seconds` pause after each restart before the next kill.

After each restart in both phases, `list`, `search_by_timestamp` (with the
current time), and `search_by_gtid_set` (with the server's current GTID
set) are all exercised: `list` must always succeed (storage being read
mid-restart-storm should never itself be an error), while the other two
are only logged during the storm since "not yet covered" / "storage empty"
is an expected transient state while `pull` is being repeatedly killed.

Once both phases finish, the background sysbench run is awaited, then the
test polls until the final `pull` has genuinely caught up with everything
the server has (not a fixed sleep), stops it gracefully (SIGTERM), and
only then hard-asserts the real correctness gates: `list` matching
`SHOW BINARY LOGS` by name, `search_by_gtid_set` covering the fully
executed GTID set, and `search_by_timestamp` (now storage is non-empty)
succeeding too.

The background sysbench run's duration is computed from the phase
parameters (long enough to cover both phases plus the final catch-up);
--background-duration acts as a floor on top of that, for extra soak time.

GTID mode, no rewrite (rewrite only changes file naming/chunking, not
restart-resilience; search_by_gtid_set also requires GTID mode). basedir,
binlog_server_bin, and storage settings come from --config (default:
config.json in pbs-tests/), not from command-line flags.

An optional pull_restart_resilience_test.config file next to this script
(a flat "key=value" file, blank lines and "#" comments ignored) can
override two of the defaults above -- unset, empty, or 0 for either key
just keeps the CLI default, and an explicit --rapid-restart-count/
--gapped-restart-count/--gap-max-seconds on the command line always wins
over both:

  restart_counts=<n>    split in half between --rapid-restart-count and
                         --gapped-restart-count (the extra kill goes to
                         the gapped count for an odd n); must be
                         positive, truncated to a maximum of 200.
  max_restart_time_interval=<seconds>   overrides --gap-max-seconds.
"""

from __future__ import annotations

import argparse
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# util.py/servers.py/setup.py live in pbs-tests/, one level up from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import setup
from servers import gtid_since_baseline, start_pull_with_recovery, wait_for_pull_catch_up
from util import LOG, TestFailure, assert_response_ok, load_key_value_config, tail_log_file

NAME = "pull-restart-resilience"

TEST_CONFIG_PATH = Path(__file__).resolve().parent / "pull_restart_resilience_test.config"
MAX_RESTART_COUNTS = 200


def apply_test_config_overrides(p: argparse.ArgumentParser) -> None:
    """Reads TEST_CONFIG_PATH (a no-op if it doesn't exist) and, for any
    key that's actually set to a valid non-zero value, replaces that
    flag's argparse default -- so an explicit CLI flag still overrides the
    file, and the file still overrides the hardcoded default, exactly like
    pull_purge_resume_test.py's own p.set_defaults(max_binlog_size=...)
    already does for a single value."""
    values = load_key_value_config(TEST_CONFIG_PATH)
    overrides = {}

    raw_restart_counts = values.get("restart_counts", "").strip()
    if raw_restart_counts and raw_restart_counts != "0":
        try:
            restart_counts = int(raw_restart_counts)
        except ValueError:
            sys.exit(f"{TEST_CONFIG_PATH}: 'restart_counts' must be an integer, got {raw_restart_counts!r}")
        if restart_counts < 0:
            sys.exit(f"{TEST_CONFIG_PATH}: 'restart_counts' must be positive, got {restart_counts}")
        if restart_counts > MAX_RESTART_COUNTS:
            LOG.warning(
                "%s: restart_counts=%d exceeds the maximum of %d; truncating",
                TEST_CONFIG_PATH, restart_counts, MAX_RESTART_COUNTS,
            )
            restart_counts = MAX_RESTART_COUNTS
        overrides["rapid_restart_count"] = restart_counts // 2
        overrides["gapped_restart_count"] = restart_counts - restart_counts // 2

    raw_max_gap = values.get("max_restart_time_interval", "").strip()
    if raw_max_gap and raw_max_gap != "0":
        try:
            max_gap = float(raw_max_gap)
        except ValueError:
            sys.exit(f"{TEST_CONFIG_PATH}: 'max_restart_time_interval' must be a number, got {raw_max_gap!r}")
        if max_gap < 0:
            sys.exit(f"{TEST_CONFIG_PATH}: 'max_restart_time_interval' must be positive, got {max_gap}")
        overrides["gap_max_seconds"] = max_gap

    if overrides:
        LOG.info("%s: overriding defaults: %s", TEST_CONFIG_PATH, overrides)
        p.set_defaults(**overrides)


def build_parser() -> argparse.ArgumentParser:
    p = setup.build_common_parser(__doc__)
    setup.add_background_duration_arg(p)
    setup.add_catch_up_args(p)

    p.add_argument("--rapid-restart-count", type=int, default=5, help="kills in phase 1 (default: %(default)s)")
    p.add_argument(
        "--rapid-work-seconds", type=float, default=2,
        help="seconds to let pull run before each phase-1 kill (default: %(default)s)",
    )
    p.add_argument("--gapped-restart-count", type=int, default=5, help="kills in phase 2 (default: %(default)s)")
    p.add_argument(
        "--gapped-work-seconds", type=float, default=2,
        help="seconds to let pull run before the first phase-2 kill (default: %(default)s)",
    )
    p.add_argument("--gap-min-seconds", type=float, default=5, help="min pause after each phase-2 restart, before the next kill (default: %(default)s)")
    p.add_argument("--gap-max-seconds", type=float, default=60, help="max pause after each phase-2 restart, before the next kill (default: %(default)s)")

    apply_test_config_overrides(p)
    return p


def kill_and_restart(
    binlog_srv, config_path, pull_process: subprocess.Popen, *,
    phase: str, iteration: int, storage_dir, binsrv_log_path,
) -> subprocess.Popen:
    LOG.info("[%s] %s restart #%d: killing pull (pid %s)", NAME, phase, iteration, pull_process.pid)
    # Popen.kill() on an already-exited child is a silent no-op (it just
    # signals a zombie), and the immediately-following wait() would then
    # simply reap it -- so if this pull died on its own sometime during
    # its work/gap interval, that crash would otherwise go completely
    # undetected, credited as a normal scheduled kill instead of the real
    # bug it is.
    exit_code = pull_process.poll()
    if exit_code is not None:
        raise TestFailure(
            f"pull (pid {pull_process.pid}) exited on its own (code {exit_code}) before the scheduled "
            f"kill during {phase} restart #{iteration}; last lines of {binsrv_log_path}:\n"
            f"{tail_log_file(binsrv_log_path)}"
        )
    pull_process.kill()
    try:
        pull_process.wait(timeout=15)
    except subprocess.TimeoutExpired as exc:
        raise TestFailure(
            f"pull (pid {pull_process.pid}) did not die within 15s of SIGKILL during {phase} restart #{iteration}"
        ) from exc

    # A hard kill can land between binlog_server writing a new rotated
    # file's metadata and it committing the updated index -- self-heals by
    # removing that one orphaned file and retrying, if that's what happened.
    new_process = start_pull_with_recovery(binlog_srv, config_path, storage_dir, binsrv_log_path)
    if new_process.poll() is not None:
        raise TestFailure(
            f"pull failed to (re)start during {phase} restart #{iteration} (exit {new_process.returncode}); "
            f"last lines of {binsrv_log_path}:\n{tail_log_file(binsrv_log_path)}"
        )
    return new_process


def exercise_query_operations(binlog_srv, config_path, server, *, context: str) -> None:
    listing = binlog_srv.list(config_path)
    assert_response_ok(listing, f"list during {context}")

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    ts_result = binlog_srv.search_by_timestamp(config_path, now_iso)
    LOG.info("[%s] search_by_timestamp during %s: status=%s", NAME, context, ts_result.get("status"))

    gtid_now = server.gtid_executed()
    gtid_result = binlog_srv.search_by_gtid_set(config_path, gtid_now)
    LOG.info("[%s] search_by_gtid_set during %s: status=%s", NAME, context, gtid_result.get("status"))


class PullRestartResilienceScenario(setup.ScenarioRunner):
    gtid_mode = True

    def scenario(self) -> None:
        args, test_config = self.args, self.test_config
        storage_dir, binsrv_log_path = self.storage_dir, self.binsrv_log_path
        config_path, server, sysbench, binlog_srv = self.config_path, self.server, self.sysbench, self.binlog_srv

        # Captured before any workload runs -- see gtid_since_baseline()'s
        # docstring -- so the final GTID coverage check below only ever
        # requires what this run itself generated, never anything that
        # predates it and may be unfetchable under SKIP_SERVER_SETUP=1.
        gtid_baseline = server.gtid_executed()

        LOG.info("[%s] preparing sysbench data (initial load)", NAME)
        sysbench.prepare()

        setup.generate_binsrv_config(
            args, test_config, output_path=config_path, log_path=binsrv_log_path,
            replication_mode="gtid", use_rewrite=False,
            storage_dir=storage_dir, buffer_dir=self.buffer_dir, keyring_path=self.keyring_path,
            host=self.host, port=self.port, user=setup.REPL_USER, password=setup.REPL_PASSWORD,
        )

        required_duration = int(
            args.rapid_restart_count * (args.rapid_work_seconds + 3)
            + args.gapped_work_seconds
            + args.gapped_restart_count * (args.gap_max_seconds + 3)
            + args.catch_up_timeout + 30
        )
        # --background-duration acts as a floor: the load must run at least as
        # long as the restart phases + final catch-up need, but the flag still
        # lets the user ask for more (e.g. extra soak time) on top of that.
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

        LOG.info("[%s] phase 1: %d rapid kill+restart cycles (no gap)", NAME, args.rapid_restart_count)
        for i in range(1, args.rapid_restart_count + 1):
            time.sleep(args.rapid_work_seconds)
            self.pull_process = kill_and_restart(
                binlog_srv, config_path, self.pull_process, phase="rapid", iteration=i,
                storage_dir=storage_dir, binsrv_log_path=binsrv_log_path,
            )
            exercise_query_operations(binlog_srv, config_path, server, context=f"rapid restart #{i}")

        LOG.info(
            "[%s] phase 2: %d kill+restart cycles with a random %s-%ss gap after each restart",
            NAME, args.gapped_restart_count, args.gap_min_seconds, args.gap_max_seconds,
        )
        time.sleep(args.gapped_work_seconds)
        for i in range(1, args.gapped_restart_count + 1):
            self.pull_process = kill_and_restart(
                binlog_srv, config_path, self.pull_process, phase="gapped", iteration=i,
                storage_dir=storage_dir, binsrv_log_path=binsrv_log_path,
            )
            exercise_query_operations(binlog_srv, config_path, server, context=f"gapped restart #{i}")

            gap = random.uniform(args.gap_min_seconds, args.gap_max_seconds)
            LOG.info("[%s] gapped restart #%d: waiting %.1fs before the next kill", NAME, i, gap)
            time.sleep(gap)

        LOG.info("[%s] waiting for the background sysbench run to finish", NAME)
        try:
            self.sysbench_bg.wait(timeout=background_duration + 120)
        except subprocess.TimeoutExpired as exc:
            raise TestFailure(f"background sysbench run did not finish within {background_duration + 120}s") from exc
        if self.sysbench_bg.returncode != 0:
            raise TestFailure(f"background sysbench run failed (exit {self.sysbench_bg.returncode})")
        self.sysbench_bg = None

        gtid_final = gtid_since_baseline(server, gtid_baseline)
        server_binlogs = server.show_binary_logs()

        LOG.info("[%s] waiting up to %ss for the final pull to catch up", NAME, args.catch_up_timeout)
        caught_up = wait_for_pull_catch_up(
            binlog_srv, config_path, use_rewrite=False, gtid_target=gtid_final, server_binlogs=server_binlogs,
            timeout=args.catch_up_timeout, poll_interval=args.catch_up_poll_interval,
        )
        if not caught_up:
            raise TestFailure(
                f"pull did not catch up with the server within {args.catch_up_timeout}s after the restart storm"
            )

        rc = binlog_srv.stop_pull(self.pull_process, timeout=args.pull_stop_timeout)
        self.pull_process = None
        if rc != 0:
            raise TestFailure(
                f"final pull did not shut down cleanly (exit {rc}); "
                f"last lines of {binsrv_log_path}:\n{tail_log_file(binsrv_log_path)}"
            )

        final_listing = binlog_srv.list(config_path)
        assert_response_ok(final_listing, "final list after the restart storm")
        stored_names = {r["name"] for r in final_listing.get("result", [])}
        missing = set(server_binlogs) - stored_names
        if missing:
            raise TestFailure(f"binlog files present on the server but missing from storage: {sorted(missing)}")
        LOG.info("[%s] all %d server binlog file(s) are present in storage", NAME, len(server_binlogs))

        LOG.info("[%s] verifying final full GTID coverage via search_by_gtid_set", NAME)
        search_result = binlog_srv.search_by_gtid_set(config_path, gtid_final)
        assert_response_ok(search_result, "final search_by_gtid_set for the fully executed GTID set")

        LOG.info("[%s] verifying final search_by_timestamp", NAME)
        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
        ts_result = binlog_srv.search_by_timestamp(config_path, now_iso)
        assert_response_ok(ts_result, "final search_by_timestamp")

        LOG.info("[%s] PASSED", NAME)


def main() -> int:
    args = build_parser().parse_args()
    ok = PullRestartResilienceScenario(args, name=NAME).run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
