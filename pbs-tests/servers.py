"""Process/connection wrapper classes for the MySQL server and
binlog_server, plus resilience helpers layered on top of BinlogServer.

A leaf module from the scenario framework's point of view: it only
imports util.py, never setup.py -- setup.py builds scenario setup on top
of these classes, not the other way around.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional

from util import LOG, ORPHAN_INDEX_ERROR_MARKER, TestFailure, find_and_repair_orphaned_binlog, run, tail_log_file


class _ServerAdminMixin:
    """SQL-level helpers shared between a self-managed mysqld and an already
    running server; subclasses only need to implement `sql()`."""

    def sql(self, statement: str, database: Optional[str] = None) -> str:
        raise NotImplementedError

    def show_binary_logs(self) -> list:
        out = self.sql("SHOW BINARY LOGS")
        return [line.split("\t")[0] for line in out.splitlines() if line.strip()]

    def gtid_executed(self) -> str:
        return self.sql("SELECT @@GLOBAL.gtid_executed").strip()

    def _create_user(self, user: str, password: str) -> None:
        try:
            self.sql(
                f"CREATE USER IF NOT EXISTS '{user}'@'%' "
                f"IDENTIFIED WITH mysql_native_password BY '{password}'"
            )
        except TestFailure:
            LOG.warning(
                "mysql_native_password unavailable on this server; falling back to the "
                "default auth plugin for '%s'@'%%'. If that ends up being "
                "caching_sha2_password, TCP connections without SSL may fail with a "
                "public-key-retrieval error -- generate_config.py has no option for that, "
                "so in that case either point basedir/connection at a server with "
                "mysql_native_password available, or configure SSL for this test.",
                user,
            )
            self.sql(f"CREATE USER IF NOT EXISTS '{user}'@'%' IDENTIFIED BY '{password}'")

    def setup_test_accounts(self) -> None:
        from setup import REPL_PASSWORD, REPL_USER, SBTEST_DB, SBTEST_PASSWORD, SBTEST_USER

        self._create_user(REPL_USER, REPL_PASSWORD)
        self.sql(f"GRANT REPLICATION SLAVE ON *.* TO '{REPL_USER}'@'%'")
        self.sql(f"CREATE DATABASE IF NOT EXISTS {SBTEST_DB}")
        self._create_user(SBTEST_USER, SBTEST_PASSWORD)
        self.sql(f"GRANT ALL PRIVILEGES ON {SBTEST_DB}.* TO '{SBTEST_USER}'@'%'")
        self.sql("FLUSH PRIVILEGES")

    def teardown_test_accounts(self) -> None:
        """Drops exactly what setup_test_accounts() created: the sbtest
        database (and every table a scenario put in it, sysbench-driven or
        raw-SQL) plus the repl/sbtest accounts. Only meaningful for
        ExistingServer (SKIP_SERVER_SETUP=1): a throwaway MysqldServer's
        entire datadir is already disposed of the same way regardless (wiped
        at the start of the next run), so it never calls this -- but an
        already-running, persistent, possibly-shared server has nothing else
        that ever removes this run's data, so it would otherwise accumulate
        across every run against it."""
        from setup import REPL_USER, SBTEST_DB, SBTEST_USER

        self.sql(f"DROP DATABASE IF EXISTS {SBTEST_DB}")
        self.sql(f"DROP USER IF EXISTS '{REPL_USER}'@'%'")
        self.sql(f"DROP USER IF EXISTS '{SBTEST_USER}'@'%'")


class ExistingServer(_ServerAdminMixin):
    """Adapter for an already-running server (SKIP_SERVER_SETUP=1): connects
    over TCP with the admin credentials from the test config's 'connection'
    section instead of starting/stopping a mysqld of our own."""

    def __init__(self, mysql_bin: str, host: str, port: int, user: str, password: str):
        self.mysql_bin = mysql_bin
        self.host = host
        self.port = port
        self.user = user
        self.password = password

    def initialize(self) -> None:
        pass

    def start(self) -> None:
        LOG.info("SKIP_SERVER_SETUP=1: using existing server at %s:%s as '%s'", self.host, self.port, self.user)

    def stop(self) -> None:
        # Unlike MysqldServer, this connection points at an
        # already-running, persistent server we don't own; nothing else
        # ever removes the sbtest database/accounts setup_test_accounts()
        # created (or the tables/rows the scenario put in them), so they'd
        # otherwise accumulate across every run against it. Best-effort
        # (like cleanup_s3_storage_path()): a failure here is logged but
        # never affects the test's recorded result.
        try:
            self.teardown_test_accounts()
        except TestFailure as exc:
            LOG.warning(
                "SKIP_SERVER_SETUP=1: could not clean up test accounts/database on %s:%s: %s",
                self.host, self.port, exc,
            )

    def sql(self, statement: str, database: Optional[str] = None) -> str:
        cmd = [self.mysql_bin, f"--host={self.host}", f"--port={self.port}", f"--user={self.user}", "-N", "-B"]
        if database:
            cmd.append(database)
        cmd += ["-e", statement]
        env = os.environ.copy()
        if self.password:
            env["MYSQL_PWD"] = self.password
        try:
            result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        except subprocess.TimeoutExpired as exc:
            raise TestFailure(f"admin SQL command timed out after 60s: {statement}") from exc
        if result.returncode != 0:
            raise TestFailure(f"admin SQL command failed (exit {result.returncode}): {statement}\n{result.stderr[-4000:]}")
        return result.stdout


class MysqldServer(_ServerAdminMixin):
    def __init__(self, basedir: Path, workdir: Path, port: int, gtid_mode: bool, max_binlog_size: str):
        self.basedir = basedir
        self.datadir = workdir / "data"
        self.port = port
        self.gtid_mode = gtid_mode
        self.max_binlog_size = max_binlog_size
        self.socket_path = self.datadir / "mysqld.sock"
        self.pid_file = self.datadir / "mysqld.pid"
        self.error_log = workdir / "mysqld.err"
        self.process: Optional[subprocess.Popen] = None
        self.mysqld_bin = basedir / "bin" / "mysqld"
        self.mysql_bin = basedir / "bin" / "mysql"

    def initialize(self) -> None:
        self.datadir.mkdir(parents=True, exist_ok=True)
        LOG.info("initializing datadir at %s", self.datadir)
        run(
            [
                str(self.mysqld_bin), "--no-defaults", "--initialize-insecure",
                f"--basedir={self.basedir}", f"--datadir={self.datadir}", f"--log-error={self.error_log}",
            ],
            capture=True, timeout=300,
        )

    def start(self) -> None:
        cmd = [
            str(self.mysqld_bin), "--no-defaults",
            f"--basedir={self.basedir}", f"--datadir={self.datadir}",
            f"--socket={self.socket_path}", f"--port={self.port}",
            "--bind-address=127.0.0.1",
            f"--pid-file={self.pid_file}", f"--log-error={self.error_log}",
            "--server-id=1",
            f"--log-bin=mysql-bin",
            "--binlog-format=ROW",
            f"--max-binlog-size={self.max_binlog_size}",
            f"--gtid-mode={'ON' if self.gtid_mode else 'OFF'}",
        ]
        if self.gtid_mode:
            cmd.append("--enforce-gtid-consistency=ON")
        LOG.info("starting mysqld on port %s (gtid_mode=%s)", self.port, self.gtid_mode)
        self.process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self._wait_ready()

    def _wait_ready(self, timeout: float = 60) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            assert self.process is not None
            if self.process.poll() is not None:
                raise TestFailure(
                    f"mysqld exited early (code {self.process.returncode}); see {self.error_log}"
                )
            probe = subprocess.run(
                [str(self.mysql_bin), f"--socket={self.socket_path}", "-uroot", "-e", "SELECT 1"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if probe.returncode == 0:
                return
            time.sleep(0.5)
        raise TestFailure(f"mysqld did not become ready within {timeout}s; see {self.error_log}")

    def sql(self, statement: str, database: Optional[str] = None) -> str:
        cmd = [str(self.mysql_bin), f"--socket={self.socket_path}", "-uroot", "-N", "-B"]
        if database:
            cmd.append(database)
        cmd += ["-e", statement]
        return run(cmd, capture=True, timeout=60).stdout

    def stop(self) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            LOG.info("stopping mysqld (pid %s)", self.process.pid)
            self.process.terminate()
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                LOG.warning("mysqld did not stop in time, killing it")
                self.process.kill()
                self.process.wait(timeout=10)
        self.process = None


class Sysbench:
    def __init__(
        self, binary: str, host: str, port: int, user: str, password: str, database: str,
        tables: int, table_size: int, threads: int, script: str = "oltp_read_write",
    ):
        self.binary = binary
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.tables = tables
        self.table_size = table_size
        self.threads = threads
        self.script = script

    def _base_cmd(self) -> list:
        return [
            self.binary, self.script,
            "--db-driver=mysql",
            f"--mysql-host={self.host}", f"--mysql-port={self.port}",
            f"--mysql-user={self.user}", f"--mysql-password={self.password}",
            f"--mysql-db={self.database}",
            f"--tables={self.tables}", f"--table-size={self.table_size}",
            f"--threads={self.threads}",
        ]

    def prepare(self) -> None:
        run(self._base_cmd() + ["prepare"], capture=True, timeout=300)

    def run_blocking(self, duration: int) -> None:
        run(self._base_cmd() + [f"--time={duration}", "run"], capture=True, timeout=duration + 60)

    def run_background(self, duration: int) -> subprocess.Popen:
        return subprocess.Popen(
            self._base_cmd() + [f"--time={duration}", "run"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


class BinlogServer:
    def __init__(self, binary: str):
        self.binary = binary

    def _run_json(self, mode: str, config_path: Path, value: Optional[str] = None, timeout: float = 120) -> dict:
        cmd = [self.binary, mode, str(config_path)]
        if value is not None:
            cmd.append(value)
        try:
            result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            # Used inside catch-up polling loops -- report as "not ready yet"
            # rather than raising, so a single slow call doesn't abort the wait.
            return {"status": "error", "message": f"{mode} timed out after {timeout}s", "_exit_code": None}
        stdout = result.stdout.strip()
        try:
            payload = json.loads(stdout) if stdout else {}
        except json.JSONDecodeError:
            payload = {"status": "error", "message": f"unparseable output: {stdout!r}"}
        payload["_exit_code"] = result.returncode
        return payload

    def list(self, config_path: Path, timeout: float = 120) -> dict:
        return self._run_json("list", config_path, timeout=timeout)

    def search_by_gtid_set(self, config_path: Path, gtid_set: str, timeout: float = 120) -> dict:
        return self._run_json("search_by_gtid_set", config_path, gtid_set, timeout=timeout)

    def search_by_timestamp(self, config_path: Path, timestamp: str, timeout: float = 120) -> dict:
        return self._run_json("search_by_timestamp", config_path, timestamp, timeout=timeout)

    def purge_binlogs(self, config_path: Path, binlog_name: str, timeout: float = 120) -> dict:
        return self._run_json("purge_binlogs", config_path, binlog_name, timeout=timeout)

    def fetch(self, config_path: Path, timeout: float = 600) -> None:
        LOG.info("running fetch against %s", config_path)
        try:
            result = subprocess.run(
                [self.binary, "fetch", str(config_path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise TestFailure(f"fetch did not finish within {timeout}s") from exc
        if result.returncode != 0:
            raise TestFailure(f"fetch failed (exit {result.returncode}): {result.stderr[-4000:]}")

    def start_pull(self, config_path: Path) -> subprocess.Popen:
        LOG.info("starting pull against %s", config_path)
        return subprocess.Popen([self.binary, "pull", str(config_path)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop_pull(self, process: subprocess.Popen, timeout: float = 60) -> int:
        if process.poll() is None:
            LOG.info("stopping pull (pid %s)", process.pid)
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                LOG.warning("pull did not stop gracefully in time, killing it")
                process.kill()
                process.wait(timeout=10)
        return process.returncode


def start_pull_with_recovery(
    binlog_srv: "BinlogServer", config_path: Path, storage_dir: Path, binsrv_log_path: Path,
    *, wait_seconds: float = 1.0,
) -> subprocess.Popen:
    """Start pull; if it immediately dies with the known post-hard-kill
    orphaned-binlog signature, repair storage and retry once. If it dies for
    any other reason, or repair wasn't possible/applicable, just return the
    dead process as usual -- the caller's existing poll()-based failure
    handling (with the binsrv.log tail already in its message) reports it."""
    process = binlog_srv.start_pull(config_path)
    time.sleep(wait_seconds)
    if process.poll() is None:
        return process

    if ORPHAN_INDEX_ERROR_MARKER not in tail_log_file(binsrv_log_path):
        return process

    if find_and_repair_orphaned_binlog(storage_dir) is None:
        return process

    LOG.warning("retrying pull now that the orphaned binlog file has been removed")
    process = binlog_srv.start_pull(config_path)
    time.sleep(wait_seconds)
    return process


def run_binlog_command_with_recovery(call, storage_dir: Path, context: str) -> dict:
    """Run a BinlogServer JSON-returning call (list/search_by_*/purge_binlogs);
    if it fails with the known post-hard-kill orphaned-binlog signature,
    repair storage and retry once. Otherwise returns the (possibly failing)
    result as-is for the caller's normal handling."""
    result = call()
    if result.get("status") in ("success", "warning"):
        return result
    if ORPHAN_INDEX_ERROR_MARKER not in str(result.get("message", "")):
        return result
    if find_and_repair_orphaned_binlog(storage_dir) is None:
        return result

    LOG.warning("retrying %s now that the orphaned binlog file has been removed", context)
    return call()


