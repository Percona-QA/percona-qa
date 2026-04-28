"""pgBackRest and pg_basebackup backup/restore helpers."""
import configparser
import logging
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)


class BackupManager:
    """Wraps pgBackRest operations for backup and PITR testing."""

    def __init__(self, stanza: str = "test", repo_path: str = "/tmp/pgtest_pytest/pgbackrest") -> None:
        self.stanza = stanza
        self.repo_path = Path(repo_path)
        self.conf_path = Path(f"/tmp/pgtest_pytest/pgbackrest_{stanza}.conf")

    # ── configuration ─────────────────────────────────────────────────────

    def write_config(
        self,
        pg_path: str,
        pg_port: int,
        pg_socket_path: str,
        retention_full: int = 2,
    ) -> None:
        self.repo_path.mkdir(parents=True, exist_ok=True)
        self.conf_path.parent.mkdir(parents=True, exist_ok=True)
        cfg = configparser.ConfigParser()
        cfg["global"] = {
            "repo1-path": str(self.repo_path),
            "repo1-retention-full": str(retention_full),
            "log-level-console": "info",
        }
        cfg[f"stanza:{self.stanza}"] = {
            "pg1-path": pg_path,
            "pg1-port": str(pg_port),
            "pg1-socket-path": pg_socket_path,
        }
        with self.conf_path.open("w") as f:
            cfg.write(f)
        log.info("pgBackRest config written to %s", self.conf_path)

    def configure_postgres(self, cluster) -> None:
        """Add archive settings to the cluster's postgresql.conf."""
        archive_cmd = (
            f"pgbackrest --config={self.conf_path} "
            f"--stanza={self.stanza} archive-push %p"
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
            *args,
        ]
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
    ) -> None:
        args = [f"--pg1-path={target_path}", "restore"]
        if delta:
            args.insert(0, "--delta")
        if recovery_target_time:
            args.insert(0, f"--recovery-target-time={recovery_target_time}")
            args.insert(0, "--recovery-target-action=promote")
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
