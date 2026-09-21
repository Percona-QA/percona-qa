#!/usr/bin/env python3
"""Runner for the percona-binlog-server QA test suite under tests/.

Runs one or more of the standalone tests/*.py scripts -- the same way a
user would invoke one directly -- either sequentially or across a small
pool of parallel workers, and reports a pass/fail summary.

Test selection: --tests (alias --test) takes a comma-separated list, e.g.
--tests=gtid_rewrite_test,pull_purge_resume_test. A name not already
ending in ".py" has ".py" appended (so "gtid_rewrite_test" and
"gtid_rewrite_test.py" both resolve to tests/gtid_rewrite_test.py); a name
that already ends in ".py" is used as-is, with nothing appended. Every
named test must exist under tests/ as its own script (util.py, servers.py,
and setup.py -- the shared framework modules every test imports -- live
in pbs-tests/ itself, not under tests/, and are rejected by name even if
someone types one) -- if any doesn't, the run fails immediately, before
anything is executed, reporting every name that could not be found.
--tests=all (or any name list that includes "all") runs every *_test.py
script under tests/, same as --run-all-tests below.

--run-all-tests runs every *_test.py script under tests/ regardless of
--tests/--test -- whether it was given at all, and regardless of what
value it was given. Either --tests/--test or --run-all-tests must be
given.

Sequential (--parallel not given, or given as 0 -- "parallel not set"):
tests run one after another, all sharing --log-dir itself as their
working directory (each test's own setup_scenario() wipes/recreates
./logs there at the start of its own run) -- not one permanent
subdirectory per test, which would otherwise pile up indefinitely as
more tests get added, most of it for tests that passed and left nothing
worth keeping.

Parallel (--parallel=N, clamped to [1, 4] -- 1 is the minimum once
parallel mode is on, 4 the maximum regardless of how high N is):
up to N tests run concurrently across worker slots w1..wN under
--log-dir. Each slot is a working directory reused across the run: as
soon as a test occupying a slot finishes, the next queued test claims
that slot (and thus that slot's ./logs, including the mysqld datadir
under ./logs/data) for its own run.

In both modes, a test's working directory (--log-dir itself in
sequential mode, w<N> in parallel mode) is reused by whichever test runs
there next. Because of that, a failing test's ./logs and its own
per-test log file are copied to <working-dir>/failed_logs/<test-name>/
before that directory is reused -- otherwise the next test to run there
would wipe/overwrite that evidence before anyone could look at it. This
copy is best-effort and never affects the test's recorded result; its
path (when there is one) is included in the console summary and
summary.json.

-e/--encryption forces storage encryption on for every test in this run,
regardless of the "encryption" setting in the test config file (it only
turns encryption on; it never turns it off if the config file already has
it on). This is done by writing a copy of the config file with
"encryption" forced to 1 under --log-dir and pointing every test at that
copy via --config; without -e, each test is pointed at --config (or its
own default) unmodified.

Each test's own console output is captured to a per-run log file rather
than streamed live -- with parallel workers, interleaved live output from
multiple tests would be unreadable. Tail a specific test's log file for a
live view of that test while the run is in progress. A machine-readable
summary.json is also written to --log-dir, and everything this runner
itself prints to the console (not each test's own captured output) is
also copied to test_runner.log there.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import logging
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import List, Optional

LOG = logging.getLogger("pbs_test_runner")

PBS_DIR = Path(__file__).resolve().parent
TESTS_DIR = PBS_DIR / "tests"
DEFAULT_CONFIG_PATH = PBS_DIR / "config.json"
DEFAULT_LOG_DIR = PBS_DIR / "runner_logs"

MIN_PARALLEL_WORKERS = 1
MAX_PARALLEL_WORKERS = 4

# Kept in sync with setup.py's own SKIP_SERVER_SETUP_ENV/skip_server_setup_enabled()
# by name and value, not by import -- this runner is deliberately standalone
# and never imports setup.py/servers.py/util.py.
SKIP_SERVER_SETUP_ENV = "SKIP_SERVER_SETUP"

# Shared framework modules (live in pbs-tests/, not tests/) -- rejected by name
# even though they'd never actually be found under tests/, since that
# gives a clearer reason than a bare "no such file" would.
FRAMEWORK_MODULES = {"util.py", "servers.py", "setup.py"}

# --tests/--test value that means "every test", same as --run-all-tests.
ALL_TESTS_KEYWORD = "all"


class TestRunnerFailure(Exception):
    """Raised for a runner-level problem (bad args, missing test/config)."""


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
    )


def add_file_log_handler(log_dir: Path, verbose: bool) -> None:
    """Mirrors everything this runner itself logs to the console (not each
    test's own captured output, which already goes to its own log file)
    into test_runner.log under log_dir, so the whole run's own narrative --
    including the final summary -- is preserved on disk exactly as it
    appeared on screen."""
    handler = logging.FileHandler(log_dir / "test_runner.log")
    handler.setLevel(logging.DEBUG if verbose else logging.INFO)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(message)s"))
    logging.getLogger().addHandler(handler)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument(
        "--tests", "--test", dest="tests", default=None,
        help="comma-separated test names, e.g. gtid_rewrite_test,pull_purge_resume_test "
             "(.py appended automatically unless already present); 'all' runs every test, "
             "same as --run-all-tests. Required unless --run-all-tests is given.",
    )
    p.add_argument(
        "--run-all-tests", action="store_true",
        help="run every *_test.py under tests/, regardless of --tests/--test",
    )
    p.add_argument(
        "-e", "--encryption", action="store_true",
        help="force storage encryption on for every test run, overriding the config file's setting",
    )
    p.add_argument(
        "--parallel", type=int, default=0,
        help=(
            "number of parallel workers: 0 = parallel not set (sequential, the default), "
            "1 = minimum once parallel mode is on, values above 4 are truncated to 4"
        ),
    )
    p.add_argument(
        "--config", default=str(DEFAULT_CONFIG_PATH),
        help="test config file forwarded to every test as --config (default: %(default)s)",
    )
    p.add_argument(
        "--log-dir", default=str(DEFAULT_LOG_DIR),
        help="main log directory, cleared and recreated at the start of the run (default: %(default)s)",
    )
    p.add_argument("--verbose", action="store_true")
    return p


def normalize_parallel(requested: int) -> int:
    """0 stays 0 ("parallel not set" -> sequential). Otherwise clamp to
    [MIN_PARALLEL_WORKERS, MAX_PARALLEL_WORKERS]."""
    if requested < 0:
        raise TestRunnerFailure(f"--parallel must be >= 0, got {requested}")
    if requested == 0:
        return 0
    if os.environ.get(SKIP_SERVER_SETUP_ENV, "0") == "1":
        raise TestRunnerFailure(
            f"--parallel={requested} is not supported with {SKIP_SERVER_SETUP_ENV}=1: every test would "
            f"target the same already-running server instead of its own throwaway mysqld, so concurrent "
            f"workers would race on the same accounts/tables/binlogs -- run sequentially (--parallel not "
            f"given, or 0) instead"
        )
    if requested > MAX_PARALLEL_WORKERS:
        LOG.warning(
            "--parallel=%d exceeds the maximum of %d workers; truncating to %d",
            requested, MAX_PARALLEL_WORKERS, MAX_PARALLEL_WORKERS,
        )
        return MAX_PARALLEL_WORKERS
    return max(requested, MIN_PARALLEL_WORKERS)


def discover_all_tests(tests_dir: Path) -> List[Path]:
    return sorted(tests_dir.glob("*_test.py"))


def resolve_tests(raw_names: List[str], tests_dir: Path) -> List[Path]:
    """Resolve each requested name to a script under tests_dir. Validates
    every name before returning anything -- a run is only ever all-or-nothing,
    so a typo late in the list is reported alongside everything else wrong,
    rather than after already running the earlier tests. If "all" appears
    anywhere in the list, every other name is ignored and every test under
    tests_dir is returned instead, same as --run-all-tests."""
    names = [raw.strip() for raw in raw_names if raw.strip()]

    if any(name.lower() == ALL_TESTS_KEYWORD for name in names):
        if len(names) > 1:
            LOG.warning(
                "--tests/--test included %r alongside other names; running every test under %s instead",
                ALL_TESTS_KEYWORD, tests_dir,
            )
        tests = discover_all_tests(tests_dir)
        if not tests:
            raise TestRunnerFailure(f"no *_test.py files found under {tests_dir}")
        return tests

    resolved: List[Path] = []
    problems: List[str] = []
    for name in names:
        filename = name if name.endswith(".py") else f"{name}.py"
        if filename in FRAMEWORK_MODULES:
            problems.append(f"{name!r}: {filename} is shared test infrastructure, not a runnable test")
            continue
        candidate = Path(filename)
        if candidate.name != filename:
            problems.append(f"{name!r}: test names must not contain path components")
            continue
        path = tests_dir / candidate
        if not path.is_file():
            problems.append(f"{name!r}: no such test file: {path}")
            continue
        resolved.append(path)

    if not resolved and not problems:
        raise TestRunnerFailure("--tests/--test named no tests")
    if problems:
        for problem in problems:
            LOG.error("%s", problem)
        raise TestRunnerFailure(f"{len(problems)} named test(s) do not exist; see above")
    return resolved


def build_effective_config(config_path: Path, *, force_encryption: bool, log_dir: Path) -> Path:
    """Returns config_path unchanged unless force_encryption is set, in which
    case a copy with "encryption" forced to 1 is written under log_dir and
    that copy's path is returned instead."""
    if not config_path.is_file():
        raise TestRunnerFailure(f"test config file not found: {config_path}")
    if not force_encryption:
        return config_path

    try:
        data = json.loads(config_path.read_text())
    except json.JSONDecodeError as exc:
        raise TestRunnerFailure(f"{config_path}: invalid JSON: {exc}") from exc

    data["encryption"] = 1
    effective_path = log_dir / "effective_config.json"
    fd = os.open(effective_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2))
    # This copy carries over config_path's plaintext credentials (DB
    # password, S3 secret key, etc.) verbatim.
    LOG.info("encryption forced on: writing %s (based on %s) for this run", effective_path, config_path)
    return effective_path


