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


def _pg_settings_file_string_literal(value: str) -> str:
    """
    Quote *value* for the RHS of a ``postgresql.conf`` / ``postgresql.auto.conf`` line.

    PostgreSQL expects string GUCs as single-quoted literals; embedded ``'`` must
    be doubled. Do **not** use ``shlex.quote()`` here: paths containing only
    ``[\\w@%+=:,./-]`` are considered shell-safe and are returned **without** any
    quotes, which pgBackRest then writes verbatim so the server sees a bare
    ``/path/...`` after ``=`` and fails with a syntax error near ``/``.
    """
    return "'" + value.replace("'", "''") + "'"


# Keys copied from backups / ALTER SYSTEM that break a pytest-managed instance
# (bare paths after ``=``, wrong port/socket, or noisy archiver during recovery).
_AUTO_CONF_DROP_AFTER_TDE_RESTORE = frozenset(
    {
        "restore_command",  # replaced with a known-valid line below
        "archive_mode",
        "archive_command",
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
    }
)


def _rewrite_restore_command_in_auto_conf(data_dir: Path, restore_cmd: str) -> None:
    """
    Rewrite ``postgresql.auto.conf`` after a pg_tde + pgBackRest restore.

    - Drop ``restore_command`` / ``archive_*`` / socket GUC lines that pgBackRest or
      the backup may have written incorrectly (e.g. unquoted paths → syntax error
      near ``/``).
    - Append a single PostgreSQL-valid ``restore_command`` literal.
    """
    auto = data_dir / "postgresql.auto.conf"
    quoted = _pg_settings_file_string_literal(restore_cmd)
    if not auto.exists():
        auto.write_text(f"restore_command = {quoted}\n")
        return
    out_lines: List[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#"):
            out_lines.append(line)
            continue
        if "=" not in raw:
            out_lines.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _AUTO_CONF_DROP_AFTER_TDE_RESTORE:
            continue
        out_lines.append(line)
    out_lines.append(f"restore_command = {quoted}")
    auto.write_text("\n".join(out_lines) + "\n")


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
        # Keep config beside repo1-path (pytest tmp_path), not a shared /tmp dir, so parallel
        # runs and lock files do not collide. Set spool-path under the repo too (avoids [053]
        # when pgBackRest would otherwise default to /var/spool/pgbackrest).
        self.conf_path = self.repo_path.parent / f"pgbackrest_{stanza}.conf"
        # Set by write_config(); duplicated on the CLI for backup/stanza-create (some versions
        # miss stanza options from ConfigParser). Do not pass pg1-port/socket on archive-push.
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
        lock_path = self.repo_path / "lock"
        lock_path.mkdir(parents=True, exist_ok=True)
        # Default spool-path is /var/spool/pgbackrest — restore/archive still probe it
        # and fail with [053] Permission denied for non-root pytest users.
        spool_path = self.repo_path / "spool"
        spool_path.mkdir(parents=True, exist_ok=True)
        self.conf_path.parent.mkdir(parents=True, exist_ok=True)
        cfg = configparser.ConfigParser(interpolation=None)
        cfg["global"] = {
            "repo1-path": str(self.repo_path),
            "repo1-retention-full": str(retention_full),
            "log-level-console": "info",
            "log-path": str(log_path),
            "lock-path": str(lock_path),
            "spool-path": str(spool_path),
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
        # archive-push only accepts pg1-path on the CLI; port/socket belong in the
        # stanza section of the config file (pgBackRest 2.58+: --pg1-port is invalid here).
        return " ".join(
            [
                "pgbackrest",
                shlex.quote(f"--config={self.conf_path}"),
                shlex.quote(f"--stanza={self.stanza}"),
                shlex.quote(f"--pg1-path={self._pg1_path}"),
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
            # pgBackRest requires --pg1-path on the archive-push CLI; pg1-port/socket
            # must not be passed to archive-push (invalid in pgBackRest 2.58+).
            archive_cmd = " ".join(
                [
                    "pgbackrest",
                    shlex.quote(f"--config={self.conf_path}"),
                    shlex.quote(f"--stanza={self.stanza}"),
                    shlex.quote(f"--pg1-path={self._pg1_path}"),
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

    # Only duplicate [stanza] pg1-* on the CLI for commands that still accept it
    # in pgBackRest 2.58+. ``info``/``check``/``expire`` reject --pg1-path with
    # [031]. ``restore``/``archive-push`` pass their own ``--pg1-path=...`` (WAL
    # segment or target data dir) — never infer from other argv tokens (paths
    # can equal subcommand names in edge cases).
    _PG1_CLI_DUP_COMMANDS = frozenset({"stanza-create", "backup"})

    @staticmethod
    def _pgbackrest_subcommand(args_str: List[str]) -> str:
        for a in reversed(args_str):
            s = str(a)
            if not s.startswith("-"):
                return s
        return ""

    def _run(self, *args) -> subprocess.CompletedProcess:
        cmd = [
            "pgbackrest",
            f"--config={self.conf_path}",
            f"--stanza={self.stanza}",
        ]
        args_str = [str(a) for a in args]
        sub = self._pgbackrest_subcommand(args_str)
        needs_pg1_dup = sub in self._PG1_CLI_DUP_COMMANDS
        if (
            needs_pg1_dup
            and self._pg1_path
            and not any(a.startswith("--pg1-path=") for a in args_str)
        ):
            cmd.append(f"--pg1-path={self._pg1_path}")
            cmd.append(f"--pg1-port={self._pg1_port}")
            cmd.append(f"--pg1-socket-path={self._pg1_socket_path}")
        cmd.extend(args)
        log.debug("pgbackrest: %s", " ".join(cmd))
        try:
            return subprocess.run(cmd, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            # pgBackRest writes the actionable error to stderr; surface it so
            # the test failure points at the real cause instead of just
            # "non-zero exit status N".
            raise RuntimeError(
                "pgbackrest failed (exit %d):\n"
                "  cmd:    %s\n"
                "  stdout: %s\n"
                "  stderr: %s"
                % (
                    e.returncode,
                    " ".join(cmd),
                    (e.stdout or "").strip(),
                    (e.stderr or "").strip(),
                )
            ) from e

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
        restore_type: str = "default",
        target: Optional[str] = None,
        target_action: str = "promote",
        recovery_target_time: Optional[str] = None,  # kept for backward compat
        delta: bool = False,
        db_include: Optional[List[str]] = None,
        force: bool = False,
        pg_tde_wal_restore: bool = False,
    ) -> None:
        """
        Run ``pgbackrest restore``.

        Args:
            target_path: target data directory.
            restore_type: pgBackRest ``--type`` value. One of
                ``default`` (latest backup, replay all WAL),
                ``standby`` (restore as standby with ``standby.signal``),
                ``time`` / ``lsn`` / ``xid`` (PITR — ``target`` required),
                ``immediate`` (recover to first consistent point).
            target: value for ``--target`` (timestamp / LSN / XID).
                Required when ``restore_type`` is time/lsn/xid.
            target_action: ``--target-action`` for PITR (promote/pause/shutdown).
            recovery_target_time: legacy alias for ``restore_type='time'`` + ``target=...``.
            delta: pass ``--delta``; do not wipe ``target_path`` first.
            db_include: list of database names; passes ``--db-include`` once per entry.
            force: pass ``--force`` (allows restore into a non-empty directory).
            pg_tde_wal_restore: wrap archive-get with ``pg_tde_restore_encrypt``.
        """
        # Legacy alias support.
        if recovery_target_time and restore_type == "default":
            restore_type = "time"
            target = recovery_target_time

        if restore_type in {"time", "lsn", "xid"} and not target:
            raise ValueError(f"restore_type={restore_type!r} requires target=")
        if target_action not in {"promote", "pause", "shutdown"}:
            raise ValueError(f"invalid target_action: {target_action!r}")

        dest = Path(target_path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Wipe the destination unless the caller wants delta or force semantics.
        if dest.exists() and not delta and not force:
            shutil.rmtree(dest)

        args: List[str] = [f"--pg1-path={target_path}"]
        if restore_type != "default":
            args.append(f"--type={restore_type}")
        if target is not None:
            args.append(f"--target={target}")
        if restore_type in {"time", "lsn", "xid", "name", "immediate"}:
            args.append(f"--target-action={target_action}")
        if delta:
            args.append("--delta")
        if force:
            args.append("--force")
        if db_include:
            for db in db_include:
                args.append(f"--db-include={db}")
        restore_cmd: Optional[str] = None
        if pg_tde_wal_restore:
            if not self._pg_bin:
                raise ValueError("write_config(..., pg_bin='...') is required for pg_tde_wal_restore")
            encrypt = self._pg_bin / "pg_tde_restore_encrypt"
            if not encrypt.is_file():
                raise FileNotFoundError(f"pg_tde_restore_encrypt not found: {encrypt}")
            inner = self._inner_pgbackrest_archive_get()
            restore_cmd = f"{encrypt} %f %p \"{inner}\""
            args.append(
                "--recovery-option=restore_command="
                + _pg_settings_file_string_literal(restore_cmd)
            )
        args.append("restore")
        self._run(*args)
        if restore_cmd is not None:
            _rewrite_restore_command_in_auto_conf(dest, restore_cmd)
        log.info(
            "pgBackRest restore completed to %s (type=%s, target=%s)",
            target_path, restore_type, target,
        )

    def info(self) -> str:
        result = self._run("info")
        return result.stdout

    def archive_push(self, wal_segment: str) -> None:
        self._run(f"--pg1-path={wal_segment}", "archive-push")

    def check(self) -> None:
        self._run("check")

    # ── timing helpers ────────────────────────────────────────────────────

    def wait_for_wal_archive(self, cluster, timeout: int = 30) -> str:
        """
        Force a WAL switch and block until pg_stat_archiver reports progress.

        Why this looks indirect: after ``pgbackrest backup`` returns, the cluster
        is parked at offset 0 of a fresh WAL segment (pgBackRest does its own
        ``pg_switch_wal`` to flush the backup-history file). A naive
        ``SELECT pg_switch_wal()`` from us is then a *no-op* — no ``.ready`` file
        appears, the archiver has nothing to do, and ``last_archived_wal`` never
        advances past the ``*.backup`` history file we have already seen.

        Workaround: emit at least one WAL record (CHECKPOINT writes a
        CHECKPOINT_ONLINE record unconditionally) so the next ``pg_switch_wal``
        actually closes a segment. Then poll until ``last_archived_wal`` differs
        from the value we captured at entry — robust against the
        ``...NNN.backup`` vs ``...NNN+1`` lexicographic ambiguity.

        Returns the new ``last_archived_wal`` value.
        """
        initial = cluster.fetchone(
            "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
        ) or ""

        # CHECKPOINT guarantees the current segment has offset > 0, so the
        # subsequent pg_switch_wal is not a no-op.
        cluster.execute("CHECKPOINT")
        cluster.execute("SELECT pg_switch_wal()")

        deadline = time.time() + timeout
        latest = initial
        while time.time() < deadline:
            latest = cluster.fetchone(
                "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
            ) or ""
            if latest and latest != initial:
                log.debug("WAL archive advanced: %s -> %s", initial, latest)
                return latest
            time.sleep(0.3)

        # Surface any archiver-side failure so the test message is actionable.
        stats = cluster.fetchone(
            "SELECT format('failed_count=%s last_failed_wal=%s last_failed_time=%s', "
            "failed_count, last_failed_wal, last_failed_time) "
            "FROM pg_stat_archiver"
        )
        raise TimeoutError(
            f"last_archived_wal did not advance from {initial!r} within {timeout}s. "
            f"pg_stat_archiver: {stats}"
        )


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
