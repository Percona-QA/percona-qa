"""Core PostgreSQL cluster lifecycle management."""
import getpass
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

log = logging.getLogger(__name__)

# The ``io_method`` GUC exists only from PostgreSQL 18 onward (worker, sync,
# io_uring). Earlier majors ignore the setting in this harness.
PG_IO_METHOD_MIN_MAJOR = 18
IO_METHOD_VALUES: Tuple[str, ...] = ("worker", "sync", "io_uring")
# Placeholder passed to tests on PG < 18; never written to postgresql.conf.
IO_METHOD_LEGACY_PLACEHOLDER = "worker"

# Leading digits of the version token from ``postgres --version``.
# Handles ``17.2``, ``18.4.1``, ``19beta2``, ``19rc1``, ``19devel``.
_POSTGRES_MAJOR_RE = re.compile(r"^(\d+)")


def parse_postgres_major_version(version_output: str) -> int:
    """
    Extract the integer major from ``postgres --version`` stdout.

    Examples::

        postgres (PostgreSQL) 17.2     → 17
        postgres (PostgreSQL) 18.4     → 18
        postgres (PostgreSQL) 19beta2  → 19
        postgres (PostgreSQL) 19rc1    → 19
    """
    text = (version_output or "").strip()
    if not text:
        raise ValueError("empty postgres --version output")

    # Usual form: ``postgres (PostgreSQL) <version>``
    parts = text.split()
    candidates = []
    if len(parts) >= 3:
        candidates.append(parts[2])
    candidates.extend(parts)

    for token in candidates:
        # Strip a leading "v" if present; keep only the major digits.
        token = token.lstrip("vV")
        match = _POSTGRES_MAJOR_RE.match(token)
        if match:
            return int(match.group(1))

    raise ValueError(
        f"could not parse PostgreSQL major version from: {version_output!r}"
    )


def prepend_install_lib_dirs(env: Dict[str, str], *install_roots: Path) -> None:
    """Prepend PREFIX/lib and PREFIX/lib64 to LD_LIBRARY_PATH for each install root.

    Source builds often lack RPATH; without this, binaries from one PostgreSQL
    prefix can load the wrong libpq / ICU from another prefix on LD_LIBRARY_PATH.
    """
    additions: List[str] = []
    for root in install_roots:
        r = Path(root)
        for name in ("lib", "lib64"):
            p = r / name
            if p.is_dir():
                additions.append(str(p))
    if not additions:
        return
    prefix = ":".join(additions)
    key = "LD_LIBRARY_PATH"
    tail = env.get(key, "")
    env[key] = f"{prefix}:{tail}" if tail else prefix


def postgres_major_version(install_dir: Path) -> int:
    """Return major version number for binaries under ``install_dir`` (e.g. 17, 18, 19)."""
    bin_pg = Path(install_dir) / "bin" / "postgres"
    env = os.environ.copy()
    prepend_install_lib_dirs(env, Path(install_dir))
    result = subprocess.run(
        [str(bin_pg), "--version"],
        capture_output=True,
        text=True,
        check=True,
        env=env,
    )
    return parse_postgres_major_version(result.stdout)


def io_method_guc_supported(install_dir: Path) -> bool:
    """True when ``--install-dir`` is PostgreSQL 18+ and the ``io_method`` GUC applies."""
    return postgres_major_version(install_dir) >= PG_IO_METHOD_MIN_MAJOR


def initdb_io_method_args(install_dir: Path, io_method: str) -> List[str]:
    """``initdb --set io_method=…`` only for PostgreSQL 18+."""
    if not io_method_guc_supported(install_dir):
        return []
    return ["--set", f"io_method={io_method}"]


def _kernel_io_uring_disabled() -> Optional[int]:
    """Read ``/proc/sys/kernel/io_uring_disabled`` (Linux only)."""
    proc = Path("/proc/sys/kernel/io_uring_disabled")
    if not proc.is_file():
        return None
    try:
        return int(proc.read_text().strip())
    except (OSError, ValueError):
        return None