@dataclasses.dataclass
class TestResult:
    name: str
    slot: str
    returncode: Optional[int]
    duration: float
    log_path: Path
    work_dir: Path
    failed_logs_path: Optional[Path] = None


def run_one_test(test_path: Path, *, cwd: Path, extra_args: List[str], log_file: Path) -> "tuple[int, float]":
    cwd.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(test_path)] + extra_args
    start = time.time()
    with open(log_file, "w") as f:
        f.write(f"+ {' '.join(cmd)}\n(cwd={cwd})\n\n")
        f.flush()
        proc = subprocess.run(cmd, cwd=str(cwd), stdout=f, stderr=subprocess.STDOUT)
    duration = time.time() - start
    return proc.returncode, duration


def preserve_failed_logs(run_dir: Path, name: str, log_file: Path) -> Optional[Path]:
    """Copies a failed test's logs into run_dir/failed_logs/<name>/ before
    run_dir is reused by another test, and returns that path (or None on
    failure). run_dir is a shared working directory across the whole run
    -- log_dir itself in sequential mode, or a w<N> slot in parallel mode
    -- so its ./logs (and the failed test's own per-test log file) get
    wiped or overwritten by whichever test runs there next; without this,
    a failure's evidence would be gone the moment that next test starts.
    Best-effort: a problem here is logged as a warning and never allowed
    to affect the actual test result or the rest of the run."""
    try:
        failed_dir = run_dir / "failed_logs" / name
        if failed_dir.exists():
            shutil.rmtree(failed_dir)
        failed_dir.mkdir(parents=True)

        scenario_logs = run_dir / "logs"
        if scenario_logs.is_dir():
            shutil.copytree(scenario_logs, failed_dir / "logs")
        if log_file.is_file():
            shutil.copy2(log_file, failed_dir / log_file.name)
        LOG.warning("[%s] preserved failed %s's logs at %s", run_dir.name, name, failed_dir)
        return failed_dir
    except Exception as exc:  # noqa: BLE001 - best-effort preservation, must never mask the real result
        LOG.warning("[%s] could not preserve failed %s's logs: %s", run_dir.name, name, exc)
        return None


