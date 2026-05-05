"""pgBackRest and pg_basebackup backup/restore helpers."""
import configparser
import logging
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path
from typing import List, Optional

log = logging.getLogger(__name__)


def pgbackrest_installed() -> bool:
    """Return True if the pgbackrest binary is on PATH and responds to ``version``."""
    exe = shutil.which("pgbackrest")
    if not exe:
        return False
    try:
        r = subprocess.run(
            [exe, "version"],
            capture_output=True,
            timeout=30,
            text=True,
        )
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class BackupManager:
    """
    Wraps pgBackRest operations for backup and PITR testing.

    For **pg_tde + WAL encryption**, archive/restore must use Percona's helpers
    (see Percona walkthrough:
    https://percona.community/blog/2026/03/10/running-pgbackrest-with-pg_tde-a-practical-percona-walkthrough/):

    - ``pg_tde_archive_decrypt`` wraps ``archive-push`` so WAL is decrypted before pgBackRest.
    - ``pg_tde_restore_encrypt`` wraps ``archive-get`` so WAL is re-encrypted on restore.

    Pass ``pg_bin`` to ``write_config()`` and set ``pg_tde_wal_archiving`` /
    ``pg_tde_wal_restore`` on configure/restore when exercising encrypted WAL.
    """

    def __init__(self, stanza: str = "test", repo_path: str = "/tmp/pgtest_pytest/pgbackrest") -> None:
        self.stanza = stanza
        self.repo_path = Path(repo_path)
        self.conf_path = Path(f"/tmp/pgtest_pytest/pgbackrest_{stanza}.conf")
        # Set by write_config(); passed on the CLI so pgBackRest always sees pg1-* (some versions
        # miss stanza options read only from config files written by ConfigParser).
        self._pg1_path: Optional[str] = None
        self._pg1_port: Optional[int] = None
        self._pg1_socket_path: Optional[str] = None
        self._pg_bin: Optional[Path] = None

    # ── configuration ─────────────────────────────────────────────────────

    def write_config(
        self,
        pg_path: str,
        pg_port: int,
        pg_socket_path: str,
        retention_full: int = 2,
        *,
        pg_bin: Optional[str] = None,
    ) -> None:
        self._pg1_path = pg_path
        self._pg1_port = pg_port
        self._pg1_socket_path = pg_socket_path
        self._pg_bin = Path(pg_bin) if pg_bin else None

        self.repo_path.mkdir(parents=True, exist_ok=True)
        log_path = self.repo_path / "logs"
        log_path.mkdir(parents=True, exist_ok=True)
        self.conf_path.parent.mkdir(parents=True, exist_ok=True)
        cfg = configparser.ConfigParser(interpolation=None)
        cfg["global"] = {
            "repo1-path": str(self.repo_path),
            "repo1-retention-full": str(retention_full),
            "log-level-console": "info",
            "log-path": str(log_path),
        }
        cfg[f"stanza:{self.stanza}"] = {
            "pg1-path": pg_path,
            "pg1-port": str(pg_port),
            "pg1-socket-path": pg_socket_path,
        }
        with self.conf_path.open("w") as f:
            cfg.write(f)
        log.info("pgBackRest config written to %s", self.conf_path)

    def _inner_pgbackrest_archive_push(self) -> str:
        """pgBackRest CLI fragment passed to pg_tde_archive_decrypt (see Percona blog)."""
        return " ".join(
            [
                "pgbackrest",
                shlex.quote(f"--config={self.conf_path}"),
                shlex.quote(f"--stanza={self.stanza}"),
                shlex.quote(f"--pg1-path={self._pg1_path}"),
                shlex.quote(f"--pg1-port={self._pg1_port}"),
                shlex.quote(f"--pg1-socket-path={self._pg1_socket_path}"),
                # %% so postgresql.conf keeps a literal %p for pgBackRest after escape rules
                "archive-push",
                "%%p",
            ]
        )

    def _inner_pgbackrest_archive_get(self) -> str:
        """pgBackRest CLI fragment passed to pg_tde_restore_encrypt (see Percona blog)."""
        return " ".join(
            [
                "pgbackrest",
                shlex.quote(f"--config={self.conf_path}"),
                shlex.quote(f"--stanza={self.stanza}"),
                "archive-get",
                "%%f",
                "%%p",
            ]
        )

    def configure_postgres(self, cluster, *, pg_tde_wal_archiving: bool = False) -> None:
        """Add archive settings to the cluster's postgresql.conf."""
        if pg_tde_wal_archiving:
            if not self._pg_bin:
                raise ValueError("write_config(..., pg_bin='...') is required for pg_tde_wal_archiving")
            decrypt = self._pg_bin / "pg_tde_archive_decrypt"
            if not decrypt.is_file():
                raise FileNotFoundError(f"pg_tde_archive_decrypt not found: {decrypt}")
            # Percona walkthrough: decrypt WAL before pgBackRest archive-push.
            inner = self._inner_pgbackrest_archive_push()
            archive_cmd = f"{decrypt} %f %p \"{inner}\""
        else:
            # PostgreSQL may invoke archive-push with a *relative* %p (e.g. pg_wal/...).
            # pgBackRest then requires pg1-path (and friends) on the archive-push CLI.
            archive_cmd = " ".join(
                [
                    "pgbackrest",
                    shlex.quote(f"--config={self.conf_path}"),
                    shlex.quote(f"--stanza={self.stanza}"),
                    shlex.quote(f"--pg1-path={self._pg1_path}"),
                    shlex.quote(f"--pg1-port={self._pg1_port}"),
                    shlex.quote(f"--pg1-socket-path={self._pg1_socket_path}"),
                    "archive-push",
                    "%p",
                ]
            )
        cluster.configure(
            {
                "archive_mode": "on",
                "archive_command": f"'{archive_cmd}'",
                "wal_level": "replica",
            }
        )

    # ── stanza / backup operations ────────────────────────────────────────

    def _run(self, *args) -> subprocess.CompletedProcess:
        cmd = [
            "pgbackrest",
            f"--config={self.conf_path}",
            f"--stanza={self.stanza}",
        ]
        # Duplicate stanza pg1-* on the CLI; avoids [037] stanza-create requires option: pg1-path
        # when the config file alone is not applied as expected.
        merged = " ".join(str(a) for a in args)
        if self._pg1_path and "--pg1-path=" not in merged:
            cmd.append(f"--pg1-path={self._pg1_path}")
            cmd.append(f"--pg1-port={self._pg1_port}")
            cmd.append(f"--pg1-socket-path={self._pg1_socket_path}")
        cmd.extend(args)
        log.debug("pgbackrest: %s", " ".join(cmd))
        return subprocess.run(cmd, check=True, capture_output=True, text=True)

    def stanza_create(self) -> None:
        self._run("stanza-create")
        log.info("pgBackRest stanza '%s' created", self.stanza)

    def backup(self, backup_type: str = "full") -> None:
        self._run(f"--type={backup_type}", "backup")
        log.info("pgBackRest %s backup completed", backup_type)

    def restore(
        self,
        target_path: str,
        *,
        recovery_target_time: Optional[str] = None,
        delta: bool = False,
        pg_tde_wal_restore: bool = False,
    ) -> None:
        args: List[str] = [f"--pg1-path={target_path}", "restore"]
        if delta:
            args.insert(0, "--delta")
        if recovery_target_time:
            args.insert(0, f"--recovery-target-time={recovery_target_time}")
            args.insert(0, "--recovery-target-action=promote")
        if pg_tde_wal_restore:
            if not self._pg_bin:
                raise ValueError("write_config(..., pg_bin='...') is required for pg_tde_wal_restore")
            encrypt = self._pg_bin / "pg_tde_restore_encrypt"
            if not encrypt.is_file():
                raise FileNotFoundError(f"pg_tde_restore_encrypt not found: {encrypt}")
            inner = self._inner_pgbackrest_archive_get()
            restore_cmd = f"{encrypt} %f %p \"{inner}\""
            args.insert(0, "--recovery-option=restore_command=" + shlex.quote(restore_cmd))
        self._run(*args)
        log.info("pgBackRest restore completed to %s", target_path)

    def info(self) -> str:
        result = self._run("info")
        return result.stdout

    def archive_push(self, wal_segment: str) -> None:
        self._run(f"--pg1-path={wal_segment}", "archive-push")

    def check(self) -> None:
        self._run("check")


class PgBaseBackup:
    """Simple wrapper around pg_basebackup for ad-hoc backups."""

    def __init__(self, cluster) -> None:
        self.cluster = cluster

    def take(self, target_dir: str, wal_method: str = "stream") -> None:
        cmd = [
            str(self.cluster.bin / "pg_basebackup"),
            "-h", str(self.cluster.socket_dir),
            "-p", str(self.cluster.port),
            "-D", target_dir,
            f"--wal-method={wal_method}",
            "--checkpoint=fast",
            "-v",
        ]
        subprocess.run(cmd, check=True)
        log.info("pg_basebackup completed to %s", target_dir)

    def restore(self, backup_dir: str, target_dir: str) -> None:
        import shutil
        shutil.copytree(backup_dir, target_dir)
        log.info("Backup restored from %s to %s", backup_dir, target_dir)