def io_uring_system_ready() -> Tuple[bool, List[str]]:
    """
    OS prerequisites for ``io_method=io_uring`` under the current user.

    Matches manual setup in ``docs/io_uring_system_setup.md`` (memlock + sysctl).
    """
    issues: List[str] = []
    if sys.platform != "linux":
        return True, issues

    try:
        import resource

        soft, _hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
        if soft != resource.RLIM_INFINITY:
            issues.append(
                f"memlock soft limit is {soft} bytes (need unlimited); set "
                f"'{getpass.getuser()} soft/hard memlock unlimited' in "
                "/etc/security/limits.conf and re-login (ulimit -l)"
            )
    except (AttributeError, OSError, ValueError):
        pass

    disabled = _kernel_io_uring_disabled()
    if disabled == 1:
        issues.append(
            "kernel.io_uring_disabled=1 (io_uring disabled); "
            "sysctl -w kernel.io_uring_disabled=0"
        )
    elif disabled == 2:
        issues.append(
            "kernel.io_uring_disabled=2 (admin-only); "
            "sysctl -w kernel.io_uring_disabled=0 for non-root users"
        )

    return (len(issues) == 0, issues)


def io_uring_build_supported(install_dir: Path) -> bool:
    """True when installed ``initdb`` accepts ``--set io_method=io_uring``."""
    if not io_method_guc_supported(install_dir):
        return False
    initdb = Path(install_dir) / "bin" / "initdb"
    env = os.environ.copy()
    prepend_install_lib_dirs(env, install_dir)
    with tempfile.TemporaryDirectory(prefix="pg_io_probe_") as td:
        try:
            subprocess.run(
                [str(initdb), "-D", td, "--set", "io_method=io_uring"],
                capture_output=True,
                text=True,
                check=True,
                env=env,
            )
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            return False


def io_uring_runtime_ready(install_dir: Path) -> Tuple[bool, List[str]]:
    """Build **and** system checks for running tests with ``io_uring``."""
    if not io_uring_build_supported(install_dir):
        return (
            False,
            [
                f"PostgreSQL at {install_dir} does not accept "
                "initdb --set io_method=io_uring (not built with liburing?)"
            ],
        )
    ok, issues = io_uring_system_ready()
    return ok, issues


def io_method_usable(install_dir: Path, io_method: str) -> bool:
    """Whether tests may use this ``io_method`` on this install **and** host."""
    if io_method not in IO_METHOD_VALUES and io_method != IO_METHOD_LEGACY_PLACEHOLDER:
        return False
    if not io_method_guc_supported(install_dir):
        return io_method == IO_METHOD_LEGACY_PLACEHOLDER
    if io_method != "io_uring":
        return True
    ready, _issues = io_uring_runtime_ready(install_dir)
    return ready


def io_methods_available(install_dir: Path) -> List[str]:
    """``io_method`` values usable for ``--io-method-matrix`` on this host."""
    if not io_method_guc_supported(install_dir):
        return [IO_METHOD_LEGACY_PLACEHOLDER]
    return [m for m in IO_METHOD_VALUES if io_method_usable(install_dir, m)]


def io_method_param_values(
    install_dir: Path,
    *,
    matrix: bool,
    single: str,
) -> List[str]:
    """
    Values for the pytest ``io_method`` fixture.

    PG 18+ matrix: only methods supported by **build and** (for io_uring) **system**.
    """
    if not io_method_guc_supported(install_dir):
        return [IO_METHOD_LEGACY_PLACEHOLDER]
    if matrix:
        return io_methods_available(install_dir)
    return [single]


def io_uring_status_lines(install_dir: Path) -> List[str]:
    """Diagnostic lines for ``pytest --report-header`` or manual inspection."""
    lines: List[str] = []
    if not io_method_guc_supported(install_dir):
        lines.append("io_uring: N/A (PostgreSQL < 18)")
        return lines
    if not io_uring_build_supported(install_dir):
        lines.append(
            "io_uring: not in PostgreSQL build (initdb rejects io_method=io_uring)"
        )
        return lines
    sys_ok, issues = io_uring_system_ready()
    if sys_ok:
        lines.append("io_uring: build OK, system OK (memlock + kernel)")
    else:
        lines.append("io_uring: build OK, system NOT ready — " + "; ".join(issues))
    return lines


def initdb_args_no_data_checksums(install_dir: Path) -> List[str]:
    """initdb flags to disable data checksums when the build defaults them on (PG 18+).

    PostgreSQL 18 enables data checksums by default and accepts ``--no-data-checksums``.
    PostgreSQL 17 and earlier disable checksums by default and **do not** implement
    that flag — passing it would make initdb fail.
    """
    if postgres_major_version(install_dir) >= 18:
        return ["--no-data-checksums"]
    return []


def libpq_superuser() -> str:
    """
    OS user that owns initdb-created clusters in CI (often 'ubuntu'), not always 'postgres'.
    Respect PGUSER if callers intentionally override it.
    """
    return os.environ.get("PGUSER") or getpass.getuser()