def run_sequential(tests: List[Path], *, log_dir: Path, extra_args: List[str]) -> List[TestResult]:
    """Every test runs with log_dir itself as its working directory --
    log_dir is the sequential "workdir", reused by every test in turn
    (each test's own setup_scenario() wipes/recreates ./logs at the start
    of its own run), rather than each test getting its own permanent
    <log-dir>/<test-name>/ subdirectory -- that would otherwise pile up
    one directory per test, most of them for tests that passed and left
    nothing worth keeping, as more tests get added over time. A failing
    test's logs are preserved the same way parallel mode preserves a
    worker slot's, and for the same reason: the next test's own setup
    would otherwise wipe them."""
    results: List[TestResult] = []
    for test_path in tests:
        name = test_path.stem
        log_file = log_dir / f"{name}.log"

        LOG.info("running %s", name)
        rc, duration = run_one_test(test_path, cwd=log_dir, extra_args=extra_args, log_file=log_file)
        status = "PASSED" if rc == 0 else f"FAILED (exit {rc})"
        LOG.info("%s %s in %.1fs (log: %s)", name, status, duration, log_file)
        failed_logs_path = None
        if rc != 0:
            failed_logs_path = preserve_failed_logs(log_dir, name, log_file)
        results.append(TestResult(name, "seq", rc, duration, log_file, log_dir, failed_logs_path))
    return results