def gtid_since_baseline(server, baseline: str) -> str:
    """Returns GTID_SUBTRACT(@@GLOBAL.gtid_executed, baseline): only the
    GTIDs generated since `baseline` was captured (normally via
    server.gtid_executed(), at the very start of a scenario, before any
    workload runs), computed server-side via MySQL's own GTID set algebra.

    Any search_by_gtid_set/wait_for_pull_catch_up target should be built
    this way rather than from the server's raw, full @@GLOBAL.gtid_executed:
    under SKIP_SERVER_SETUP=1 (an already-running, persistent, possibly
    shared server), that full set can include historical transactions
    whose binlogs were already purged before this test ever started --
    this run's storage can never cover those, so a target built on the
    full set would time out/fail despite every event this test itself
    generated having been captured correctly."""
    return server.sql(f"SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '{baseline}')").strip()


def wait_for_pull_catch_up(
    binlog_srv: "BinlogServer", config_path: Path, *, use_rewrite: bool,
    gtid_target: str, server_binlogs: list, timeout: float, poll_interval: float,
) -> bool:
    """Poll storage until it actually covers everything the server has, instead
    of guessing a fixed sleep -- only then is it safe to stop `pull`.

    Each search_by_gtid_set()/list() call below is capped at whatever's
    left of `timeout`, not left to BinlogServer's own fixed per-command
    default (120s) -- otherwise a single slow/hung call could by itself
    block well past `timeout` (e.g. a 10s `timeout` still blocking ~120s),
    making `timeout` not an actual upper bound on how long this function
    can run."""
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return False
        if use_rewrite:
            result = binlog_srv.search_by_gtid_set(config_path, gtid_target, timeout=remaining)
            if result.get("status") == "success":
                return True
        else:
            listing = binlog_srv.list(config_path, timeout=remaining)
            if listing.get("status") in ("success", "warning"):
                stored_names = {r["name"] for r in listing.get("result", [])}
                if set(server_binlogs) <= stored_names:
                    return True
        if time.time() >= deadline:
            return False
        time.sleep(poll_interval)