class PgCluster:
    """Manages a single PostgreSQL cluster (initdb → start/stop → query)."""

    def __init__(
        self,
        data_dir: Path,
        port: int,
        install_dir: Path,
        socket_dir: Optional[Path] = None,
        io_method: str = "worker",
    ) -> None:
        self.data_dir = Path(data_dir)
        self.port = port
        self.install_dir = Path(install_dir)
        self.bin = self.install_dir / "bin"
        self.socket_dir = Path(socket_dir) if socket_dir else self.data_dir
        self.io_method = io_method
        self._major_version: Optional[int] = None

    # ── lifecycle ─────────────────────────────────────────────────────────

    def initdb(self, extra_args: Optional[List[str]] = None) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        cmd = [str(self.bin / "initdb"), "-D", str(self.data_dir)]
        if extra_args:
            cmd.extend(extra_args)
        self._run(cmd, env_override={})
        log.info("initdb completed at %s", self.data_dir)

    def configure(self, params: Dict[str, str], *, append: bool = True) -> None:
        """Write key=value lines to postgresql.conf."""
        conf = self.data_dir / "postgresql.conf"
        mode = "a" if append else "w"
        with conf.open(mode) as f:
            for k, v in params.items():
                f.write(f"{k} = {v}\n")

    def write_default_config(
        self,
        role: str = "primary",
        extra_params: Optional[Dict[str, str]] = None,
    ) -> None:
        """Mirror write_postgresql_conf() from common.sh."""
        self.socket_dir.mkdir(parents=True, exist_ok=True)
        params: Dict[str, str] = {
            "port": str(self.port),
            "unix_socket_directories": f"'{self.socket_dir}'",
            "listen_addresses": "'*'",
            "logging_collector": "on",
            "log_directory": f"'{self.data_dir}'",
            "log_filename": "'server.log'",
            "log_statement": "'all'",
            "max_wal_senders": "5",
        }
        if self.major_version >= PG_IO_METHOD_MIN_MAJOR:
            params["io_method"] = f"'{self.io_method}'"
        if role == "replica":
            params.update(
                {
                    "wal_level": "replica",
                    "wal_compression": "on",
                    "wal_log_hints": "on",
                    "wal_keep_size": "'512MB'",
                    "max_replication_slots": "2",
                }
            )
        if extra_params:
            params.update(extra_params)
        self.configure(params, append=False)
        # initdb adds include_if_exists = 'postgresql.auto.conf'; a full rewrite above
        # drops it, so recovery / ALTER SYSTEM parameters in auto.conf would be ignored.
        with (self.data_dir / "postgresql.conf").open("a") as f:
            f.write("include_if_exists = 'postgresql.auto.conf'\n")

    def add_hba_entry(self, entry: str) -> None:
        with (self.data_dir / "pg_hba.conf").open("a") as f:
            f.write(f"{entry}\n")

    def start(self, timeout: int = 60) -> None:
        log_file = self.data_dir / "server.log"
        cmd = [
            str(self.bin / "pg_ctl"), "start",
            "-D", str(self.data_dir),
            "-w", "-t", str(timeout),
            "-o", f"-p {self.port} -k {self.socket_dir}",
            "-l", str(log_file),
        ]
        try:
            self._run(
                cmd,
                env_override=self._pgctl_wait_env(),
                capture=True,
            )
        except subprocess.CalledProcessError as e:
            tail = self.read_log(last_n=50)
            out = (e.stdout or "").strip()
            err = (e.stderr or "").strip()
            raise RuntimeError(
                "pg_ctl start failed (exit %d)\n"
                "  cmd     : %s\n"
                "  stdout  : %s\n"
                "  stderr  : %s\n"
                "  log tail: %s\n"
                % (
                    e.returncode,
                    " ".join(cmd),
                    out or "(empty)",
                    err or "(empty)",
                    tail or "(server.log missing or empty)",
                )
            ) from e
        log.info("PostgreSQL started on port %d", self.port)

    def stop(self, mode: str = "fast", timeout: int = 60, check: bool = True) -> None:
        cmd = [
            str(self.bin / "pg_ctl"), "stop",
            "-D", str(self.data_dir),
            "-m", mode, "-w", "-t", str(timeout),
        ]
        self._run(cmd, env_override={}, check=check)
        log.info("PostgreSQL stopped (mode=%s)", mode)

    def restart(self, timeout: int = 60) -> None:
        log_file = self.data_dir / "server.log"
        cmd = [
            str(self.bin / "pg_ctl"), "restart",
            "-D", str(self.data_dir),
            "-w", "-t", str(timeout),
            "-o", f"-p {self.port} -k {self.socket_dir}",
            "-l", str(log_file),
        ]
        try:
            self._run(
                cmd,
                env_override=self._pgctl_wait_env(),
                capture=True,
            )
        except subprocess.CalledProcessError as e:
            tail = self.read_log(last_n=50)
            out = (e.stdout or "").strip()
            err = (e.stderr or "").strip()
            raise RuntimeError(
                "pg_ctl restart failed (exit %d)\n"
                "  cmd     : %s\n"
                "  stdout  : %s\n"
                "  stderr  : %s\n"
                "  log tail: %s\n"
                % (
                    e.returncode,
                    " ".join(cmd),
                    out or "(empty)",
                    err or "(empty)",
                    tail or "(server.log missing or empty)",
                )
            ) from e
        log.info("PostgreSQL restarted on port %d", self.port)

    def reload(self) -> None:
        cmd = [str(self.bin / "pg_ctl"), "reload", "-D", str(self.data_dir)]
        self._run(cmd, env_override={})

    def promote(self, *, wait_seconds: int = 180) -> None:
        cmd = [
            str(self.bin / "pg_ctl"),
            "promote",
            "-D",
            str(self.data_dir),
            "-w",
            "-t",
            str(wait_seconds),
        ]
        self._run(cmd, env_override={})
        log.info("Standby promoted to primary on port %d", self.port)

    def crash(self, timeout: int = 30) -> None:
        """SIGKILL the postmaster and wait for all processes to exit."""
        pid_file = self.data_dir / "postmaster.pid"
        if not pid_file.exists():
            return
        pid = int(pid_file.read_text().splitlines()[0])
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                os.kill(pid, 0)
                time.sleep(0.5)
            except ProcessLookupError:
                break
        pid_file.unlink(missing_ok=True)
        socket_file = self.socket_dir / f".s.PGSQL.{self.port}"
        socket_file.unlink(missing_ok=True)
        log.info("PostgreSQL crashed (SIGKILL) on port %d", self.port)

    def is_ready(self) -> bool:
        env = os.environ.copy()
        prepend_install_lib_dirs(env, self.install_dir)
        result = subprocess.run(
            [
                str(self.bin / "pg_isready"),
                "-h", str(self.socket_dir),
                "-p", str(self.port),
                "-U", libpq_superuser(),
                "-d", "postgres",
            ],
            capture_output=True,
            timeout=5,
            env=env,
        )
        return result.returncode == 0

    def wait_ready(self, timeout: int = 60) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.is_ready():
                return
            time.sleep(1)
        raise TimeoutError(
            f"PostgreSQL on port {self.port} did not become ready in {timeout}s\n"
            f"Data dir : {self.data_dir}\n"
            f"Server log (last 20 lines):\n{self.read_log(last_n=20)}"
        )

    def destroy(self) -> None:
        try:
            self.stop(mode="fast", check=False)
        except Exception:
            pass
        shutil.rmtree(self.data_dir, ignore_errors=True)

    # ── querying ──────────────────────────────────────────────────────────

    def execute(self, sql: str, dbname: str = "postgres") -> str:
        """Run SQL and return stdout as a stripped string."""
        result = self.execute_allow_error(sql, dbname=dbname)
        if result.returncode != 0:
            raise RuntimeError(
                f"psql failed (port={self.port}, db={dbname})\n"
                f"SQL : {sql}\n"
                f"OUT : {result.stdout.strip()}\n"
                f"ERR : {result.stderr.strip()}"
            )
        return result.stdout.strip()

    def execute_allow_error(
        self, sql: str, dbname: str = "postgres"
    ) -> subprocess.CompletedProcess:
        """Run SQL; return CompletedProcess (check=False) for negative tests."""
        cmd = [
            str(self.bin / "psql"),
            "-h", str(self.socket_dir),
            "-p", str(self.port),
            "-U", libpq_superuser(),
            "-d", dbname,
            "-c", sql,
            "--no-align", "--tuples-only", "-q",
        ]
        return self._run(cmd, capture=True, check=False)

    def execute_file(self, sql_file: str, dbname: str = "postgres") -> str:
        cmd = [
            str(self.bin / "psql"),
            "-h", str(self.socket_dir),
            "-p", str(self.port),
            "-U", libpq_superuser(),
            "-d", dbname,
            "-f", sql_file,
        ]
        result = self._run(cmd, capture=True)
        return result.stdout.strip()

    def fetchone(self, sql: str, dbname: str = "postgres") -> Optional[str]:
        out = self.execute(sql, dbname)
        lines = [l for l in out.splitlines() if l.strip()]
        return lines[0].strip() if lines else None

    def fetchall(self, sql: str, dbname: str = "postgres") -> List[str]:
        out = self.execute(sql, dbname)
        return [l.strip() for l in out.splitlines() if l.strip()]

    # ── replication helpers ───────────────────────────────────────────────

    def basebackup(self, target_dir: str, extra_args: Optional[List[str]] = None) -> None:
        cmd = [
            str(self.bin / "pg_basebackup"),
            "-h", str(self.socket_dir),
            "-p", str(self.port),
            "-U", libpq_superuser(),
            "-D", target_dir,
            "-R", "--checkpoint=fast",
        ]
        if extra_args:
            cmd.extend(extra_args)
        self._run(cmd, env_override={})

    def pg_rewind(self, target_data_dir: str, source_server_port: int) -> None:
        cmd = [
            str(self.bin / "pg_rewind"),
            "-D", target_data_dir,
            "--source-server",
            f"host={self.socket_dir} port={source_server_port} "
            f"user={libpq_superuser()} dbname=postgres",
        ]
        self._run(cmd, env_override={})

    # ── version & control data ────────────────────────────────────────────

    @property
    def major_version(self) -> int:
        if self._major_version is None:
            self._major_version = postgres_major_version(self.install_dir)
        return self._major_version

    def controldata(self, field: str) -> str:
        env = os.environ.copy()
        prepend_install_lib_dirs(env, self.install_dir)
        result = subprocess.run(
            [str(self.bin / "pg_controldata"), str(self.data_dir)],
            capture_output=True,
            text=True,
            check=True,
            env=env,
        )
        for line in result.stdout.splitlines():
            if field in line:
                return line.split(":", 1)[1].strip()
        return ""

    def read_log(self, last_n: int = 50) -> str:
        log_file = self.data_dir / "server.log"
        if not log_file.exists():
            return ""
        lines = log_file.read_text().splitlines()
        return "\n".join(lines[-last_n:])

    # ── internal helpers ──────────────────────────────────────────────────

    def _run(
        self,
        cmd: List[str],
        env_override: Optional[Dict] = None,
        capture: bool = False,
        check: bool = True,
        **kwargs,
    ) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        prepend_install_lib_dirs(env, self.install_dir)
        if env_override is not None:
            env.update(env_override)
        log.debug("Running: %s", " ".join(cmd))
        return subprocess.run(
            cmd,
            env=env,
            check=check,
            capture_output=capture,
            text=capture,
            **kwargs,
        )

    def _pgctl_wait_env(self) -> Dict[str, str]:
        """
        Ensure pg_ctl -w probes the cluster with stable libpq defaults.

        Without this, ambient shell vars (for example PGDATABASE/PGUSER set to
        a local login like 'ubuntu') can make pg_ctl report startup failure with:
        "FATAL: database '<user>' does not exist".
        """
        return {
            "PGHOST": str(self.socket_dir),
            "PGPORT": str(self.port),
            "PGUSER": libpq_superuser(),
            "PGDATABASE": "postgres",
        }