def run_parallel(tests: List[Path], *, log_dir: Path, workers: int, extra_args: List[str]) -> List[TestResult]:
    slot_ids = [f"w{i}" for i in range(1, workers + 1)]
    for slot in slot_ids:
        slot_dir = log_dir / slot
        if slot_dir.exists():
            shutil.rmtree(slot_dir)
        slot_dir.mkdir(parents=True)

    free_slots: "queue.Queue[str]" = queue.Queue()
    for slot in slot_ids:
        free_slots.put(slot)

    results: List[TestResult] = []
    results_lock = threading.Lock()

    def worker(test_path: Path) -> None:
        slot = free_slots.get()
        try:
            name = test_path.stem
            slot_dir = log_dir / slot
            log_file = slot_dir / f"{name}.log"
            LOG.info("[%s] running %s", slot, name)
            rc, duration = run_one_test(test_path, cwd=slot_dir, extra_args=extra_args, log_file=log_file)
            status = "PASSED" if rc == 0 else f"FAILED (exit {rc})"
            LOG.info("[%s] %s %s in %.1fs (log: %s)", slot, name, status, duration, log_file)
            failed_logs_path = None
            if rc != 0:
                # Must finish before this slot is freed (finally, below) --
                # otherwise the next test queued into this slot can start
                # wiping ./logs before the copy is done.
                failed_logs_path = preserve_failed_logs(slot_dir, name, log_file)
            with results_lock:
                results.append(TestResult(name, slot, rc, duration, log_file, slot_dir, failed_logs_path))
        finally:
            free_slots.put(slot)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(worker, test_path) for test_path in tests]
        for future in concurrent.futures.as_completed(futures):
            future.result()

    order = {test_path.stem: i for i, test_path in enumerate(tests)}
    results.sort(key=lambda r: order.get(r.name, 0))
    return results


