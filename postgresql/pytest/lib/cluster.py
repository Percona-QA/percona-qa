"""Core PostgreSQL cluster lifecycle management."""
import logging
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

log = logging.getLogger(__name__)


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

    def write_default_config(self, role: str = "primary") -> None:
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
        if self.major_version >= 18:
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
        self.configure(params, append=False)

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
        self._run(cmd, env_override={})
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
        self._run(cmd, env_override={})
        log.info("PostgreSQL restarted on port %d", self.port)

    def reload(self) -> None:
        cmd = [str(self.bin / "pg_ctl"), "reload", "-D", str(self.data_dir)]
        self._run(cmd, env_override={})

    def promote(self) -> None:
        cmd = [str(self.bin / "pg_ctl"), "promote", "-D", str(self.data_dir), "-w"]
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
        result = subprocess.run(
            [str(self.bin / "pg_isready"), "-h", str(self.socket_dir), "-p", str(self.port)],
            capture_output=True,
            timeout=5,
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
        cmd = [
            str(self.bin / "psql"),
            "-h", str(self.socket_dir),
            "-p", str(self.port),
            "-d", dbname,
            "-c", sql,
            "--no-align", "--tuples-only", "-q",
        ]
        try:
            result = self._run(cmd, capture=True)
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"psql failed (port={self.port}, db={dbname})\n"
                f"SQL : {sql}\n"
                f"OUT : {e.stdout.strip()}\n"
                f"ERR : {e.stderr.strip()}"
            ) from e

    def execute_file(self, sql_file: str, dbname: str = "postgres") -> str:
        cmd = [
            str(self.bin / "psql"),
            "-h", str(self.socket_dir),
            "-p", str(self.port),
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
            f"host={self.socket_dir} port={source_server_port} user=postgres dbname=postgres",
        ]
        self._run(cmd, env_override={})

    # ── version & control data ────────────────────────────────────────────

    @property
    def major_version(self) -> int:
        if self._major_version is None:
            result = subprocess.run(
                [str(self.bin / "postgres"), "--version"],
                capture_output=True, text=True,
            )
            # "postgres (PostgreSQL) 17.1" → 17
            self._major_version = int(result.stdout.split()[2].split(".")[0])
        return self._major_version

    def controldata(self, field: str) -> str:
        result = subprocess.run(
            [str(self.bin / "pg_controldata"), str(self.data_dir)],
            capture_output=True, text=True, check=True,
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