def initdb_extra_align_data_checksums_with_old(
    old_cluster: "PgCluster",
    new_install_dir: Path,
    explicit_extra: Optional[List[str]],
) -> Optional[List[str]]:
    """Build initdb extra args so the new cluster matches the old data-checksum setting.

    PostgreSQL 18+ initdb enables data checksums by default; upgrading from PG 17
    (checksums off by default) therefore requires ``--no-data-checksums`` on the
    new cluster unless the old cluster already had checksums enabled.

    If ``explicit_extra`` already contains ``--data-checksums`` or
    ``--no-data-checksums``, it is left unchanged (aside from copying the list).
    """
    extra = list(explicit_extra or ())
    if "--data-checksums" in extra or "--no-data-checksums" in extra:
        return extra or None
    raw = old_cluster.controldata("Data page checksum version")
    try:
        old_ck = int(raw)
    except ValueError:
        old_ck = 0
    new_maj = postgres_major_version(new_install_dir)
    if old_ck == 0:
        extra.extend(initdb_args_no_data_checksums(new_install_dir))
    elif new_maj < 18:
        extra.append("--data-checksums")
    return extra or None


def pg_tde_control_file_candidates(install_dir: Path) -> List[Path]:
    """Paths to ``pg_tde.control`` for *install_dir* (source build vs Debian/Ubuntu packages)."""
    root = Path(install_dir)
    candidates: List[Path] = []
    try:
        maj = postgres_major_version(root)
        candidates.append(
            Path(f"/usr/share/postgresql/{maj}/extension/pg_tde.control")
        )
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        pass
    pg_config = root / "bin" / "pg_config"
    if pg_config.is_file():
        try:
            env = os.environ.copy()
            prepend_install_lib_dirs(env, root)
            sharedir = subprocess.run(
                [str(pg_config), "--sharedir"],
                capture_output=True,
                text=True,
                check=True,
                env=env,
            ).stdout.strip()
            candidates.append(Path(sharedir) / "extension" / "pg_tde.control")
        except subprocess.CalledProcessError:
            pass
    candidates.extend(
        (
            root / "share" / "postgresql" / "extension" / "pg_tde.control",
            root / "share" / "extension" / "pg_tde.control",
        )
    )
    seen: set = set()
    unique: List[Path] = []
    for p in candidates:
        key = str(p)
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def read_pg_tde_default_version(install_dir: Path) -> Optional[str]:
    """Return ``default_version`` from ``pg_tde.control`` (e.g. ``'2.1'``, ``'2.2'``)."""
    for ctrl in pg_tde_control_file_candidates(install_dir):
        if not ctrl.is_file():
            continue
        for line in ctrl.read_text().splitlines():
            if line.strip().startswith("default_version"):
                return line.split("=", 1)[1].strip().strip("'\"")
    return None