def write_summary_json(results: List[TestResult], log_dir: Path) -> None:
    payload = [
        {
            "name": r.name,
            "slot": r.slot,
            "returncode": r.returncode,
            "passed": r.returncode == 0,
            "duration_seconds": round(r.duration, 1),
            "log_path": str(r.log_path),
            "work_dir": str(r.work_dir),
            "failed_logs_path": str(r.failed_logs_path) if r.failed_logs_path else None,
        }
        for r in results
    ]
    (log_dir / "summary.json").write_text(json.dumps(payload, indent=2))


def print_summary(results: List[TestResult], log_dir: Path) -> int:
    name_width = max((len(r.name) for r in results), default=4)
    passed = sum(1 for r in results if r.returncode == 0)

    LOG.info("=" * 78)
    LOG.info("SUMMARY (log directory: %s)", log_dir)
    for r in results:
        status = "PASSED" if r.returncode == 0 else f"FAILED (exit {r.returncode})"
        LOG.info("  %-*s  [%-3s]  %-18s  %7.1fs  %s", name_width, r.name, r.slot, status, r.duration, r.log_path)
        if r.failed_logs_path:
            LOG.info("  %-*s          preserved logs: %s", name_width, "", r.failed_logs_path)
    LOG.info("%d/%d test(s) passed", passed, len(results))
    LOG.info("=" * 78)

    return 0 if passed == len(results) else 1


def main() -> int:
    args = build_parser().parse_args()
    configure_logging(args.verbose)

    try:
        if args.run_all_tests:
            tests = discover_all_tests(TESTS_DIR)
            if not tests:
                raise TestRunnerFailure(f"no *_test.py files found under {TESTS_DIR}")
        elif args.tests:
            tests = resolve_tests(args.tests.split(","), TESTS_DIR)
        else:
            raise TestRunnerFailure("either --tests/--test or --run-all-tests must be given")
    except TestRunnerFailure as exc:
        LOG.error("%s", exc)
        return 1

    log_dir = Path(args.log_dir).resolve()
    config_path = Path(args.config).resolve()
    # log_dir is about to be wiped and recreated below. If --config was
    # (deliberately or accidentally) pointed at a file somewhere under it,
    # that delete would take the config file down with it before
    # build_effective_config() ever gets to read it -- turning an
    # otherwise-valid invocation into a confusing "test config file not
    # found". Reject that combination up front, before anything is deleted.
    try:
        config_path.relative_to(log_dir)
        config_nested_in_log_dir = True
    except ValueError:
        config_nested_in_log_dir = False
    if config_nested_in_log_dir:
        LOG.error(
            "--config %s is located under --log-dir %s, which is deleted and recreated at the "
            "start of every run -- point --config somewhere outside --log-dir",
            config_path, log_dir,
        )
        return 1

    if log_dir.exists():
        shutil.rmtree(log_dir)
    log_dir.mkdir(parents=True)
    add_file_log_handler(log_dir, args.verbose)
    LOG.info("runner log directory: %s", log_dir)

    try:
        workers = normalize_parallel(args.parallel)
    except TestRunnerFailure as exc:
        LOG.error("%s", exc)
        return 1

    try:
        effective_config = build_effective_config(
            config_path, force_encryption=args.encryption, log_dir=log_dir,
        )
    except TestRunnerFailure as exc:
        LOG.error("%s", exc)
        return 1

    extra_args = ["--config", str(effective_config)]

    if workers == 0:
        LOG.info("running %d test(s) sequentially", len(tests))
        results = run_sequential(tests, log_dir=log_dir, extra_args=extra_args)
    else:
        LOG.info("running %d test(s) across %d parallel worker(s)", len(tests), workers)
        results = run_parallel(tests, log_dir=log_dir, workers=workers, extra_args=extra_args)

    write_summary_json(results, log_dir)
    return print_summary(results, log_dir)


if __name__ == "__main__":
    sys.exit(main())