def _pgbackrest_version_string() -> Optional[str]:
    import shutil
    import subprocess

    br = shutil.which("pgbackrest")
    if not br:
        return None
    result = subprocess.run(
        [br, "version"], capture_output=True, text=True, check=False
    )
    line = (result.stdout or result.stderr or "").strip().splitlines()
    return line[0].strip() if line else None


def _pg_tde_build_info_paths(install_dir: Path) -> List[Path]:
    """Locations where ``build_from_source.sh`` may write pg_tde git metadata."""
    paths = [
        install_dir / "pg_tde_build_info",
        install_dir / "share" / "pg_tde_build_info",
    ]
    # build_from_source.sh falls back here when /usr sharedir is not writable.
    workdir = os.environ.get("WORKDIR", "").strip()
    if workdir:
        paths.append(Path(workdir) / "pg_tde_build_info")
    paths.append(Path.home() / "pgwork" / "pg_tde_build_info")
    pg_config = install_dir / "bin" / "pg_config"
    if pg_config.is_file():
        import subprocess

        result = subprocess.run(
            [str(pg_config), "--sharedir"],
            capture_output=True,
            text=True,
            check=False,
        )
        sharedir = (result.stdout or "").strip()
        if sharedir:
            paths.append(Path(sharedir) / "pg_tde_build_info")
            paths.append(Path(sharedir) / "extension" / "pg_tde_build_info")
    return paths


def _parse_pg_tde_build_info(path: Path) -> dict:
    info: dict = {}
    try:
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            info[key.strip()] = val.strip()
    except OSError:
        return {}
    return info


def _git_describe_repo(src: Path) -> Optional[dict]:
    """Return branch/commit/dirty for a git checkout, or None."""
    import subprocess

    if not (src / ".git").exists() and not (src / ".git").is_file():
        return None
    try:
        branch = subprocess.run(
            ["git", "-C", str(src), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        commit = subprocess.run(
            ["git", "-C", str(src), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        dirty = subprocess.run(
            ["git", "-C", str(src), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=False,
        )
        if commit.returncode != 0:
            return None
        br = (branch.stdout or "").strip() or "DETACHED"
        sha = (commit.stdout or "").strip()
        is_dirty = bool((dirty.stdout or "").strip())
        return {
            "source": str(src),
            "branch": br,
            "commit": sha,
            "dirty": "1" if is_dirty else "0",
        }
    except OSError:
        return None


def _resolve_pg_tde_source_git(install_dir: Path) -> Optional[dict]:
    """
    pg_tde git identity for source builds.

    Prefer ``pg_tde_build_info`` written at install time; else probe
    ``PG_TDE_SRC`` / ``TDE_SRC`` / common lab paths.
    """
    for path in _pg_tde_build_info_paths(install_dir):
        if path.is_file():
            info = _parse_pg_tde_build_info(path)
            if info.get("commit") or info.get("branch"):
                return info

    candidates: List[Path] = []
    for env_key in ("PG_TDE_SRC", "TDE_SRC"):
        v = os.environ.get(env_key, "").strip()
        if v:
            candidates.append(Path(v))
    # Adjacent trees from build_from_source.sh (…/pginst/18 → …/pg_tde).
    work = install_dir.parent
    candidates.extend(
        [
            work / "pg_tde",
            work / "src" / "pg_tde",
            install_dir.parent.parent / "pg_tde",
        ]
    )
    seen: set = set()
    for src in candidates:
        key = str(src.resolve()) if src.exists() else str(src)
        if key in seen:
            continue
        seen.add(key)
        if not src.is_dir():
            continue
        git_info = _git_describe_repo(src)
        if git_info:
            return git_info
    return None


def _format_pg_tde_source_line(info: dict, *, tag: str) -> str:
    branch = info.get("branch") or "?"
    commit = info.get("commit") or "?"
    dirty = info.get("dirty", "0") in ("1", "true", "yes")
    dirty_s = " (dirty)" if dirty else ""
    src = info.get("source") or info.get("src") or ""
    base = f"{tag}pg_tde source: {branch}@{commit}{dirty_s}"
    if src:
        return f"{base} ({src})"
    return base


def install_version_summary_lines(
    install_dir: Path, *, prefix: str = ""
) -> List[str]:
    """
    Human-readable install-tree versions (no running cluster required).

    Shows PostgreSQL ``postgres --version``, ``pg_tde.control``
    ``default_version``, optional source git (branch/commit), and
    ``pgbackrest version`` when on PATH.
    """
    import subprocess

    tag = f"{prefix} " if prefix else ""
    lines: List[str] = []
    pg_bin = install_dir / "bin" / "postgres"
    if pg_bin.is_file():
        result = subprocess.run(
            [str(pg_bin), "--version"],
            capture_output=True,
            text=True,
            check=False,
        )
        pg_ver = (result.stdout or result.stderr).strip()
        lines.append(f"{tag}PostgreSQL server: {pg_ver}")
    else:
        lines.append(
            f"{tag}PostgreSQL server: (no postgres binary under {install_dir})"
        )

    try:
        ctrl_ver = read_pg_tde_default_version(install_dir)
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError):
        ctrl_ver = None
    if ctrl_ver:
        lines.append(f"{tag}pg_tde.control default_version: {ctrl_ver}")
    else:
        lines.append(f"{tag}pg_tde extension: pg_tde.control not found")

    try:
        git_info = _resolve_pg_tde_source_git(install_dir)
    except OSError:
        git_info = None
    if git_info:
        lines.append(_format_pg_tde_source_line(git_info, tag=tag))
    else:
        lines.append(f"{tag}pg_tde source: (package install or no git metadata)")

    # Only once for the primary INSTALL tree (avoid duplicate when summarizing OLD).
    if not prefix or prefix.upper() == "INSTALL":
        br = _pgbackrest_version_string()
        if br:
            lines.append(f"pgBackRest: {br}")
        else:
            lines.append("pgBackRest: (not on PATH)")

    lines.append(f"{tag}install-dir: {install_dir}")
    return lines


def cluster_runtime_version_lines(
    cluster: "PgCluster", *, prefix: str = ""
) -> List[str]:
    """Query a running cluster for server + pg_tde versions."""
    tag = f"{prefix} " if prefix else ""
    lines: List[str] = []
    try:
        pg_ver = cluster.fetchone("SELECT version()")
        if pg_ver:
            lines.append(f"{tag}PostgreSQL server: {pg_ver}")
    except Exception as exc:
        lines.append(f"{tag}PostgreSQL server: (query failed: {exc})")

    try:
        tde_bin = cluster.fetchone("SELECT pg_tde_version()")
        if tde_bin:
            lines.append(f"{tag}pg_tde binary pg_tde_version(): {tde_bin.strip()}")
    except Exception:
        lines.append(f"{tag}pg_tde binary pg_tde_version(): (not available)")

    try:
        ext_ver = cluster.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        if ext_ver:
            lines.append(f"{tag}pg_tde catalog extversion: {ext_ver}")
    except Exception:
        pass
    return lines


def log_version_summary(lines: List[str]) -> None:
    """Print version lines to stderr (visible under pytest -s and in CI logs)."""
    import sys

    for line in lines:
        print(line, file=sys.stderr)


def cluster_has_pg_tde_data(cluster: "PgCluster") -> bool:
    return (Path(cluster.data_dir) / "pg_tde").is_dir()


def cluster_wal_encryption_enabled(cluster: "PgCluster") -> bool:
    """True when ``pg_tde.wal_encrypt`` is ``on`` in the source cluster config."""
    for path in (
        Path(cluster.data_dir) / "postgresql.auto.conf",
        Path(cluster.data_dir) / "postgresql.conf",
    ):
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            if "pg_tde.wal_encrypt" not in line.lower():
                continue
            stripped = line.split("#", 1)[0].strip().lower()
            if "=" not in stripped:
                continue
            val = stripped.split("=", 1)[1].strip().strip("'\"")
            if val == "on":
                return True
    return False


def should_use_pg_tde_upgrade_wrapper(
    old_cluster: "PgCluster",
    new_install_dir: Path,
    *,
    extra_params: Optional[Dict[str, str]] = None,
) -> bool:
    """Choose ``pg_tde_upgrade`` over plain ``pg_upgrade`` + ``pg_tde/`` copy.

  Use the Percona wrapper when the source has pg_tde key material and either:

  - the old/new installs ship different pg_tde extension default versions
    (e.g. 2.1.x on PG17 → 2.2.x on PG18), or
  - WAL encryption was enabled on the source cluster.

  Plain ``pg_upgrade`` + ``copy_pg_tde_dir`` is sufficient for same pg_tde
  minor across a PG major bump (e.g. 2.2.0 → 2.2.0).
    """
    if not cluster_has_pg_tde_data(old_cluster):
        return False

    old_ver = read_pg_tde_default_version(old_cluster.install_dir)
    new_ver = read_pg_tde_default_version(new_install_dir)
    if old_ver and new_ver and old_ver != new_ver:
        return True

    if cluster_wal_encryption_enabled(old_cluster):
        return True

    if extra_params:
        wal = extra_params.get("pg_tde.wal_encrypt", "").strip().strip("'\"")
        if wal.lower() == "on":
            return True

    return False


def pg_upgrade_target_params(
    extra_params: Optional[Dict[str, str]] = None,
) -> Optional[Dict[str, str]]:
    """Parameters safe for the *empty* target cluster during ``pg_upgrade``.

    ``pg_tde.wal_encrypt`` on the target before migration prevents the upgrade
    postmaster from starting (bash scripts never set it pre-upgrade).

    Keep ``shared_preload_libraries = 'pg_tde'`` on the target so ``pg_upgrade``'s
    loadable-library check finds ``pg_tde``. A prior workaround that dropped
    preload for 2.1→2.2 caused ``Checking for presence of required libraries``
    fatal failures. Startup decrypt issues from empty smgr key slots/files are
    addressed in pg_tde PG-2381 / PR #582, not by removing preload.
    """
    if not extra_params:
        return None
    drop = {"pg_tde.wal_encrypt"}
    filtered = {k: v for k, v in extra_params.items() if k not in drop}
    return filtered or None


def copy_pg_tde_dir(old_data_dir: Path, new_data_dir: Path) -> bool:
    """Copy ``$PGDATA/pg_tde`` after ``pg_upgrade`` (PG-2240).

    Vanilla ``pg_upgrade`` does not migrate the encrypted key-material tree;
    the bash automation scripts apply this copy before starting the new cluster.
    Returns True when a directory was copied.
    """
    src = Path(old_data_dir) / "pg_tde"
    if not src.is_dir():
        return False
    dst = Path(new_data_dir) / "pg_tde"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return True


def write_pg_upgrade_target_config(
    cluster: "PgCluster",
    extra_params: Optional[Dict[str, str]] = None,
) -> None:
    """Minimal ``postgresql.conf`` for the pg_upgrade *target* cluster.

    Bash upgrade scripts set port, socket dir, and ``shared_preload_libraries``
    on the target (see ``pg_upgrade_target_params``). Full
    ``PgCluster.write_default_config()``
    (``logging_collector``, PG18 ``io_method``, etc.) is applied *after*
    pg_upgrade succeeds. Using the full config on the empty target breaks
    some ``pg_tde_upgrade`` builds when the wrapper starts the target
    postmaster during the schema-dump phase.
    """
    cluster.socket_dir.mkdir(parents=True, exist_ok=True)
    params: Dict[str, str] = {
        "port": str(cluster.port),
        "unix_socket_directories": f"'{cluster.socket_dir}'",
    }
    if extra_params:
        params.update(extra_params)
    cluster.configure(params, append=False)
    with (cluster.data_dir / "postgresql.conf").open("a") as f:
        f.write("include_if_exists = 'postgresql.auto.conf'\n")


def resolve_pg_upgrade_binary(
    install_dir: Path, *, use_tde_wrapper: bool
) -> Path:
    """Return ``pg_tde_upgrade`` or plain ``pg_upgrade`` under *install_dir*."""
    new_bin = Path(install_dir) / "bin"
    wrapper = new_bin / "pg_tde_upgrade"
    if use_tde_wrapper and wrapper.is_file():
        return wrapper
    return new_bin / "pg_upgrade"
