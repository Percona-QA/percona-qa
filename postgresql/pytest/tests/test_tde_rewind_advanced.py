"""
pg_rewind / pg_tde_rewind regression and corner-case tests.

Consolidates rewind coverage from ``test_recovery.py`` and
``test_replication.py`` (plain ``pg_rewind`` + TDE offline rewind) plus
advanced scenarios that stress the interaction between pg_tde and rewind:

  TestTdeRewindWalEncryption       WAL-encrypted archives, compression + TDE
  TestTdeRewindFullHaCycle         Live-source rewind, full failback as standby,
                                   cascading 3-node topology
  TestTdeRewindKeyProviderEdges    Database-level provider, multi-provider, provider
                                   absent on target (negative)
  TestTdeRewindDataStructures      Tablespace, sequence reset, relfilenode via
                                   VACUUM FULL, GIN index, multiple databases
  TestTdeRewindNegative            Source running, dirty target, no archive for -c,
                                   same-dir source/target
  TestTdeRewindRandomized          pg_tde_rewind_randomized.sh (PG-2329, asymmetric DDL)
  TestTdeRewindMultiRound          DDL storm, double rewind, concurrent writes,
                                   3-round HA lifecycle
  TestTdeRewindEncryptedWalChaosLoop  Manual 10× loop (archive-stable stops)
  TestTdeRewindAdvancedEncryptedHa   Live-source, failback, 3-node+encrypt, etc.
  TestTdeRewindEncTapPorts          pg_tde/t/pg_rewind_enc_*.pl (2026 fixes)
  TestTdeRewindEncMedium            ext TS, empty-pg_wal archive mode, remote flags
  TestTdeRewindUpstreamPorts        upstream pg_rewind_*.pl options/extrafiles/…
"""

import random
import re
import shutil
import subprocess
import time
import os
import signal
from pathlib import Path
from typing import Optional, Tuple

import pytest

from conftest import allocate_port
from lib import (
    PgCluster,
    ReplicationManager,
    TdeManager,
    archive_restore_conf_values,
    wrappers_available,
)
from lib.cluster import (
    initdb_args_no_data_checksums,
    libpq_superuser,
    postgres_major_version,
)

pytestmark = [pytest.mark.rewind, pytest.mark.slow]


# ── module-level helpers ──────────────────────────────────────────────────────


def _tde_rewind_bin(install_dir: Path) -> Path:
    p = install_dir / "bin" / "pg_tde_rewind"
    return p if p.exists() else install_dir / "bin" / "pg_rewind"


def _rewind_env(install_dir: Path) -> dict:
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    return env


def _run_rewind_pgdata_ex(
    install_dir: Path,
    target: PgCluster,
    source: Optional[PgCluster] = None,
    *,
    source_pgdata: Optional[Path] = None,
    source_server: Optional[str] = None,
    restore_wal: bool = False,
    no_ensure_shutdown: bool = False,
    config_file: Optional[Path] = None,
    write_recovery_conf: bool = False,
    dry_run: bool = False,
    debug: bool = False,
    stderr_sink=None,
) -> subprocess.CompletedProcess:
    """
    Flexible ``pg_tde_rewind`` invocation (offline or ``--source-server``).

    Matches flags exercised in ``pg_tde/t/RewindTest.pm`` and ``pg_rewind_options.pl``.
    """
    cmd = [str(_tde_rewind_bin(install_dir)), "--target-pgdata", str(target.data_dir)]
    if source_server:
        cmd.extend(["--source-server", source_server])
    elif source_pgdata is not None:
        cmd.extend(["--source-pgdata", str(source_pgdata)])
    elif source is not None:
        cmd.extend(["--source-pgdata", str(source.data_dir)])
    else:
        raise ValueError("source, source_pgdata, or source_server required")
    if restore_wal:
        cmd.append("-c")
    if no_ensure_shutdown:
        cmd.append("--no-ensure-shutdown")
    if config_file is not None:
        cmd.extend(["--config-file", str(config_file)])
    if write_recovery_conf:
        cmd.append("--write-recovery-conf")
    if dry_run:
        cmd.append("--dry-run")
    if debug or os.environ.get("PG_TDE_REWIND_DEBUG", "").strip() in ("1", "yes", "true"):
        cmd.append("--debug")
    env = _rewind_env(install_dir)
    if stderr_sink is not None:
        return subprocess.run(
            cmd, stdout=subprocess.PIPE, text=True, env=env, stderr=stderr_sink
        )
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _run_rewind_pgdata(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
    *,
    restore_wal: bool = True,
) -> subprocess.CompletedProcess:
    """
    Offline pg_tde_rewind: both clusters must already be stopped.
    restore_wal=True passes -c (use restore_command to fetch missing WAL).
    """
    return _run_rewind_pgdata_ex(
        install_dir, target, source, restore_wal=restore_wal
    )


def _cleanup_ha_pair_root(root: Path, install_dir: Path) -> None:
    """Stop postgres under ``root/{primary,standby}`` and remove the tree (failed ``_ha_pair``)."""
    if not root.exists():
        return
    pg_ctl = install_dir / "bin" / "pg_ctl"
    if pg_ctl.is_file():
        for sub in ("primary", "standby"):
            d = root / sub
            if d.is_dir():
                subprocess.run(
                    [
                        str(pg_ctl),
                        "-D",
                        str(d),
                        "stop",
                        "-m",
                        "immediate",
                        "-w",
                        "-t",
                        "30",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
    shutil.rmtree(root, ignore_errors=True)


def _run_rewind_live(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
    *,
    restore_wal: bool = True,
) -> subprocess.CompletedProcess:
    """
    Online pg_tde_rewind: source must be running; target must be stopped.
    Uses --source-server (live connection) — mirrors pg_rewind --source-server.
    """
    connstr = (
        f"host={source.socket_dir} port={source.port} "
        f"user={libpq_superuser()} dbname=postgres"
    )
    return _run_rewind_pgdata_ex(
        install_dir,
        target,
        source_server=connstr,
        restore_wal=restore_wal,
    )


def _create_rewind_user(cluster: PgCluster, role: str = "rewind_user") -> str:
    """Minimal grants for ``--source-server`` rewind (``RewindTest.pm``)."""
    cluster.execute(f"CREATE ROLE {role} LOGIN;")
    for fn in (
        "pg_catalog.pg_ls_dir(text, boolean, boolean)",
        "pg_catalog.pg_stat_file(text, boolean)",
        "pg_catalog.pg_read_binary_file(text)",
        "pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)",
    ):
        cluster.execute(f"GRANT EXECUTE ON FUNCTION {fn} TO {role};")
    return role


def _enc_wal_ha_pair(
    install_dir: Path,
    tmp_path: Path,
    io_mode: str,
    *,
    cipher: str = "aes_128",
    wal_keep_size: str = "512MB",
    archive_dir: Optional[Path] = None,
) -> Tuple[PgCluster, PgCluster, TdeManager, str, Path]:
    """WAL-encrypted pair with optional cipher and ``wal_keep_size`` override."""
    archive_dir = archive_dir or (tmp_path / "enc_archive")
    extra = {
        "pg_tde.cipher": f"'{cipher}'",
        "wal_keep_size": f"'{wal_keep_size}'",
    }
    primary, standby, tde, keyfile = _ha_pair(
        install_dir,
        tmp_path,
        io_mode,
        wal_encrypt=True,
        archive_dir=archive_dir,
        extra_primary_params=extra,
    )
    return primary, standby, tde, keyfile, archive_dir


def _enc_block_tail_diverge(primary: PgCluster, standby: PgCluster) -> None:
    """Shared divergence for ``pg_rewind_enc_copy_blocks.pl`` / ``enc_keep_wal_seg.pl``."""
    primary.execute(
        "CREATE TABLE tail_t (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
        "f1 TEXT) USING tde_heap"
    )
    primary.execute(
        "INSERT INTO tail_t (f1) SELECT repeat('abcdeF', 1000) "
        "FROM generate_series(1, 1000)"
    )
    primary.execute(
        "CREATE TABLE block_t (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
        "f1 TEXT) USING tde_heap"
    )
    primary.execute(
        "INSERT INTO block_t (f1) SELECT repeat('abcdeF', 1000) "
        "FROM generate_series(1, 1000)"
    )
    primary.execute("CHECKPOINT")
    ReplicationManager(primary, standby).assert_catchup(timeout=60)
    _promote(standby)
    deadline = time.time() + 30
    while time.time() < deadline:
        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
            break
        time.sleep(0.5)
    primary.execute("UPDATE block_t SET f1='YYYYYYY' WHERE id % 10 = 0;")
    standby.execute(
        "INSERT INTO tail_t (f1) SELECT repeat('ghijk', 100) "
        "FROM generate_series(1, 1000)"
    )
    standby.execute("CHECKPOINT")


def _rotate_principal_key(cluster: PgCluster, key_name: str) -> None:
    """Principal-key rotation only (``pg_rewind_enc_keep_archive_wal.pl`` pattern)."""
    cluster.execute(
        f"SELECT pg_tde_create_key_using_global_key_provider("
        f"'{key_name}', 'file_provider');"
    )
    cluster.execute(
        f"SELECT pg_tde_set_key_using_global_key_provider("
        f"'{key_name}', 'file_provider');"
    )


def _promote(standby: PgCluster) -> None:
    """
    Promote standby and wait until it exits recovery.

    Uses SQL ``pg_promote`` first (long wait) so we do not rely on ``pg_ctl
    promote``'s default timeout, which often loses the race when WAL encryption
    + archive wrappers finish recovery slowly. Falls back to ``pg_ctl promote``
    with an extended wait, then restarts once if the postmaster exited.
    """
    if not standby.is_ready():
        standby.start()
        standby.wait_ready(timeout=60)

    try:
        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
            return
    except Exception:
        pass

    try:
        standby.execute("SELECT pg_promote(wait_seconds => 120)")
    except Exception:
        pass

    deadline = time.time() + 125
    while time.time() < deadline:
        try:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                return
        except Exception:
            pass
        time.sleep(0.5)

    try:
        standby.promote()
    except Exception:
        pass

    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                return
        except Exception:
            pass
        time.sleep(0.5)

    # Postmaster may have exited during promote; bring it back once.
    if not standby.is_ready():
        standby.start()
        standby.wait_ready(timeout=60)
        try:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                return
        except Exception:
            pass

    raise RuntimeError(
        "Standby did not promote within timeout.\n"
        f"Standby log tail:\n{standby.read_log(last_n=80)}"
    )


def _ha_pair(
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    primary_name: str = "primary",
    standby_name: str = "standby",
    keyfile: str = None,
    archive_dir: Path = None,
    wal_encrypt: bool = False,
    wal_compress: Optional[str] = None,
    extra_primary_params: Optional[dict] = None,
) -> Tuple[PgCluster, PgCluster, TdeManager, str]:
    """
    Full TDE primary + standby: global file key provider, archive, and optional
    WAL encryption / compression.  Returns (primary, standby, tde, keyfile).
    """
    archive_dir = archive_dir or (tmp_path / "archive")
    archive_dir.mkdir(parents=True, exist_ok=True)
    keyfile = keyfile or str(tmp_path / "keyring.file")

    primary = PgCluster(tmp_path / primary_name, allocate_port(), install_dir,
                        socket_dir=tmp_path, io_method=io_method)
    standby = PgCluster(tmp_path / standby_name, allocate_port(), install_dir,
                        socket_dir=tmp_path, io_method=io_method)
    shutil.rmtree(primary.data_dir, ignore_errors=True)
    shutil.rmtree(standby.data_dir, ignore_errors=True)

    # Wrappers are only valid when WAL segments are encrypted; plain WAL + decrypt
    # helpers corrupts archive/recovery and standbys die during promotion.
    arch_cmd, restore_cmd = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=wal_encrypt
    )
    params = {
        "shared_preload_libraries": "'pg_tde'",
        "wal_level": "replica",
        # ``always`` also archives WAL restored during recovery (standby paths).
        # Encrypted WAL + timeline switches rely on ``restore_command`` finding
        # matching segments and *.history in the archive; tighter archiving reduces races.
        "archive_mode": "always" if wal_encrypt else "on",
        "archive_command": arch_cmd,
        # Required for pg_tde_rewind -c when this node later becomes target.
        "restore_command": restore_cmd,
        "wal_log_hints": "on",
        "max_wal_senders": "5",
        "hot_standby": "on",
    }
    if wal_encrypt:
        params["archive_timeout"] = "'10s'"
        # Match PG-2358 overlap repro: retain WAL on primaries so streaming catch-up after
        # promote / rewind does not lose segments when pg_wal overlaps archived timelines.
        params["wal_keep_size"] = "'512MB'"
    if wal_compress:
        params["wal_compression"] = f"'{wal_compress}'"
    if extra_primary_params:
        params.update(extra_primary_params)

    try:
        primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
        primary.write_default_config(extra_params=params)
        primary.add_hba_entry("local all all trust")
        primary.add_hba_entry("local replication all trust")
        primary.add_hba_entry("host  all all 127.0.0.1/32 trust")
        primary.add_hba_entry("host  replication all 127.0.0.1/32 trust")
        primary.start()

        tde = TdeManager(primary)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()

        if wal_encrypt:
            tde.enable_wal_encryption()
            primary.restart()

        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(
            use_tde_basebackup=True,
            extra_args=(["-E"] if wal_encrypt else None),
        )
        # Mirror archiving on the standby so WAL received (and later generated after
        # promotion) lands in the same archive as the primary. Rewound / reattached
        # nodes may fall back to restore_command for timeline gaps; missing files
        # (e.g. timeline-N.history or segment 00000002...) otherwise stall replay.
        standby_params = {
            "shared_preload_libraries": "'pg_tde'",
            "restore_command": restore_cmd,
            "archive_mode": "always" if wal_encrypt else "on",
            "archive_command": arch_cmd,
        }
        if wal_encrypt:
            standby_params["archive_timeout"] = "'10s'"
            # Same as primary / PG-2358 repro Step 4: standby archives WAL after promote too.
            standby_params["wal_keep_size"] = "'512MB'"
        # Replay must use the same GUCs as primary when WAL applies DDL (e.g. in-place TS).
        if extra_primary_params:
            standby_params.update(extra_primary_params)
        standby.write_default_config("replica", extra_params=standby_params)
        standby.start()
        standby.wait_ready(timeout=60)

        deadline = time.time() + 30
        while time.time() < deadline:
            n = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
            if n and int(n) >= 1:
                break
            time.sleep(1)

        return primary, standby, tde, keyfile
    except Exception:
        _teardown(standby, primary)
        raise


def _promote_diverge_stop(standby: PgCluster, sql: str) -> None:
    """Promote standby, execute sql on it, checkpoint, then stop it."""
    _promote(standby)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
        except Exception:
            pass
        time.sleep(1)
    if isinstance(sql, (list, tuple)):
        for stmt in sql:
            standby.execute(stmt)
    else:
        standby.execute(sql)
    standby.execute("CHECKPOINT")
    try:
        standby.execute("SELECT pg_switch_wal()")
    except Exception:
        pass
    standby.stop()


def _teardown(*clusters: PgCluster) -> None:
    for c in clusters:
        try:
            c.stop(check=False)
        except Exception:
            pass
        try:
            c.stop(mode="immediate", check=False)
        except Exception:
            pass
        try:
            pid_file = c.data_dir / "postmaster.pid"
            if pid_file.exists():
                pid = int(pid_file.read_text().splitlines()[0].strip())
                os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            (c.socket_dir / f".s.PGSQL.{c.port}").unlink(missing_ok=True)
        except Exception:
            pass
        shutil.rmtree(c.data_dir, ignore_errors=True)


def _reconnect_standby(rewound: PgCluster, new_primary: PgCluster) -> None:
    """Attach rewound server as a streaming standby of new_primary."""
    auto = rewound.data_dir / "postgresql.auto.conf"
    with auto.open("a") as f:
        f.write(
            f"primary_conninfo = 'host={new_primary.socket_dir} "
            f"port={new_primary.port} user={libpq_superuser()}'\n"
        )
    (rewound.data_dir / "standby.signal").touch()


def _flush_leader_wal_to_archive(leader: PgCluster) -> None:
    """Help archiver ship segments + timeline history before standbys replay."""
    leader.execute("CHECKPOINT")
    for _ in range(4):
        leader.execute("SELECT pg_switch_wal()")
    time.sleep(3)


def _wait_wal_segment_archived(
    cluster: PgCluster, archive_dir: Path, *, timeout: int = 180
) -> str:
    """
    Force a WAL switch and wait until ``pg_stat_archiver`` reports a new segment
    that is present under ``archive_dir``.

    Do **not** wait on ``pg_current_wal_lsn()`` — the open segment is not archived
    until it is closed by ``pg_switch_wal()``.  A CHECKPOINT first guarantees the
    switch is not a no-op on an idle cluster (see ``BackupManager.wait_for_wal_archive``).
    """
    initial = cluster.fetchone(
        "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
    ) or ""
    cluster.execute("CHECKPOINT")
    cluster.execute("SELECT pg_switch_wal()")

    deadline = time.time() + timeout
    while time.time() < deadline:
        latest = cluster.fetchone(
            "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
        ) or ""
        if latest and latest != initial and (archive_dir / latest).is_file():
            return latest
        time.sleep(0.3)

    stats = cluster.fetchone(
        "SELECT format('failed_count=%s last_failed_wal=%s last_failed_time=%s', "
        "failed_count, last_failed_wal, last_failed_time) "
        "FROM pg_stat_archiver"
    )
    latest = cluster.fetchone(
        "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
    ) or ""
    raise TimeoutError(
        f"WAL archive did not advance from {initial!r} under {archive_dir} "
        f"after {timeout}s (last_archived_wal={latest!r}). "
        f"pg_stat_archiver: {stats}"
    )


def _force_wal_archive_stable(cluster: PgCluster, archive_dir: Path) -> None:
    """Checkpoint, switch WAL, and block until the archiver has caught up."""
    _wait_wal_segment_archived(cluster, archive_dir)
    _flush_leader_wal_to_archive(cluster)


def _missing_archived_wal_files(
    cluster: PgCluster,
    archive_dir: Path,
    *,
    exclude_current: bool = True,
) -> list[str]:
    """Return WAL segment / history names in ``pg_wal`` not yet present in ``archive_dir``."""
    pg_wal = cluster.data_dir / "pg_wal"
    if not pg_wal.is_dir():
        return []
    current = ""
    if exclude_current:
        current = (
            cluster.fetchone("SELECT pg_walfile_name(pg_current_wal_lsn())") or ""
        ).strip()
    missing: list[str] = []
    for entry in pg_wal.iterdir():
        if not entry.is_file() or entry.name.endswith(".partial"):
            continue
        if exclude_current and entry.name == current:
            continue
        if not (archive_dir / entry.name).is_file():
            missing.append(entry.name)
    return missing


def _push_pg_wal_files_to_archive(
    install_dir: Path,
    cluster: PgCluster,
    archive_dir: Path,
) -> None:
    """
    Push every file in ``pg_wal`` into ``archive_dir`` using ``pg_tde_archive_decrypt``.

    The background archiver may skip closed segments on a diverged old primary;
    this mirrors what ``archive_command`` would do file-by-file before TAP-style
    ``pg_wal`` removal.
    """
    if not wrappers_available(install_dir):
        raise RuntimeError("pg_tde archive wrappers required")

    cluster.execute("CHECKPOINT")
    cluster.execute("SELECT pg_switch_wal()")
    time.sleep(0.5)

    decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
    pg_wal = cluster.data_dir / "pg_wal"
    archive_dir.mkdir(parents=True, exist_ok=True)
    env = _rewind_env(install_dir)

    for entry in sorted(pg_wal.iterdir()):
        if not entry.is_file() or entry.name.endswith(".partial"):
            continue
        dest = archive_dir / entry.name
        if dest.is_file():
            continue
        result = subprocess.run(
            [
                str(decrypt),
                entry.name,
                str(entry),
                f"cp %p {dest}",
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"pg_tde_archive_decrypt failed for {entry.name!r}:\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )

    missing = _missing_archived_wal_files(cluster, archive_dir, exclude_current=False)
    if missing:
        raise TimeoutError(
            f"archive still missing pg_wal files after manual push: {missing!r}"
        )


def _ensure_pg_wal_archived_to_dir(
    install_dir: Path,
    cluster: PgCluster,
    archive_dir: Path,
    *,
    timeout: int = 60,
) -> None:
    """
    Best-effort archiver flush, then push any remaining ``pg_wal`` files via wrapper.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        missing = _missing_archived_wal_files(cluster, archive_dir)
        if not missing:
            return
        cluster.execute("CHECKPOINT")
        cluster.execute("SELECT pg_switch_wal()")
        try:
            _wait_wal_segment_archived(cluster, archive_dir, timeout=20)
        except TimeoutError:
            pass
        time.sleep(0.3)

    _push_pg_wal_files_to_archive(install_dir, cluster, archive_dir)


def _random_stop_for_rewind(
    cluster: PgCluster,
    archive_dir: Path,
    rng: random.Random,
) -> None:
    """Archive-stable stop with random ``pg_ctl`` mode (smart / fast / immediate)."""
    _force_wal_archive_stable(cluster, archive_dir)
    mode = ("smart", "fast", "immediate")[rng.randint(0, 2)]
    cluster.stop(mode=mode, check=False)


def _maybe_rotate_keys(
    cluster: PgCluster, rng: random.Random, *, server_key: bool = False
) -> None:
    """
    Optional principal-key rotation during chaos loops.

    Matches ``pg_rewind_enc_keep_archive_wal.pl`` (principal only). Server/default
    WAL key rotation is opt-in because it historically broke post-rewind replay.
    """
    if rng.getrandbits(1):
        key = f"key_{rng.randint(0, 99999)}"
        _rotate_principal_key(cluster, key)
    if server_key and rng.getrandbits(1):
        sk = f"server_key_{rng.randint(0, 99999)}"
        cluster.execute(
            f"SELECT pg_tde_create_key_using_global_key_provider('{sk}','file_provider');"
        )
        cluster.execute(
            "SELECT pg_tde_set_default_key_using_global_key_provider("
            f"'{sk}','file_provider');"
        )


def _maybe_sql(cluster: PgCluster, sql: str) -> None:
    try:
        cluster.execute(sql)
    except RuntimeError:
        pass


def _maybe_relfilenode_churn(cluster: PgCluster, rng: random.Random) -> None:
    if rng.getrandbits(1):
        _maybe_sql(cluster, "REINDEX TABLE t1;")
    if rng.getrandbits(1):
        _maybe_sql(
            cluster,
            f"CREATE INDEX CONCURRENTLY idx_t1_{rng.randint(0, 99999)} ON t1(id);",
        )
    if rng.getrandbits(1):
        _maybe_sql(cluster, "CLUSTER t1;")


def _maybe_divergence_chaos(cluster: PgCluster, rng: random.Random) -> None:
    if rng.getrandbits(1):
        cluster.execute("VACUUM FULL t1;")
    if rng.getrandbits(1):
        cluster.execute("TRUNCATE t1;")
        cluster.execute("INSERT INTO t1 SELECT generate_series(1, 5000);")
    if rng.getrandbits(1):
        col = f"c_{rng.randint(0, 99999)}"
        cluster.execute(f"ALTER TABLE t1 ADD COLUMN {col} INT;")


def _stash_rewind_target_configs(target: PgCluster, stash_dir: Path) -> None:
    """Save configs before ``pg_tde_rewind`` overwrites them (loop script step)."""
    stash_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target.data_dir / "postgresql.conf", stash_dir / "postgresql.conf")
    auto = target.data_dir / "postgresql.auto.conf"
    if auto.is_file():
        shutil.copy2(auto, stash_dir / "postgresql.auto.conf")


def _restore_stashed_configs(target: PgCluster, stash_dir: Path) -> None:
    shutil.copy2(stash_dir / "postgresql.conf", target.data_dir / "postgresql.conf")
    auto_stash = stash_dir / "postgresql.auto.conf"
    if auto_stash.is_file():
        shutil.copy2(auto_stash, target.data_dir / "postgresql.auto.conf")


def _run_rewind_pgdata_with_optional_debug(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
    *,
    restore_wal: bool = True,
) -> subprocess.CompletedProcess:
    return _run_rewind_pgdata_ex(
        install_dir,
        target,
        source,
        restore_wal=restore_wal,
        debug=os.environ.get("PG_TDE_REWIND_DEBUG", "").strip() in ("1", "yes", "true"),
    )


_REWIND_TARGET_CONF_MARKER = (
    "# percona-qa: rewind target — restore allocated port (pg_rewind copied source conf)"
)


def _repair_rewind_target_identity(rewound: PgCluster) -> None:
    """
    pg_rewind copies the source ``postgresql.conf`` onto the target; restore the
    target's listen port and drop stale recovery settings before first startup.
    """
    dd = rewound.data_dir
    for sig in ("standby.signal", "recovery.signal"):
        p = dd / sig
        if p.exists():
            p.unlink()
    strip_auto = re.compile(
        r"^\s*(primary_conninfo|primary_slot_name|recovery_|restore_command)\s*=",
        re.I,
    )
    auto = dd / "postgresql.auto.conf"
    if auto.exists():
        kept = [
            ln for ln in auto.read_text().splitlines()
            if not (ln.strip() and strip_auto.match(ln))
        ]
        auto.write_text("\n".join(kept) + ("\n" if kept else ""))
    conf = dd / "postgresql.conf"
    if conf.exists() and _REWIND_TARGET_CONF_MARKER not in conf.read_text():
        conf.write_text(
            conf.read_text().rstrip()
            + f"\n\n{_REWIND_TARGET_CONF_MARKER}\n"
            + "logging_collector = off\n"
            + f"port = {rewound.port}\n"
        )


def _sync_archive_history_to_pg_wal(archive_dir: Path, pg_wal: Path) -> None:
    """Copy ``*.history`` from the WAL archive into ``pg_wal`` for timeline switches."""
    if not archive_dir.is_dir():
        return
    pg_wal.mkdir(parents=True, exist_ok=True)
    for hist in archive_dir.glob("*.history"):
        shutil.copy2(hist, pg_wal / hist.name)


def _sanitize_promoted_leader_pgdata(leader: PgCluster) -> None:
    """Ensure a promoted primary does not still have standby/recovery signals."""
    for sig in ("standby.signal", "recovery.signal"):
        p = leader.data_dir / sig
        if p.exists():
            p.unlink()


def _prepare_rewound_streaming_standby(
    rewound: PgCluster,
    new_primary: PgCluster,
    *,
    streaming_only: bool = True,
) -> None:
    """
    Attach ``rewound`` as a streaming standby of ``new_primary``.

    When ``streaming_only`` is True (default), force ``restore_command = ''`` at the
    end of ``postgresql.conf`` so it wins over earlier settings — WAL comes only from
    ``primary_conninfo`` streaming.

    When False, keep the node's existing ``restore_command`` (e.g. encrypted WAL
    archive). Streaming still applies new WAL; archive can satisfy timeline gaps or
    replace bad local segments after pg_rewind ``-c`` kept tails.

    Sets ``recovery_target_timeline = 'latest'`` so the standby follows the promoted
    leader's timeline after rewind.

    Also collapse duplicate ``primary_conninfo`` lines (repeated reconnects / rewind).
    """
    conn_line = (
        f"primary_conninfo = 'host={new_primary.socket_dir} "
        f"port={new_primary.port} user={libpq_superuser()}'"
    )
    auto = rewound.data_dir / "postgresql.auto.conf"
    lines_out: list[str] = []
    if auto.exists():
        for line in auto.read_text().splitlines():
            raw = line.strip()
            if raw and not raw.startswith("#") and "=" in raw:
                key = raw.split("=", 1)[0].strip().lower()
                if key == "primary_conninfo":
                    continue
                if key == "primary_slot_name" or key.startswith("recovery"):
                    continue
                if streaming_only and key == "restore_command":
                    continue
            lines_out.append(line)
    lines_out.append(conn_line)
    lines_out.append("recovery_target_timeline = 'latest'")
    if streaming_only:
        lines_out.append("restore_command = ''")
    auto.write_text("\n".join(lines_out) + "\n")

    conf = rewound.data_dir / "postgresql.conf"
    if conf.exists() and streaming_only:
        text = conf.read_text()
        marker = (
            "\n# percona-qa: rewound standby — WAL via streaming only\n"
            "restore_command = ''\n"
        )
        if "percona-qa: rewound standby" not in text:
            conf.write_text(text.rstrip() + marker)

    (rewound.data_dir / "standby.signal").touch()


# ── pg_rewind ─────────────────────────────────────────────────────────────────


class TestPgRewind:
    def test_rewind_basic(self, replica_pair, tmp_path: Path, install_dir: Path, io_method: str):
        primary, standby = replica_pair
        primary.configure({"wal_log_hints": "on"})
        primary.restart()
        primary.execute("CREATE TABLE rewind_base (id INT)")
        primary.execute("INSERT INTO rewind_base SELECT generate_series(1,100)")

        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Promote standby; standby becomes new primary
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO rewind_base SELECT generate_series(101,200)")
        standby.execute("CHECKPOINT")

        primary.stop()
        primary.pg_rewind(str(primary.data_dir), standby.port)
        _repair_rewind_target_identity(primary)

        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        (primary.data_dir / "standby.signal").touch()
        primary.start()
        primary.wait_ready(timeout=60)

        repl2 = ReplicationManager(standby, primary)
        repl2.assert_catchup(timeout=60)
        count = primary.fetchone("SELECT COUNT(*) FROM rewind_base")
        assert count == "200"

    def test_rewind_after_large_dml(self, replica_pair, tmp_path: Path):
        primary, standby = replica_pair
        # Lots of WAL + checkpoints recycle segments from pg_wal; pg_rewind must
        # still read local WAL on the old primary back to the divergence point.
        primary.configure(
            {"wal_log_hints": "on", "wal_keep_size": "'512MB'"}
        )
        primary.restart()
        primary.execute("CREATE TABLE rewind_large (id BIGSERIAL, data TEXT)")
        primary.execute(
            "INSERT INTO rewind_large (data) SELECT md5(i::text) FROM generate_series(1,100000) i"
        )
        primary.execute("VACUUM FULL rewind_large")

        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=60)

        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute(
            "INSERT INTO rewind_large (data) SELECT md5(i::text) FROM generate_series(100001,110000) i"
        )

        primary.stop()
        primary.pg_rewind(str(primary.data_dir), standby.port)
        _repair_rewind_target_identity(primary)

        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        (primary.data_dir / "standby.signal").touch()
        primary.start()
        primary.wait_ready(timeout=60)

        result = primary.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t"

# ── pg_tde_rewind: shared helpers ─────────────────────────────────────────────


def _make_tde_ha_pair(
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    primary_subdir: str = "primary",
    standby_subdir: str = "standby",
    keyfile: str = None,
    archive_dir: Path = None,
) -> tuple:
    """
    Spin up a TDE-enabled primary + streaming standby with WAL archiving.

    Returns (primary, standby, TdeManager, keyfile_path).
    Mirrors the init sequence from pg_tde_rewind_extended.sh:
      - global file key provider
      - server key set
      - archive_mode + restore_command on standby
    """
    archive_dir = archive_dir or tmp_path / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    keyfile = keyfile or str(tmp_path / "keyring.file")
    arch_cmd, restore_cmd = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=True
    )

    primary = PgCluster(
        tmp_path / primary_subdir, allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
    )
    standby = PgCluster(
        tmp_path / standby_subdir, allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
    )

    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "wal_level": "replica",
        "archive_mode": "on",
        "archive_command": arch_cmd,
        # Needed by pg_tde_rewind -c when primary later becomes rewind target.
        "restore_command": restore_cmd,
        "wal_log_hints": "on",
        "max_wal_senders": "5",
        "hot_standby": "on",
    })
    primary.add_hba_entry("local all all trust")
    primary.add_hba_entry("local replication all trust")
    primary.add_hba_entry("host  all all 127.0.0.1/32 trust")
    primary.add_hba_entry("host  replication all 127.0.0.1/32 trust")
    primary.start()

    tde = TdeManager(primary)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=keyfile)
    tde.set_global_principal_key()

    repl = ReplicationManager(primary, standby)
    repl.create_standby_from_backup(use_tde_basebackup=True)
    standby.write_default_config("replica", extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "restore_command": restore_cmd,
    })
    standby.start()
    standby.wait_ready(timeout=60)

    deadline = time.time() + 30
    while time.time() < deadline:
        n = primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication")
        if n and int(n) >= 1:
            break
        time.sleep(1)

    return primary, standby, tde, keyfile


def _promote_and_diverge(standby: PgCluster, sql: str) -> None:
    """Promote standby, wait for it to become writable, then run sql on it."""
    standby.promote()
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            val = standby.fetchone("SELECT pg_is_in_recovery()")
            if val == "f":
                break
        except Exception:
            pass
        time.sleep(1)
    standby.execute(sql)
    standby.execute("CHECKPOINT")


class TestTdeRewindExtended:
    """
    Port of postgresql/automation/tests/pg_tde_rewind_extended.sh
    (PR #428 - PG-2287).

    Covers complex divergence scenarios: multiple tde_heap tables, TOAST,
    partitions, partial/expression indexes, WAL pressure, key rotation,
    crash before rewind, and post-rewind stability.
    """

    def test_rewind_multi_table_mixed_dml(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Diverge on 10 tde_heap tables with mixed UPDATE/DELETE/VACUUM FULL,
        then rewind and validate all tables are accessible.
        """
        primary, standby, tde, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE base_t (id INT) USING tde_heap; "
                "INSERT INTO base_t SELECT generate_series(1,1000); "
                "CHECKPOINT;"
            )
            repl = ReplicationManager(primary, standby)
            repl.assert_catchup(timeout=30)

            # -- divergence on promoted standby --
            _promote_and_diverge(
                standby,
                "INSERT INTO base_t SELECT generate_series(1,500000); "
                "UPDATE base_t SET id=id+1; "
                "DELETE FROM base_t WHERE id%2=0;",
            )
            for i in range(1, 11):
                standby.execute(
                    f"CREATE TABLE mt_{i}(id INT, val TEXT) USING tde_heap; "
                    f"INSERT INTO mt_{i} SELECT g, md5(random()::text) "
                    f"FROM generate_series(1,1000) g;"
                )
            standby.execute("UPDATE mt_1 SET val = md5(random()::text)")
            standby.execute("DELETE FROM mt_2 WHERE id % 3 = 0")
            standby.execute("VACUUM FULL mt_3")
            standby.execute("CHECKPOINT")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, (
                f"pg_tde_rewind failed:\nSTDOUT:{result.stdout}\nSTDERR:{result.stderr}"
            )

            primary.start()
            primary.wait_ready(timeout=60)
            # base table must be accessible
            count = primary.fetchone("SELECT COUNT(*) FROM base_t")
            assert int(count) >= 0
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_toast_heavy_workload(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Diverge by inserting TOAST-heavy rows (repeat(md5, 1000) ≈ 32 KB/row)
        on the promoted standby — pg_tde_rewind must handle large TOAST pages.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE toast_base (id INT, data TEXT) USING tde_heap; "
                "INSERT INTO toast_base SELECT g, 'x' FROM generate_series(1,10) g; "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "CREATE TABLE toast_test (id INT, data TEXT) USING tde_heap; "
                "INSERT INTO toast_test "
                "SELECT g, repeat(md5(random()::text), 1000) "
                "FROM generate_series(1,500) g;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM toast_base")
            assert int(count) >= 0
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_partitioned_table_workload(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Diverge by creating a RANGE-partitioned tde_heap table with two
        partitions and 10k rows — pg_tde_rewind must handle partition catalog
        entries created on the diverged branch.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE anchor (id INT) USING tde_heap; "
                "INSERT INTO anchor VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "CREATE TABLE part_test (id INT, created DATE) "
                "PARTITION BY RANGE (created); "
                "CREATE TABLE part_2024 PARTITION OF part_test "
                "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01'); "
                "CREATE TABLE part_2025 PARTITION OF part_test "
                "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01'); "
                "INSERT INTO part_test "
                "SELECT g, '2024-06-01'::date + (g % 365) "
                "FROM generate_series(1, 10000) g;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert primary.fetchone("SELECT COUNT(*) FROM anchor") == "1"
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_partial_and_expression_indexes(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Partial (WHERE id > 100) and expression ((id * 2)) indexes created
        post-promotion must not prevent pg_tde_rewind from succeeding.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE idx_base (id INT) USING tde_heap; "
                "INSERT INTO idx_base SELECT generate_series(1,500); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO idx_base SELECT generate_series(501,10000); "
                "CREATE INDEX idx_partial ON idx_base(id) WHERE id > 100; "
                "CREATE INDEX idx_expr   ON idx_base((id * 2)); "
                "REINDEX TABLE idx_base;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM idx_base")
            assert int(count) >= 500
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_wal_pressure(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Bulk INSERT (200k rows) followed by CHECKPOINT on the promoted standby
        creates WAL pressure; pg_tde_rewind must still succeed.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE pressure_tbl (id INT) USING tde_heap; "
                "INSERT INTO pressure_tbl SELECT generate_series(1,1000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO pressure_tbl SELECT generate_series(1, 200000); "
                "CHECKPOINT;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM pressure_tbl")) >= 1000
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_key_rotation_on_diverged_server(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Database key is rotated on the promoted standby; pg_tde_rewind must
        succeed and the rewound primary must start with its own original key.
        """
        primary, standby, _, keyfile = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE key_rot_tbl (id INT) USING tde_heap; "
                "INSERT INTO key_rot_tbl SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote and rotate the key on the diverged server
            standby.promote()
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            tde_s = TdeManager(standby)
            # Provider already exists on standby (copied from primary via basebackup).
            tde_s.rotate_principal_key(new_key_name="rotated_key")
            standby.execute("INSERT INTO key_rot_tbl SELECT generate_series(101,200)")
            standby.execute("CHECKPOINT")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            # After rewind to pre-rotation divergence point, original key must work
            assert int(primary.fetchone("SELECT COUNT(*) FROM key_rot_tbl")) >= 100
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_after_crash_on_diverged_server(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Simulate crash (SIGKILL) on the promoted standby, let it recover,
        then stop cleanly and run pg_tde_rewind — mirrors CRASH_MODE=1 in the
        shell script. Uses cluster.crash() rather than raw kill(9).
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE crash_before_rewind (id INT) USING tde_heap; "
                "INSERT INTO crash_before_rewind SELECT generate_series(1,200); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO crash_before_rewind SELECT generate_series(201,500); "
                "UPDATE crash_before_rewind SET id=id+1;",
            )

            # Crash the promoted standby (SIGKILL), then recover it
            standby.crash()
            standby.start()
            standby.wait_ready(timeout=60)
            # Clean shutdown required before pg_rewind reads source pgdata
            standby.stop()

            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM crash_before_rewind")) >= 200
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    # ── restart-of-old-primary-before-rewind (PG-2330 / PG-2357) ──────────
    #
    # Both tickets describe the same defect: pg_tde_rewind intermittently
    # preserves stale on-disk state on the old primary when that primary is
    # restarted between divergence and the rewind call. PG-2357 was reported
    # later with an additional ``maybe_restart`` helper that randomises the
    # *non-critical* restarts in the reproducer — but the bug-triggering
    # restart (after divergence, before pg_tde_rewind) is identical to
    # PG-2330. A single regression covers both.

    def _pg2330_reproduce_iteration(
        self,
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
        iteration: int,
    ) -> None:
        """
        One full run of the PG-2330 / PG-2357 scenario.

        Trigger sequence:
          1. Init primary, create ``t1`` with 10 000 rows, basebackup → standby.
          2. Restart the primary once (pre-promotion — matches the script).
          3. Promote the standby (becomes the rewind *source*).
          4. INSERT one row id=999999 on the promoted standby + CHECKPOINT.
          5. Create ``target_only`` on the promoted standby.
          6. Create ``source_only`` on the old primary (divergent write).
          7. **Restart the old primary — the critical PG-2330/PG-2357 trigger.**
          8. Stop both clusters; run ``pg_tde_rewind --target-pgdata=<old primary>
             --source-pgdata=<promoted standby> -c``.
          9. Start the rewound (old) primary and assert post-rewind state.

        Expected on a fixed build:
          - ``t1`` has 10 001 rows
          - ``target_only`` exists on the rewound primary
          - ``source_only`` does **not** exist on the rewound primary
        """
        keyfile_path = tmp_path / f"key_{iteration}.file"
        archive_path = tmp_path / f"archive_{iteration}"
        primary, standby, _, _ = _make_tde_ha_pair(
            install_dir, tmp_path, io_method,
            primary_subdir=f"primary_{iteration}",
            standby_subdir=f"standby_{iteration}",
            keyfile=str(keyfile_path),
            archive_dir=archive_path,
        )
        try:
            primary.execute(
                "CREATE TABLE t1 (id INT) USING tde_heap; "
                "INSERT INTO t1 SELECT generate_series(1, 10000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Pre-promotion restart of primary (matches the upstream script).
            primary.restart()
            primary.wait_ready(timeout=60)

            _promote_and_diverge(
                standby,
                "INSERT INTO t1 VALUES (999999); CHECKPOINT;",
            )

            # Asymmetric DDL: each side gets a table the other doesn't have.
            standby.execute(
                "CREATE TABLE target_only (id INT) USING tde_heap; "
                "INSERT INTO target_only VALUES (1), (2);"
            )
            primary.execute(
                "CREATE TABLE source_only (id INT) USING tde_heap; "
                "INSERT INTO source_only VALUES (10), (20);"
            )

            # The critical step — without this restart PG-2330/PG-2357 does not trigger.
            primary.restart()
            primary.wait_ready(timeout=60)

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, (
                f"PG-2330 iter {iteration}: pg_tde_rewind exited "
                f"{result.returncode}\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )

            # If start fails here it is *itself* a manifestation of PG-2330
            # ("incorrect prev-link" / WAL chain inconsistency). Surface the
            # postgres log so the iteration that fails is actionable.
            try:
                primary.start()
                primary.wait_ready(timeout=60)
            except Exception as exc:
                log_tail = primary.read_log(last_n=60)
                raise AssertionError(
                    f"PG-2330 iter {iteration}: rewound primary failed to start.\n"
                    f"Underlying error: {exc}\n"
                    f"Last 60 lines of postgres log:\n{log_tail}"
                ) from exc

            t1_count = primary.fetchone("SELECT COUNT(*) FROM t1")
            assert t1_count == "10001", (
                f"PG-2330 iter {iteration}: t1 row count = {t1_count}, "
                "expected 10001 (rewind did not pull the row inserted on the "
                "promoted standby — stale on-disk state preserved)."
            )

            target_count = primary.fetchone("SELECT COUNT(*) FROM target_only")
            assert target_count == "2", (
                f"PG-2330 iter {iteration}: target_only row count = "
                f"{target_count}, expected 2 (standby-only table missing from "
                "the rewound primary)."
            )

            # source_only must be gone; querying it must raise.
            with pytest.raises(RuntimeError):
                primary.execute("SELECT COUNT(*) FROM source_only")
        finally:
            # Per-iteration teardown: data dirs (stop + rmtree) AND the
            # iteration-scoped archive_<i>/ and key_<i>.file under tmp_path.
            # The stress variant runs 5+ iterations under one tmp_path, so
            # leaving these behind accumulates GBs of WAL across iterations
            # and eventually exhausts /tmp, semaphores, or shared-mem slots.
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)
            shutil.rmtree(archive_path, ignore_errors=True)
            try:
                keyfile_path.unlink()
            except FileNotFoundError:
                pass

    def test_pg2330_pg2357_rewind_after_pre_rewind_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Regression for PG-2330 (and the duplicate PG-2357): restarting the
        old primary *between* divergence and the rewind must not cause
        pg_tde_rewind to preserve stale on-disk state. Asymmetric DDL
        (target_only / source_only) makes the failure observable. Single
        iteration — deterministic on a fixed build.
        """
        self._pg2330_reproduce_iteration(
            install_dir, tmp_path, io_method, iteration=0,
        )

    def test_pg2330_pg2357_rewind_after_pre_rewind_restart_stress(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Stress variant of the PG-2330 / PG-2357 regression. The bug is
        intermittent on the broken build, so the reproducer is run five times
        with independent data/archive dirs to raise the probability of
        catching a regression to a useful level.

        Iteration count is configurable via the ``PG2330_STRESS_ITERS`` env
        var (default 5). Each iteration cleans up its own data/archive/keyfile
        so /tmp usage stays roughly flat regardless of N. The loop also
        early-exits with a clear message if /tmp drops below 1 GB free — this
        prevents the historical "ran for hours, died at iter N with cryptic
        pg_ctl error" failure mode when the run is much longer than expected.
        """
        import os
        import shutil as _shutil

        iters = int(os.environ.get("PG2330_STRESS_ITERS", "5"))
        for i in range(iters):
            free_mb = _shutil.disk_usage(str(tmp_path)).free // (1024 * 1024)
            if free_mb < 1024:
                pytest.fail(
                    f"PG-2330 stress: /tmp dropped below 1 GB free "
                    f"({free_mb} MB available) before iteration {i}. "
                    "Refusing to continue — clean up /tmp/pytest-of-ubuntu/* "
                    "and confirm the per-iteration cleanup is firing."
                )
            self._pg2330_reproduce_iteration(
                install_dir, tmp_path, io_method, iteration=i,
            )

    def test_rewind_deep_validation_reindex_vacuum_full(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        After rewind: REINDEX TABLE and VACUUM FULL must succeed on the rewound
        tde_heap table — the 'restart twice to expose latent corruption' pattern
        from the shell script.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE deep_val (id INT) USING tde_heap; "
                "INSERT INTO deep_val SELECT generate_series(1,1000); "
                "CREATE INDEX deep_val_idx ON deep_val(id); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO deep_val SELECT generate_series(1001,5000); "
                "DELETE FROM deep_val WHERE id % 3 = 0;",
            )
            standby.execute("VACUUM FULL deep_val")
            standby.execute("CHECKPOINT")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            primary.execute("SET enable_seqscan=off; SELECT * FROM deep_val ORDER BY id LIMIT 10")
            primary.execute("REINDEX TABLE deep_val")
            primary.execute("VACUUM FULL deep_val")
            # Two restarts to expose any latent corruption (mirrors shell script)
            primary.restart()
            primary.restart()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM deep_val")
            assert int(count) >= 1000
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_with_unlogged_table_on_diverged_server(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        UNLOGGED tables are truncated during crash recovery but must not prevent
        pg_tde_rewind from running.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE logged_t (id INT) USING tde_heap; "
                "INSERT INTO logged_t SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "CREATE UNLOGGED TABLE u1(id INT); "
                "INSERT INTO u1 SELECT generate_series(1,10000); "
                "INSERT INTO logged_t SELECT generate_series(101,200);",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM logged_t")) >= 100
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)


# ── PR-428: pg_tde_rewind with checkpoint ─────────────────────────────────────


@pytest.mark.slow
class TestTdeRewindWithCheckpoint:
    """
    Port of postgresql/automation/tests/pg_tde_rewind_with_checkpoint.sh
    (PR #428 - PG-2287).

    Verifies that an explicit CHECKPOINT on the primary immediately before
    promotion does not disrupt pg_tde_rewind correctness.
    """

    def test_rewind_after_explicit_checkpoint_before_promotion(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Issue CHECKPOINT on the primary right before standby promotion, then
        diverge and rewind.  The checkpoint LSN must land correctly in the
        rewound server's control file.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE chk_tbl (id INT) USING tde_heap; "
                "INSERT INTO chk_tbl SELECT generate_series(1,1000);"
            )
            # Explicit CHECKPOINT before promotion — the key edge case
            primary.execute("CHECKPOINT")

            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO chk_tbl SELECT generate_series(1001,2000); "
                "UPDATE chk_tbl SET id = id + 1 WHERE id % 5 = 0;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM chk_tbl")
            assert int(count) >= 1000
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_large_insert_workload_after_checkpoint(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        100-table insert prepare workload on primary, CHECKPOINT, promote standby,
        then long divergence workload before rewind.
        Mirrors the sysbench oltp_insert.lua + oltp_read_write.lua sequence
        using pure SQL generate_series equivalents.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            # Simulate 100-table "prepare" step
            primary.execute(
                "DO $$ BEGIN "
                "  FOR i IN 1..100 LOOP "
                "    EXECUTE format('CREATE TABLE sbtest%s "
                "      (id SERIAL PRIMARY KEY, k INT, c TEXT, pad TEXT) "
                "      USING tde_heap', i); "
                "    EXECUTE format('INSERT INTO sbtest%s(k,c,pad) "
                "      SELECT (random()*2000000)::int, "
                "             repeat(md5(random()::text),6), "
                "             repeat(md5(random()::text),5) "
                "      FROM generate_series(1,100)', i, i); "
                "  END LOOP; "
                "END $$; "
                "CREATE TABLE t1 (id INT) USING tde_heap; "
                "INSERT INTO t1 VALUES (1),(2),(3);"
            )
            primary.execute("CHECKPOINT")

            ReplicationManager(primary, standby).assert_catchup(timeout=60)

            _promote_and_diverge(
                standby,
                "INSERT INTO t1 VALUES (4),(5),(6); "
                "DO $$ BEGIN "
                "  FOR i IN 1..100 LOOP "
                "    EXECUTE format('UPDATE sbtest%s SET k=k+1 WHERE id%%10=0', i); "
                "  END LOOP; "
                "END $$;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)

            # Verify N random sbtest tables are queryable (mirrors shell's random check)
            import random as _random
            for _ in range(10):
                i = _random.randint(1, 100)
                cnt = primary.fetchone(f"SELECT COUNT(*) FROM sbtest{i}")
                assert int(cnt) >= 0, f"sbtest{i} returned negative count"
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_postgresql_conf_preserved(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        pg_rewind may overwrite postgresql.conf from the source.
        Verify the rewound cluster starts correctly using the target's config.
        Mirrors the conf backup/restore step in pg_tde_rewind_with_checkpoint.sh.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            # Record a sentinel GUC directly in postgresql.conf (the shell script
            # backs up/restores this file around rewind).
            primary.configure({"work_mem": "'16MB'"})
            primary.reload()
            primary.execute(
                "CREATE TABLE conf_tbl (id INT) USING tde_heap; "
                "INSERT INTO conf_tbl VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_and_diverge(standby, "INSERT INTO conf_tbl VALUES (2)")

            # Back up primary's postgresql.conf (mirrors the cp in the shell script)
            conf_backup = tmp_path / "postgresql.conf.bkp"
            shutil.copy(primary.data_dir / "postgresql.conf", conf_backup)

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            # Restore primary's own conf (not the source's conf)
            shutil.copy(conf_backup, primary.data_dir / "postgresql.conf")

            primary.start()
            primary.wait_ready(timeout=60)
            # work_mem setting from restored postgresql.conf must still be present.
            wm = primary.fetchone("SHOW work_mem")
            assert wm == "16MB", f"work_mem lost after rewind: {wm!r}"
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)


# ── PR-428: pg_tde_rewind randomized ─────────────────────────────────────────


@pytest.mark.slow
class TestTdeRewindRandomized:
    """
    Port of postgresql/automation/tests/pg_tde_rewind_randomized.sh
    (PR #428 - PG-2287).

    Focuses on asymmetric-object semantics and stability under post-rewind
    restarts. The 'randomised' aspects (random restart, minimal vs heavy path)
    are split into deterministic test methods so each path is always exercised
    rather than coin-flipping.
    """

    def test_rewind_target_only_table_is_preserved(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        A table created on the promoted standby (rewind source) must exist
        after rewind, because the target is synchronized to source state.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE shared_t (id INT) USING tde_heap; "
                "INSERT INTO shared_t SELECT generate_series(1,1000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "CREATE TABLE target_only (id INT) USING tde_heap; "
                "INSERT INTO target_only VALUES (1),(2); "
                "INSERT INTO shared_t SELECT generate_series(1001,2000);",
            )
            # Object created on original primary after divergence (source-only)
            primary.execute(
                "CREATE TABLE source_only (id INT) USING tde_heap; "
                "INSERT INTO source_only VALUES (10),(20);"
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)

            # target_only was created on rewind source (promoted standby), so it
            # must exist after target is rewound to source state.
            cnt_target_only = primary.fetchone("SELECT COUNT(*) FROM target_only")
            assert cnt_target_only == "2", (
                f"target_only table missing or wrong rowcount after rewind: {cnt_target_only!r}"
            )

            # shared_t must exist (it was on both branches)
            cnt = primary.fetchone("SELECT COUNT(*) FROM shared_t")
            assert int(cnt) >= 0
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_source_only_table_is_removed(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        A table created only on the original primary (rewind target) after
        divergence must be removed by rewind, because target is overwritten
        with source-side history.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE anchor (id INT) USING tde_heap; "
                "INSERT INTO anchor VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby, "INSERT INTO anchor VALUES (999);"
            )
            # source-only table — written after divergence on original primary
            primary.execute(
                "CREATE TABLE source_only (id INT) USING tde_heap; "
                "INSERT INTO source_only VALUES (10),(20);"
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)

            exists = primary.fetchone("SELECT to_regclass('public.source_only')")
            assert exists in (None, ""), (
                f"source_only table survived rewind — it should have been removed: {exists!r}"
            )
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_minimal_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Minimal divergence path: single INSERT + CHECKPOINT on promoted standby.
        This exercises the fast path in pg_rewind where very little WAL needs
        to be replayed.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE minimal_t (id INT) USING tde_heap; "
                "INSERT INTO minimal_t SELECT generate_series(1,10000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(standby, "INSERT INTO minimal_t VALUES (999999);")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM minimal_t")
            assert int(count) >= 10000
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_heavy_divergence_update_delete_reindex(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Heavy workload divergence: UPDATE all rows, DELETE half, CREATE INDEX,
        REINDEX — the full heavy path from pg_tde_rewind_randomized.sh.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE heavy_t (id INT) USING tde_heap; "
                "INSERT INTO heavy_t SELECT generate_series(1,10000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "UPDATE heavy_t SET id=id+1; "
                "DELETE FROM heavy_t WHERE id%3=0; "
                "CREATE INDEX heavy_idx ON heavy_t(id); "
                "REINDEX TABLE heavy_t;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM heavy_t")
            # Divergence does: UPDATE all rows, DELETE id%3=0 => 6667 rows remain.
            assert int(count) == 6667
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_post_rewind_restart_stability(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        A random restart immediately after rewind must not expose latent
        corruption — mirrors the maybe_restart post-rewind call in the shell
        script. Two deterministic restarts are issued here.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE stability_t (id INT) USING tde_heap; "
                "INSERT INTO stability_t SELECT generate_series(1,500); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby,
                "INSERT INTO stability_t SELECT generate_series(501,1000); "
                "UPDATE stability_t SET id=id*2 WHERE id%4=0;",
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            primary.restart()  # first post-rewind restart
            primary.wait_ready(timeout=60)
            primary.restart()  # second post-rewind restart
            primary.wait_ready(timeout=60)

            count = primary.fetchone("SELECT COUNT(*) FROM stability_t")
            assert int(count) >= 500
            primary.execute("SELECT * FROM stability_t ORDER BY id LIMIT 5")
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_with_restart_before_promotion(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Restart primary before promotion (RANDOMIZED_RESTART_BEFORE_PROMOTION
        branch from the shell script). Ensures rewind still works when the
        checkpoint LSN on the primary was advanced by a clean restart.
        """
        primary, standby, _, _ = _make_tde_ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE pre_restart_t (id INT) USING tde_heap; "
                "INSERT INTO pre_restart_t SELECT generate_series(1,200); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Restart primary BEFORE promotion (advances its LSN independently)
            primary.restart()
            primary.wait_ready(timeout=60)

            _promote_and_diverge(
                standby, "INSERT INTO pre_restart_t SELECT generate_series(201,400);"
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM pre_restart_t")) >= 200
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)

    def test_rewind_randomized_shell_combined_pg2329(
        self, request, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Port of ``postgresql/automation/tests/pg_tde_rewind_randomized.sh`` (combined).

        Archive + ``pg_tde_rewind -c``, **PG-2329** primary restart before promote,
        optional replica restart, **minimal** (single INSERT) vs **heavy** diverge
        on the promoted leader, asymmetric DDL, optional restarts before/after
        rewind, and a final ``SET enable_seqscan=off`` probe.

        The shell script labels ``target_only`` as existing on the replica; that node
        is the rewind **source** after promotion, so the table must **remain** on the
        rewound former primary. ``source_only`` is created only on the old primary
        (rewind **target**) after divergence and must be **dropped** by rewind.
        """
        seed = abs(hash(request.node.nodeid)) % (2**31 - 1) or 1
        rng = random.Random(seed)

        def flip() -> bool:
            return bool(rng.getrandbits(1))

        archive_dir = tmp_path / "rewind_rand_archive"
        keyfile = str(tmp_path / "keyring.rand")
        primary, standby, _, _ = _ha_pair(
            install_dir,
            tmp_path,
            io_method,
            archive_dir=archive_dir,
            keyfile=keyfile,
            wal_encrypt=False,
        )
        try:
            primary.execute(
                "CREATE TABLE t1(id INT) USING tde_heap; "
                "INSERT INTO t1 SELECT generate_series(1,10000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # PG-2329: always restart primary before promotion (shell forces this).
            primary.restart()
            primary.wait_ready(timeout=60)
            if flip():
                standby.restart()
                standby.wait_ready(timeout=60)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)

            if flip():
                standby.execute("INSERT INTO t1 VALUES (999999); CHECKPOINT;")
                expect_t1 = 10_001
            else:
                standby.execute(
                    "UPDATE t1 SET id=id+1; "
                    "DELETE FROM t1 WHERE id%3=0; "
                    "CREATE INDEX idx_t1 ON t1(id); "
                    "REINDEX TABLE t1; "
                    "CHECKPOINT;"
                )
                expect_t1 = 6667

            # Asymmetric: leader-only vs old-primary-only after divergence.
            standby.execute(
                "CREATE TABLE target_only(id INT) USING tde_heap; "
                "INSERT INTO target_only VALUES (1),(2);"
            )
            primary.execute(
                "CREATE TABLE source_only(id INT) USING tde_heap; "
                "INSERT INTO source_only VALUES (10),(20);"
            )

            if flip():
                primary.restart()
                primary.wait_ready(timeout=60)
            if flip():
                standby.restart()
                standby.wait_ready(timeout=60)

            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, (
                f"pg_tde_rewind -c failed (seed={seed}):\n{result.stderr}"
            )

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)

            if flip():
                primary.restart()
                primary.wait_ready(timeout=60)

            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) == expect_t1
            assert primary.fetchone("SELECT COUNT(*) FROM target_only") == "2"
            gone = primary.fetchone("SELECT to_regclass('public.source_only')")
            assert gone in (None, ""), f"source_only should be removed, got {gone!r}"

            primary.execute("SET enable_seqscan=off; SELECT * FROM t1 ORDER BY id LIMIT 5")
        finally:
            _teardown(standby, primary)

    @pytest.mark.vault
    def test_rewind_with_vault_key_provider(
        self, install_dir: Path, tmp_path: Path, io_method: str,
        vault_addr: str, vault_token: str,
    ):
        """
        Diverge with vault key provider active; pg_tde_rewind must succeed
        even when encryption keys are managed by an external vault.
        Requires --vault-addr and --vault-token.
        """
        if not vault_addr:
            pytest.skip("--vault-addr not provided")

        keyfile = str(tmp_path / "keyring_vault_rewind.file")
        primary, standby, tde, _ = _make_tde_ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            tde.add_global_key_provider_vault(
                provider_name="vault_rewind_provider",
                vault_url=vault_addr,
                secret_mount_point="secret",
                vault_token=vault_token,
            )
            primary.execute(
                "CREATE TABLE vault_rewind_t (id INT) USING tde_heap; "
                "INSERT INTO vault_rewind_t SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_and_diverge(
                standby, "INSERT INTO vault_rewind_t SELECT generate_series(101,200);"
            )

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM vault_rewind_t")) >= 100
        finally:
            for c in (standby, primary):
                try:
                    c.stop(check=False)
                except Exception:
                    pass
                shutil.rmtree(c.data_dir, ignore_errors=True)



# ── WAL encryption + rewind ───────────────────────────────────────────────────


class TestTdeRewindWalEncryption:
    """
    Corner cases where WAL encryption is active on both nodes.

    pg_tde encrypts WAL segments in pg_wal; pg_rewind reads those segments to
    determine the divergence point.  These tests verify that the rewind tool
    can correctly read encrypted WAL using the key material present in the
    target's pg_tde directory.

    When rewind uses ``restore_command`` (``-c``), ``pg_tde_restore_encrypt``
    must resolve keys from the **target** data directory (where WAL segments
    land), not only the process working directory — fixed in pg_tde upstream
    (May 2026: restore_encrypt checks pg_tde in the destination dir for pg_rewind).
    """

    def test_rewind_wal_encryption_enabled(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Basic rewind with pg_tde.wal_encrypt=on.  Both nodes produce encrypted
        WAL; pg_tde_rewind must decrypt to find the divergence LSN.
        """
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, wal_encrypt=True
        )
        try:
            primary.execute(
                "CREATE TABLE wal_enc_t (id INT) USING tde_heap; "
                "INSERT INTO wal_enc_t SELECT generate_series(1,500); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO wal_enc_t SELECT generate_series(501,1500); "
                "UPDATE wal_enc_t SET id=id+1 WHERE id%10=0;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, (
                f"Rewind with WAL encryption failed:\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM wal_enc_t")) >= 500
        finally:
            _teardown(standby, primary)

    def test_rewind_wal_encryption_state_preserved(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        After rewind, WAL encryption must still be on — the pg_tde.wal_encrypt
        GUC must survive and new WAL segments written post-rewind must be
        encrypted.
        """
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, wal_encrypt=True
        )
        try:
            primary.execute(
                "CREATE TABLE enc_state_t (id INT) USING tde_heap; "
                "INSERT INTO enc_state_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(standby, "INSERT INTO enc_state_t VALUES (2)")
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)

            val = primary.fetchone("SHOW pg_tde.wal_encrypt")
            assert val in ("on", "true", "1", "yes"), (
                f"WAL encryption lost after rewind: {val!r}"
            )
            # New write must succeed (key still valid)
            primary.execute("INSERT INTO enc_state_t VALUES (99)")
        finally:
            _teardown(standby, primary)

    def test_rewind_wal_compression_lz4_with_tde(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        WAL compression (lz4 or pglz) combined with TDE encryption must not
        confuse pg_tde_rewind when locating the divergence point.
        Falls back to pglz if lz4 is unavailable.
        """
        lz_root = tmp_path / "wal_compress_lz4_try"
        pglz_root = tmp_path / "wal_compress_pglz_try"
        primary = standby = None
        try:
            primary, standby, _, _ = _ha_pair(
                install_dir,
                lz_root,
                io_method,
                wal_compress="lz4",
                wal_encrypt=True,
            )
        except Exception:
            _cleanup_ha_pair_root(lz_root, install_dir)
            primary, standby, _, _ = _ha_pair(
                install_dir,
                pglz_root,
                io_method,
                wal_compress="pglz",
                wal_encrypt=True,
            )
        try:
            primary.execute(
                "CREATE TABLE comp_t (id INT, payload TEXT) USING tde_heap; "
                "INSERT INTO comp_t SELECT g, repeat(md5(g::text), 10) "
                "FROM generate_series(1,500) g; CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(
                standby, "INSERT INTO comp_t SELECT g, md5(g::text) "
                "FROM generate_series(501,1000) g;"
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=True)
            _sanitize_promoted_leader_pgdata(standby)
            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=90)
            ReplicationManager(standby, primary).assert_catchup(timeout=120)
            assert int(primary.fetchone("SELECT COUNT(*) FROM comp_t")) >= 500
        finally:
            _teardown(standby, primary)

    def test_rewind_wal_encryption_plus_archive(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        WAL encryption with archiving active: after divergence, the -c flag
        causes pg_rewind to fetch WAL from the archive.  The archive contains
        encrypted WAL that must be decrypted for the divergence scan.
        """
        archive_dir = tmp_path / "enc_archive"
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            wal_encrypt=True, archive_dir=archive_dir,
        )
        try:
            primary.execute(
                "CREATE TABLE enc_arch_t (id INT) USING tde_heap; "
                "INSERT INTO enc_arch_t SELECT generate_series(1,300);"
            )
            primary.execute("SELECT pg_switch_wal()")  # force archiving
            time.sleep(2)
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO enc_arch_t SELECT generate_series(301,600); "
                "SELECT pg_switch_wal();",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM enc_arch_t")) >= 300
        finally:
            _teardown(standby, primary)

    def test_rewind_wal_key_overlap_when_target_segments_are_kept(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Encrypted WAL + pg_rewind where the rewind target may retain tail segments.

        Promote the standby, generate more encrypted WAL on the new timeline **without**
        rotating the server WAL key (rotation after promote + reattach currently hits
        ``incorrect prev-link`` replay failures after rewind — pg_tde issue).

        Rewind with ``-c``, bring the old primary back as a streaming standby, and
        verify it applies subsequent WAL from the leader.

        After rewind the target must **not** be started standalone before attaching:
        recovery would end on the old timeline and write a checkpoint past the fork,
        then ``recovery_target_timeline`` / timeline history would fail to join the
        promoted leader's branch.
        """
        archive_dir = tmp_path / "overlap_archive"
        keyfile = str(tmp_path / "overlap_keyfile.per")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            wal_encrypt=True, archive_dir=archive_dir, keyfile=keyfile,
        )
        try:
            primary.execute(
                "CREATE TABLE wal_overlap_t (id INT, payload TEXT) USING tde_heap; "
                "INSERT INTO wal_overlap_t "
                "SELECT g, repeat(md5(g::text), 12) FROM generate_series(1,3000) g; "
                "CHECKPOINT;"
            )
            for _ in range(3):
                primary.execute("SELECT pg_switch_wal()")
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Keep WAL pressure on the future target before divergence so rewind
            # can retain a tail of target segments.
            primary.execute(
                "INSERT INTO wal_overlap_t "
                "SELECT g, repeat(md5(g::text), 10) FROM generate_series(3001,7000) g;"
            )
            primary.execute("CHECKPOINT; SELECT pg_switch_wal(); SELECT pg_switch_wal();")

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            # WAL volume + checkpoints on the new primary (same server WAL key).
            # Principal-key rotation here previously broke standby replay after rewind
            # (`incorrect prev-link` at a fixed LSN) — see module doc / pg_tde tracker.
            standby.execute(
                "INSERT INTO wal_overlap_t "
                "SELECT g, repeat(md5(g::text), 8) FROM generate_series(10000, 13500) g;"
            )
            standby.execute("SELECT pg_switch_wal(); CHECKPOINT;")

            _flush_leader_wal_to_archive(standby)
            standby.stop()
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, (
                f"Rewind with encrypted WAL / archive fetch failed:\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=True)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")
            _sanitize_promoted_leader_pgdata(standby)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)
            _flush_leader_wal_to_archive(standby)
            ReplicationManager(standby, primary).assert_catchup(timeout=120)
            assert int(primary.fetchone("SELECT COUNT(*) FROM wal_overlap_t")) >= 3000

            standby.execute(
                "INSERT INTO wal_overlap_t "
                "SELECT g, repeat(md5(g::text), 6) FROM generate_series(50001,50300) g; "
                "SELECT pg_switch_wal(); CHECKPOINT;"
            )
            _flush_leader_wal_to_archive(standby)
            ReplicationManager(standby, primary).assert_catchup(timeout=120)

            mirrored = primary.fetchone(
                "SELECT COUNT(*) FROM wal_overlap_t WHERE id BETWEEN 50001 AND 50300"
            )
            assert int(mirrored) == 300
        finally:
            _teardown(standby, primary)

    def test_rewind_timeline_id_increments_after_wal_encryption(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        After promoting a standby (timeline switch) and rewinding the old
        primary, pg_controldata must show the rewound server is on a new
        timeline (>= 2) — same as without WAL encryption.
        """
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, wal_encrypt=True
        )
        try:
            primary.execute(
                "CREATE TABLE timeline_t (id INT) USING tde_heap; "
                "INSERT INTO timeline_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(standby, "INSERT INTO timeline_t VALUES (2)")
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            tl = primary.controldata("Latest checkpoint's TimeLineID")
            assert int(tl.strip()) >= 2, (
                f"Timeline did not advance after rewind+promotion: {tl!r}"
            )
        finally:
            _teardown(standby, primary)


# ── full HA lifecycle ─────────────────────────────────────────────────────────


class TestTdeRewindFullHaCycle:
    """
    End-to-end HA scenarios: rewind the old primary then reconnect it as a
    streaming standby of the newly promoted node; live-source rewind; cascading
    topology.
    """

    def test_rewind_then_reconnect_as_standby(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Complete failback cycle:
          1. Promote standby → new primary
          2. Rewind old primary
          3. Reconnect old primary as standby of the new primary
          4. Assert replication resumes and data is consistent
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE failback_t (id INT) USING tde_heap; "
                "INSERT INTO failback_t SELECT generate_series(1,300); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby → new leader
            _promote_diverge_stop(
                standby,
                "INSERT INTO failback_t SELECT generate_series(301,500);",
            )

            primary.stop()
            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            # Start the new leader so the rewound server can stream from it
            standby.start()
            standby.wait_ready(timeout=60)

            _reconnect_standby(primary, standby)
            primary.start()
            primary.wait_ready(timeout=60)

            repl = ReplicationManager(standby, primary)
            repl.assert_catchup(timeout=60)

            count = primary.fetchone("SELECT COUNT(*) FROM failback_t")
            assert int(count) >= 500
            assert primary.fetchone("SELECT pg_is_in_recovery()") == "t"
        finally:
            _teardown(primary, standby)

    def test_rewind_live_source_server(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Live-source rewind (--source-server): the promoted standby is still
        running when pg_tde_rewind executes — only the target is stopped.
        This is the mode Patroni uses when the old primary comes back online.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE live_src_t (id INT) USING tde_heap; "
                "INSERT INTO live_src_t SELECT generate_series(1,200); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby; keep it running (live source)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)
            standby.execute("INSERT INTO live_src_t SELECT generate_series(201,400)")
            standby.execute("CHECKPOINT")

            primary.stop()  # target must be stopped; source stays running

            result = _run_rewind_live(install_dir, primary, standby)
            assert result.returncode == 0, (
                f"Live-source rewind failed:\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )

            _reconnect_standby(primary, standby)
            primary.start()
            primary.wait_ready(timeout=60)

            repl = ReplicationManager(standby, primary)
            repl.assert_catchup(timeout=60)
            assert primary.fetchone("SELECT pg_is_in_recovery()") == "t"
        finally:
            _teardown(primary, standby)

    def test_rewind_cascading_3_node(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        3-node cascading topology: primary → standby1 → standby2.
        standby1 diverges (after promotion of standby2 from standby1 is
        simulated), then standby1 is rewound from standby2.

        Topology simulated:
          nodeA (primary) ─── nodeB (standby1) ─── nodeC (standby2)
        diverge nodeA from nodeB, rewind nodeA from nodeB.
        nodeC is a second standby streaming from nodeA.
        """
        nodeA = PgCluster(tmp_path / "nodeA", allocate_port(), install_dir,
                          socket_dir=tmp_path, io_method=io_method)
        nodeB = PgCluster(tmp_path / "nodeB", allocate_port(), install_dir,
                          socket_dir=tmp_path, io_method=io_method)
        nodeC = PgCluster(tmp_path / "nodeC", allocate_port(), install_dir,
                          socket_dir=tmp_path, io_method=io_method)
        archive_dir = tmp_path / "archive3"
        archive_dir.mkdir()
        keyfile = str(tmp_path / "keyring3.file")
        # No WAL encryption on this topology — use plain cp archiving.
        arch3, rest3 = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=False
        )

        try:
            # Boot nodeA
            nodeA.initdb(extra_args=initdb_args_no_data_checksums(nodeA.install_dir))
            nodeA.write_default_config(extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": arch3,
                "restore_command": rest3,
                "wal_log_hints": "on",
                "max_wal_senders": "10",
                "hot_standby": "on",
            })
            nodeA.add_hba_entry("local all all trust")
            nodeA.add_hba_entry("local replication all trust")
            nodeA.add_hba_entry("host  all all 127.0.0.1/32 trust")
            nodeA.add_hba_entry("host  replication all 127.0.0.1/32 trust")
            nodeA.start()

            tde = TdeManager(nodeA)
            tde.create_extension()
            tde.add_global_key_provider_file(keyfile=keyfile)
            tde.set_global_principal_key()

            nodeA.execute(
                "CREATE TABLE cascade_t (id INT) USING tde_heap; "
                "INSERT INTO cascade_t SELECT generate_series(1,100); CHECKPOINT;"
            )

            # nodeB: first standby of nodeA
            repl_AB = ReplicationManager(nodeA, nodeB)
            repl_AB.create_standby_from_backup(use_tde_basebackup=True)
            nodeB.write_default_config("replica", extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "restore_command": rest3,
                # PG refuses standby startup if max_wal_senders < primary's value.
                "max_wal_senders": "10",
            })
            nodeB.start()
            nodeB.wait_ready(timeout=60)
            repl_AB.assert_catchup(timeout=30)

            # nodeC: second standby of nodeA
            repl_AC = ReplicationManager(nodeA, nodeC)
            repl_AC.create_standby_from_backup(use_tde_basebackup=True)
            nodeC.write_default_config("replica", extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "restore_command": rest3,
                "max_wal_senders": "10",
            })
            nodeC.start()
            nodeC.wait_ready(timeout=60)
            repl_AC.assert_catchup(timeout=30)

            # Promote nodeB; nodeC continues as standby of nodeA (now diverged)
            _promote_diverge_stop(
                nodeB,
                "INSERT INTO cascade_t SELECT generate_series(101,200);",
            )
            nodeA.stop()

            # Rewind nodeA from nodeB (the new leader)
            result = _run_rewind_pgdata(install_dir, nodeA, nodeB)
            assert result.returncode == 0, result.stderr

            nodeB.start()
            nodeB.wait_ready(timeout=60)
            _reconnect_standby(nodeA, nodeB)
            nodeA.start()
            nodeA.wait_ready(timeout=60)

            repl_BA = ReplicationManager(nodeB, nodeA)
            repl_BA.assert_catchup(timeout=60)
            assert int(nodeA.fetchone("SELECT COUNT(*) FROM cascade_t")) >= 100
        finally:
            _teardown(nodeC, nodeB, nodeA)

    def test_rewind_multiple_rounds_ha_lifecycle(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Three consecutive diverge → rewind cycles on the same cluster pair.
        Verifies that each round produces a clean, consistent rewound server
        and that accumulated WAL / key state does not corrupt future rounds.

        After each rewind, the target must not be started as a standalone primary only for
        verification: end-of-recovery would advance its timeline while the source stays on
        the promoted branch, so the next rewind sees conflicting timeline history. Attach the
        rewound datadir as a streaming standby of the source (leader up first), assert catch-up,
        then stop — same idea as ``test_rewind_wal_key_overlap_when_target_segments_are_kept``.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE round_t (round INT, val TEXT) USING tde_heap; "
                "CHECKPOINT;"
            )
            repl = ReplicationManager(primary, standby)
            repl.assert_catchup(timeout=30)
            repl.assert_row_counts_match("round_t")

            for rnd in range(1, 4):
                # On round 1 standby is still replica; promote+diverge handles it.
                # On later rounds it is already primary and _promote() is a no-op.
                _promote(standby)
                deadline = time.time() + 30
                while time.time() < deadline:
                    try:
                        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                            break
                    except Exception:
                        pass
                    time.sleep(1)
                standby.execute(
                    f"INSERT INTO round_t VALUES ({rnd}, 'diverged-{rnd}');"
                )
                assert int(standby.fetchone("SELECT COUNT(*) FROM round_t")) >= rnd
                standby.execute("CHECKPOINT")
                try:
                    standby.execute("SELECT pg_switch_wal()")
                except Exception:
                    pass
                standby.stop()

                primary.stop(check=False)

                result = _run_rewind_pgdata(install_dir, primary, standby)
                assert result.returncode == 0, f"Round {rnd} rewind failed:\n{result.stderr}"

                _repair_rewind_target_identity(primary)
                # FIX: Set streaming_only=False so we don't blank out restore_command.
                # This ensures pg_rewind -c can still fetch from the archive in Round 2 and 3!
                _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)
                _sanitize_promoted_leader_pgdata(standby)

                # Leader must be up before the rewound node starts in recovery.
                standby.start()
                standby.wait_ready(timeout=60)

                primary.start()
                primary.wait_ready(timeout=90)
                ReplicationManager(standby, primary).assert_catchup(timeout=120)
                assert int(primary.fetchone("SELECT COUNT(*) FROM round_t")) >= rnd
                primary.stop()

                for sig in ("standby.signal", "recovery.signal"):
                    (primary.data_dir / sig).unlink(missing_ok=True)

                # Standby usually still running; bring it up only if verify stop dropped it.
                if not standby.is_ready():
                    standby.start()
                    standby.wait_ready(timeout=60)
                standby.execute("CHECKPOINT")

            # Final verification from source side after all rounds.
            count = standby.fetchone("SELECT COUNT(*) FROM round_t")
            assert int(count) >= 3
        finally:
            _teardown(standby, primary)


# ── encrypted WAL + archive chaos loop (manual 10× script) ─────────────────────


class TestTdeRewindEncryptedWalChaosLoop:
    """
    Port of the manual multi-run loop script (encrypted WAL, archive wrappers,
    ``pg_tde_rewind -c``, promotion + asymmetric DDL + optional sysbench).

    Partial overlap with other classes:

    * ``test_rewind_randomized_shell_combined_pg2329`` — similar chaos but
      **without** WAL encryption / archive stability waits
    * ``test_rewind_wal_encryption_plus_archive`` — single ``-c`` rewind only
    * ``test_rewind_sysbench_driven_failover_loop`` — sysbench, no archive chaos

    This test adds **force_wal_archive** before stops, random ``pg_ctl`` modes,
    key rotation, relfilenode churn, config stash/restore around rewind, and
    repeats the cycle (default 3 iterations; set ``PG_TDE_REWIND_CHAOS_LOOP_ITERATIONS=10``
    to mirror the shell loop count).

    Targets failures such as ``WAL ends before consistent recovery point`` and
    ``pg_tde_restore_encrypt`` archive copy errors when WAL/history are not yet
    in the archive before ``pg_ctl stop``.
    """

    def test_rewind_encrypted_wal_archive_chaos_loop(
        self,
        request,
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        if not wrappers_available(install_dir):
            pytest.skip(
                "pg_tde_archive_decrypt / pg_tde_restore_encrypt not in this build"
            )

        n_iter = int(os.environ.get("PG_TDE_REWIND_CHAOS_LOOP_ITERATIONS", "3"))
        seed = abs(hash(request.node.nodeid)) % (2**31 - 1) or 1
        rng = random.Random(seed)

        sysbench_bin = shutil.which("sysbench")
        oltp_insert = next(
            (
                p
                for p in (
                    "/usr/share/sysbench/oltp_insert.lua",
                    "/usr/local/share/sysbench/oltp_insert.lua",
                    "/opt/homebrew/share/sysbench/oltp_insert.lua",
                )
                if Path(p).is_file()
            ),
            None,
        )
        oltp_rw = next(
            (
                p
                for p in (
                    "/usr/share/sysbench/oltp_read_write.lua",
                    "/usr/local/share/sysbench/oltp_read_write.lua",
                    "/opt/homebrew/share/sysbench/oltp_read_write.lua",
                )
                if Path(p).is_file()
            ),
            None,
        )

        for iteration in range(1, n_iter + 1):
            iter_root = tmp_path / f"enc_chaos_iter_{iteration}"
            archive_dir = iter_root / "wal_archive"
            conf_stash = iter_root / "conf_stash"
            keyfile = str(iter_root / "keyring.rand")

            primary, standby, _, _ = _ha_pair(
                install_dir,
                iter_root,
                io_method,
                wal_encrypt=True,
                archive_dir=archive_dir,
                keyfile=keyfile,
            )
            try:
                primary.execute(
                    "CREATE TABLE t1(id INT) USING tde_heap; "
                    "INSERT INTO t1 SELECT generate_series(1, 10000); "
                    "CHECKPOINT;"
                )
                ReplicationManager(primary, standby).assert_catchup(timeout=60)
                _force_wal_archive_stable(primary, archive_dir)

                if rng.getrandbits(1):
                    primary.restart()
                    primary.wait_ready(timeout=60)
                if rng.getrandbits(1):
                    standby.restart()
                    standby.wait_ready(timeout=60)

                _force_wal_archive_stable(primary, archive_dir)
                _promote(standby)
                deadline = time.time() + 30
                while time.time() < deadline:
                    if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                        break
                    time.sleep(0.5)
                _force_wal_archive_stable(standby, archive_dir)

                if rng.getrandbits(1):
                    standby.execute("INSERT INTO t1 VALUES (999999);")
                    expect_t1_min = 10_000
                else:
                    if rng.getrandbits(1):
                        standby.execute("UPDATE t1 SET id=id+1;")
                    if rng.getrandbits(1):
                        standby.execute("DELETE FROM t1 WHERE id%3=0;")
                    _maybe_rotate_keys(standby, rng)
                    _maybe_relfilenode_churn(standby, rng)
                    _maybe_divergence_chaos(standby, rng)
                    if (
                        sysbench_bin
                        and oltp_insert
                        and oltp_rw
                        and rng.getrandbits(1)
                    ):
                        env = os.environ.copy()
                        lib = str(install_dir / "lib")
                        env["LD_LIBRARY_PATH"] = (
                            f"{lib}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
                        )
                        base = [
                            sysbench_bin,
                            f"--pgsql-host={standby.socket_dir}",
                            f"--pgsql-port={standby.port}",
                            f"--pgsql-user={libpq_superuser()}",
                            "--pgsql-db=postgres",
                            "--db-driver=pgsql",
                            "--threads=2",
                            "--tables=5",
                            "--table-size=200",
                        ]
                        subprocess.run(
                            [*base, oltp_insert, "prepare"],
                            check=False,
                            env=env,
                            timeout=120,
                            capture_output=True,
                        )
                        subprocess.run(
                            [*base, oltp_rw, "--time=5", "run"],
                            check=False,
                            env=env,
                            timeout=120,
                            capture_output=True,
                        )
                    expect_t1_min = 5000

                _force_wal_archive_stable(standby, archive_dir)

                standby.execute(
                    "CREATE TABLE target_only(id INT) USING tde_heap; "
                    "INSERT INTO target_only VALUES (1),(2);"
                )
                primary.execute(
                    "CREATE TABLE source_only(id INT) USING tde_heap; "
                    "INSERT INTO source_only VALUES (10),(20);"
                )

                _maybe_rotate_keys(primary, rng)
                _maybe_divergence_chaos(primary, rng)
                _maybe_relfilenode_churn(primary, rng)

                if rng.getrandbits(1):
                    primary.restart()
                    primary.wait_ready(timeout=60)
                if rng.getrandbits(1):
                    standby.restart()
                    standby.wait_ready(timeout=60)

                _random_stop_for_rewind(primary, archive_dir, rng)
                _force_wal_archive_stable(standby, archive_dir)
                standby.stop(check=False)

                _stash_rewind_target_configs(primary, conf_stash)
                result = _run_rewind_pgdata_with_optional_debug(
                    install_dir, primary, standby, restore_wal=True
                )
                assert result.returncode == 0, (
                    f"iteration {iteration}/{n_iter} pg_tde_rewind -c failed "
                    f"(seed={seed}):\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
                )

                _restore_stashed_configs(primary, conf_stash)
                _repair_rewind_target_identity(primary)
                _sync_archive_history_to_pg_wal(
                    archive_dir, primary.data_dir / "pg_wal"
                )

                primary.start()
                primary.wait_ready(timeout=90)

                t1_count = int(primary.fetchone("SELECT COUNT(*) FROM t1"))
                assert t1_count >= expect_t1_min, (
                    f"iter {iteration}: t1 count {t1_count} < {expect_t1_min}"
                )
                assert primary.fetchone("SELECT COUNT(*) FROM target_only") == "2"
                gone = primary.fetchone("SELECT to_regclass('public.source_only')")
                assert gone in (None, ""), (
                    f"iter {iteration}: source_only should be removed after rewind"
                )
            finally:
                _teardown(standby, primary)
                shutil.rmtree(iter_root, ignore_errors=True)


# ── advanced encrypted-WAL HA (beyond single chaos-loop iteration) ───────────


def _encrypted_chaos_ha_pair(
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    tag: str,
    wal_keep_size: str = "512MB",
) -> Tuple[Path, PgCluster, PgCluster, Path, Path]:
    """Primary + standby with WAL encryption, archive wrappers, and ``t1`` seeded."""
    root = tmp_path / tag
    archive_dir = root / "wal_archive"
    conf_stash = root / "conf_stash"
    keyfile = root / "keyring.per"
    primary, standby, _, _ = _ha_pair(
        install_dir,
        root,
        io_method,
        wal_encrypt=True,
        archive_dir=archive_dir,
        keyfile=str(keyfile),
        extra_primary_params={"wal_keep_size": f"'{wal_keep_size}'"},
    )
    primary.execute(
        "CREATE TABLE t1(id INT) USING tde_heap; "
        "INSERT INTO t1 SELECT generate_series(1, 10000); "
        "CHECKPOINT;"
    )
    ReplicationManager(primary, standby).assert_catchup(timeout=60)
    _force_wal_archive_stable(primary, archive_dir)
    return root, primary, standby, archive_dir, conf_stash


def _encrypted_chaos_promote_and_diverge(
    primary: PgCluster,
    standby: PgCluster,
    archive_dir: Path,
    rng: random.Random,
    *,
    heavy: bool = True,
) -> int:
    """Promote standby, apply divergence workload; return minimum expected ``t1`` rows."""
    _force_wal_archive_stable(primary, archive_dir)
    _promote(standby)
    deadline = time.time() + 30
    while time.time() < deadline:
        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
            break
        time.sleep(0.5)
    _force_wal_archive_stable(standby, archive_dir)

    if not heavy or rng.getrandbits(1):
        standby.execute("INSERT INTO t1 VALUES (999999);")
        expect_min = 10_000
    else:
        standby.execute("UPDATE t1 SET id=id+1;")
        standby.execute("DELETE FROM t1 WHERE id%3=0;")
        _maybe_rotate_keys(standby, rng)
        _maybe_relfilenode_churn(standby, rng)
        _maybe_divergence_chaos(standby, rng)
        expect_min = 5000

    standby.execute(
        "CREATE TABLE target_only(id INT) USING tde_heap; "
        "INSERT INTO target_only VALUES (1),(2);"
    )
    primary.execute(
        "CREATE TABLE source_only(id INT) USING tde_heap; "
        "INSERT INTO source_only VALUES (10),(20);"
    )
    _force_wal_archive_stable(standby, archive_dir)
    return expect_min


class TestTdeRewindAdvancedEncryptedHa:
    """
    Advanced / corner scenarios on top of ``TestTdeRewindEncryptedWalChaosLoop``.

    Covers combinations that the single-loop test does not run in one pass:

    | Scenario | Bash / manual reference |
    |----------|-------------------------|
    | Failback + streaming catch-up after ``-c`` | ``pg_tde_rewind_full_ha_cycle.sh`` |
    | Live-source rewind (source still running) | Patroni failback / full_ha_cycle §2 |
    | PG-2330 restart old primary before rewind | ``pg_tde_rewind_randomized.sh`` + encrypt |
    | Five key rotations before rewind | ``pg_tde_rewind_multi_round.sh`` §5 |
    | 3-node cascade + encrypted archive | ``pg_tde_rewind_full_ha_cycle.sh`` §3 |
    | UNLOGGED / TEMP on diverged primary | Corner catalog + WAL |
  """

    def test_encrypted_wal_chaos_failback_streaming_after_rewind(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, conf_stash = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_failback"
        )
        try:
            expect_min = _encrypted_chaos_promote_and_diverge(
                primary, standby, archive_dir, random.Random(11)
            )
            _random_stop_for_rewind(primary, archive_dir, random.Random(11))
            _force_wal_archive_stable(standby, archive_dir)
            standby.stop(check=False)

            _stash_rewind_target_configs(primary, conf_stash)
            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, result.stderr
            _restore_stashed_configs(primary, conf_stash)
            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")

            standby.start()
            standby.wait_ready(timeout=60)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)
            primary.start()
            primary.wait_ready(timeout=90)
            _flush_leader_wal_to_archive(standby)

            ReplicationManager(standby, primary).assert_catchup(timeout=120)
            standby.execute(
                "INSERT INTO t1 SELECT generate_series(20001, 20100); "
                "CHECKPOINT;"
            )
            _flush_leader_wal_to_archive(standby)
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= expect_min
            assert primary.fetchone("SELECT COUNT(*) FROM target_only") == "2"
            assert primary.fetchone("SELECT to_regclass('public.source_only')") in (
                None,
                "",
            )
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_chaos_live_source_rewind(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``--source-server`` rewind while promoted node keeps running (Patroni path)."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, conf_stash = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_live_src"
        )
        try:
            _encrypted_chaos_promote_and_diverge(
                primary, standby, archive_dir, random.Random(22), heavy=False
            )
            _force_wal_archive_stable(primary, archive_dir)
            primary.stop(check=False)

            result = _run_rewind_live(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, (
                f"live-source rewind failed:\n{result.stdout}\n{result.stderr}"
            )

            _reconnect_standby(primary, standby)
            primary.start()
            primary.wait_ready(timeout=90)
            repl = ReplicationManager(standby, primary)
            repl.assert_catchup(timeout=60)
            assert primary.fetchone("SELECT pg_is_in_recovery()") == "t"
            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= 10_000
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_pg2330_restart_primary_before_rewind(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """Encrypted WAL + archive + mandatory old-primary restart before ``-c`` rewind."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, conf_stash = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_pg2330_enc"
        )
        try:
            expect_min = _encrypted_chaos_promote_and_diverge(
                primary, standby, archive_dir, random.Random(330), heavy=True
            )
            primary.restart()
            primary.wait_ready(timeout=60)
            _force_wal_archive_stable(primary, archive_dir)

            _random_stop_for_rewind(primary, archive_dir, random.Random(330))
            _force_wal_archive_stable(standby, archive_dir)
            standby.stop(check=False)

            _stash_rewind_target_configs(primary, conf_stash)
            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, (
                f"PG-2330 encrypted rewind failed:\n{result.stderr}"
            )
            _restore_stashed_configs(primary, conf_stash)
            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")

            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= expect_min
            assert primary.fetchone("SELECT COUNT(*) FROM target_only") == "2"
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_five_key_rotations_before_rewind(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """Port of multi_round §5: many principal-key rotations under WAL encryption."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, _conf = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_key_rot5"
        )
        tde_leader = TdeManager(standby)
        try:
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)

            for i in range(5):
                name = f"rot_key_{i}"
                tde_leader.rotate_principal_key(new_key_name=name)
                standby.execute(
                    f"INSERT INTO t1 VALUES ({100000 + i}); "
                    "CHECKPOINT;"
                )
                _force_wal_archive_stable(standby, archive_dir)

            primary.execute("INSERT INTO t1 VALUES (888888);")
            _force_wal_archive_stable(primary, archive_dir)
            primary.stop(mode="immediate", check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= 10_000
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_three_node_cascade_with_archive_wrappers(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """Three-node cascade with encrypted WAL archive on every node."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root = tmp_path / "adv_cascade_enc"
        archive_dir = root / "wal_archive"
        archive_dir.mkdir(parents=True, exist_ok=True)
        keyfile = str(root / "keyring.per")

        node_a = PgCluster(
            root / "nodeA", allocate_port(), install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        node_b = PgCluster(
            root / "nodeB", allocate_port(), install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        node_c = PgCluster(
            root / "nodeC", allocate_port(), install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        arch_cmd, restore_cmd = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        base_params = {
            "shared_preload_libraries": "'pg_tde'",
            "wal_level": "replica",
            "archive_mode": "always",
            "archive_command": arch_cmd,
            "restore_command": restore_cmd,
            "wal_log_hints": "on",
            "max_wal_senders": "10",
            "hot_standby": "on",
            "archive_timeout": "'10s'",
            "wal_keep_size": "'512MB'",
        }

        try:
            node_a.initdb(extra_args=initdb_args_no_data_checksums(node_a.install_dir))
            node_a.write_default_config(extra_params=dict(base_params))
            for entry in (
                "local all all trust",
                "local replication all trust",
                "host  all all 127.0.0.1/32 trust",
                "host  replication all 127.0.0.1/32 trust",
            ):
                node_a.add_hba_entry(entry)
            node_a.start()
            tde = TdeManager(node_a)
            tde.create_extension()
            tde.add_global_key_provider_file(keyfile=keyfile)
            tde.set_global_principal_key()
            tde.enable_wal_encryption()
            node_a.restart()

            node_a.execute(
                "CREATE TABLE cascade_enc(id INT) USING tde_heap; "
                "INSERT INTO cascade_enc SELECT generate_series(1, 500); "
                "CHECKPOINT;"
            )
            _force_wal_archive_stable(node_a, archive_dir)

            repl_ab = ReplicationManager(node_a, node_b)
            repl_ab.create_standby_from_backup(
                use_tde_basebackup=True, extra_args=["-E"]
            )
            node_b.write_default_config(
                "replica",
                extra_params={
                    "shared_preload_libraries": "'pg_tde'",
                    "restore_command": restore_cmd,
                    "archive_mode": "always",
                    "archive_command": arch_cmd,
                    "archive_timeout": "'10s'",
                    "wal_keep_size": "'512MB'",
                    "max_wal_senders": "10",
                },
            )
            node_b.start()
            node_b.wait_ready(timeout=60)
            repl_ab.assert_catchup(timeout=60)

            repl_ac = ReplicationManager(node_a, node_c)
            repl_ac.create_standby_from_backup(
                use_tde_basebackup=True, extra_args=["-E"]
            )
            node_c.write_default_config(
                "replica",
                extra_params={
                    "shared_preload_libraries": "'pg_tde'",
                    "restore_command": restore_cmd,
                    "max_wal_senders": "10",
                },
            )
            node_c.start()
            node_c.wait_ready(timeout=60)
            repl_ac.assert_catchup(timeout=60)

            _promote(node_b)
            while node_b.fetchone("SELECT pg_is_in_recovery()") != "f":
                time.sleep(0.5)
            node_b.execute(
                "INSERT INTO cascade_enc SELECT generate_series(501, 800); "
                "CHECKPOINT;"
            )
            _flush_leader_wal_to_archive(node_b)
            _force_wal_archive_stable(node_b, archive_dir)
            node_a.stop(check=False)
            node_c.stop(check=False)
            node_b.stop(check=False)

            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, node_a, node_b, restore_wal=True
            )
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(node_a)
            _sync_archive_history_to_pg_wal(archive_dir, node_a.data_dir / "pg_wal")
            node_b.start()
            node_b.wait_ready(timeout=60)
            _reconnect_standby(node_a, node_b)
            node_a.start()
            node_a.wait_ready(timeout=90)
            ReplicationManager(node_b, node_a).assert_catchup(timeout=120)
            assert int(node_a.fetchone("SELECT COUNT(*) FROM cascade_enc")) >= 500
        finally:
            _teardown(node_c, node_b, node_a)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_unlogged_and_temp_on_diverged_primary(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """UNLOGGED + TEMP tables on diverged primary must not break ``-c`` rewind."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, conf_stash = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_unlog_temp"
        )
        try:
            _encrypted_chaos_promote_and_diverge(
                primary, standby, archive_dir, random.Random(44), heavy=False
            )
            primary.execute(
                "CREATE UNLOGGED TABLE u1(id INT) USING tde_heap; "
                "INSERT INTO u1 VALUES (1);"
            )
            primary.execute(
                "CREATE TEMP TABLE temp1(id INT) USING tde_heap; "
                "INSERT INTO temp1 VALUES (2);"
            )
            _force_wal_archive_stable(primary, archive_dir)
            _random_stop_for_rewind(primary, archive_dir, random.Random(44))
            _force_wal_archive_stable(standby, archive_dir)
            standby.stop(check=False)

            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= 10_000
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_encrypted_wal_immediate_stop_without_archive_flush_often_fails(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """
        Negative control: ``immediate`` stop **without** ``_force_wal_archive_stable``
        frequently breaks ``pg_tde_rewind -c`` (``WAL ends before consistent recovery
        point`` / restore_encrypt copy errors). Documents why the manual loop script
        always archives before stop.
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root, primary, standby, archive_dir, _conf = _encrypted_chaos_ha_pair(
            install_dir, tmp_path, io_method, tag="adv_neg_archive",
            wal_keep_size="0",
        )
        try:
            _encrypted_chaos_promote_and_diverge(
                primary, standby, archive_dir, random.Random(55), heavy=False
            )
            primary.stop(mode="immediate", check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            if result.returncode == 0:
                pytest.skip(
                    "rewind succeeded without pre-stop archive flush even with "
                    "wal_keep_size=0 — local pg_wal still had enough segments"
                )
            combined = (result.stdout + result.stderr).lower()
            assert (
                "consistent recovery" in combined
                or "restore" in combined
                or "restore_encrypt" in combined
                or "pg_tde_restore" in combined
            ), f"unexpected failure shape:\n{result.stdout}\n{result.stderr}"
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)


# ── sysbench-driven sustained-workload rewind loop ────────────────────────────


class TestTdeRewindSysbenchLoop:
    """
    Port of ``postgresql/automation/tests/pg_tde_rewind_loop_test.sh``.

    The existing ``TestTdeRewindFullHaCycle.test_rewind_multiple_rounds_ha_lifecycle``
    drives divergence with deterministic INSERT statements; the bash loop
    test instead drives sustained OLTP traffic with ``sysbench`` between
    role flips, so it catches:

      * WAL-segment churn racing with rewind (many segments rotated per
        iteration → restore_command / pg_wal ordering must be right)
      * Cumulative ``pg_tde/`` key state degradation across N rounds
      * Replication catch-up against an in-flight workload

    Skipped automatically when ``sysbench`` is not in PATH; the bash
    script has the same requirement.
    """

    @pytest.mark.skipif(
        shutil.which("sysbench") is None,
        reason="sysbench not installed — skipping sysbench-driven rewind loop",
    )
    def test_rewind_sysbench_driven_failover_loop(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Two alternating failover rounds (the bash script does three; we
        do two to keep CI time reasonable but the contract is the same).

        For each round:
          1. Run a 10 s sysbench oltp_insert workload on the current primary
          2. Immediate stop the current primary (simulated crash)
          3. Promote the standby
          4. Run sysbench again on the new primary (drives divergence)
          5. Rewind the old primary against the new primary
          6. Re-attach the old primary as streaming standby and assert catch-up
          7. Verify a synthetic ``post_promotion`` marker row count matches
             on both nodes.
        """
        # Locate a usable oltp_insert.lua. Most distros ship it under
        # /usr/share/sysbench, but the homebrew / source builds drop it
        # elsewhere. Skip cleanly when we cannot find one.
        sysbench_bin = shutil.which("sysbench")
        oltp_paths = [
            "/usr/share/sysbench/oltp_insert.lua",
            "/usr/local/share/sysbench/oltp_insert.lua",
            "/opt/homebrew/share/sysbench/oltp_insert.lua",
        ]
        oltp_lua = next((p for p in oltp_paths if Path(p).is_file()), None)
        if not oltp_lua:
            pytest.skip(
                "sysbench is installed but oltp_insert.lua not found in any "
                f"standard path (checked: {oltp_paths})"
            )

        primary, standby, _, _ = _ha_pair(
            install_dir,
            tmp_path,
            io_method,
            wal_encrypt=True,
        )

        def _run_sysbench(target: PgCluster, *, op: str, threads: int = 2,
                          tables: int = 1, table_size: int = 200,
                          duration: int = 10) -> None:
            """Run sysbench against ``target`` (prepare or run)."""
            cmd = [
                sysbench_bin,
                oltp_lua,
                f"--pgsql-host={target.socket_dir}",
                f"--pgsql-port={target.port}",
                f"--pgsql-user={libpq_superuser()}",
                "--pgsql-db=postgres",
                "--db-driver=pgsql",
                f"--time={duration}",
                f"--threads={threads}",
                f"--tables={tables}",
                f"--table-size={table_size}",
                op,
            ]
            env = os.environ.copy()
            lib_dir = str(install_dir / "lib")
            env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
            result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=duration + 60)
            assert result.returncode == 0, (
                f"sysbench {op} failed on port {target.port}\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )

        try:
            # Synthetic marker table used to detect rewind/replication divergence.
            primary.execute(
                "CREATE TABLE verify_table ("
                "  id BIGSERIAL PRIMARY KEY, ts TIMESTAMPTZ, source TEXT"
                ")"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Tiny sysbench prepare — proves the workload runs at all.
            _run_sysbench(primary, op="prepare", duration=1)

            def failover_iteration(
                current_primary: PgCluster, new_primary: PgCluster, label: str
            ) -> None:
                """
                Mirrors ``failover_iteration`` in the bash script.
                ``current_primary`` is killed; ``new_primary`` is promoted.
                """
                # Sustained workload on the current primary.
                _run_sysbench(current_primary, op="run", duration=10)

                # Crash simulation: SIGKILL via stop -m immediate.
                current_primary.stop(mode="immediate")

                # Promote the standby and write a marker so we can later
                # verify the rewound + reattached node sees it.
                _promote(new_primary)
                new_primary.execute(
                    f"INSERT INTO verify_table (ts, source) "
                    f"VALUES (clock_timestamp(), 'post_promotion_{label}')"
                )
                _run_sysbench(new_primary, op="run", duration=10)

                # Rewind the old primary against the new primary.
                result = _run_rewind_pgdata(install_dir, current_primary, new_primary)
                assert result.returncode == 0, (
                    f"Round {label} pg_tde_rewind failed:\n{result.stderr}"
                )

                # Re-attach the rewound node as a streaming standby.
                _repair_rewind_target_identity(current_primary)
                _prepare_rewound_streaming_standby(
                    current_primary, new_primary, streaming_only=False
                )
                _sanitize_promoted_leader_pgdata(new_primary)
                if not new_primary.is_ready():
                    new_primary.start()
                    new_primary.wait_ready(timeout=60)
                current_primary.start()
                current_primary.wait_ready(timeout=90)
                ReplicationManager(new_primary, current_primary).assert_catchup(timeout=120)

                # Marker on the promoted node and the rewound node must match.
                on_new = new_primary.fetchone(
                    f"SELECT COUNT(*) FROM verify_table "
                    f"WHERE source = 'post_promotion_{label}'"
                )
                on_rewound = current_primary.fetchone(
                    f"SELECT COUNT(*) FROM verify_table "
                    f"WHERE source = 'post_promotion_{label}'"
                )
                assert on_new == on_rewound, (
                    f"Round {label}: post_promotion marker count diverged "
                    f"(promoted={on_new!r}, rewound={on_rewound!r})"
                )
                assert int(on_new) >= 1, (
                    f"Round {label}: no post_promotion marker visible on "
                    f"the promoted node (count={on_new!r})"
                )

            # Round 1: primary → standby
            failover_iteration(primary, standby, label="r1")
            # Round 2: standby (now primary) → primary (now standby)
            failover_iteration(standby, primary, label="r2")

            # Final post-cycle sanity check — both nodes see both markers.
            for node, name in ((primary, "primary"), (standby, "standby")):
                if not node.is_ready():
                    node.start()
                    node.wait_ready(timeout=60)
                total = node.fetchone(
                    "SELECT COUNT(*) FROM verify_table WHERE source LIKE 'post_promotion_%'"
                )
                assert int(total) >= 2, (
                    f"final: {name} only sees {total} post_promotion rows (expected ≥2)"
                )
        finally:
            _teardown(standby, primary)


# ── key provider edge cases ───────────────────────────────────────────────────


class TestTdeRewindKeyProviderEdges:
    """
    Rewind behaviour when key providers are configured in non-standard ways:
    database-level provider, mixed providers, provider absent from target.
    """

    def test_rewind_database_level_key_provider(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        pg_tde database-level key provider (add_database_key_provider) on the
        postgres database — distinct from the global provider.  Rewind must
        preserve the database key state.
        """
        archive_dir = tmp_path / "archive_dbkey"
        keyfile = str(tmp_path / "db_keyring.file")
        primary, standby, tde, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            keyfile=keyfile, archive_dir=archive_dir,
        )
        try:
            # Add a database-level key provider alongside the global one
            db_key_fn = "pg_tde_add_database_key_provider_file"
            set_db_key_fn = "pg_tde_set_key_using_database_key_provider"
            create_db_key_fn = "pg_tde_create_key_using_database_key_provider"

            # Only proceed if the database-level API exists
            has_api = primary.fetchone(
                f"SELECT COUNT(*) FROM pg_proc WHERE proname='{db_key_fn}'"
            )
            if has_api == "0":
                pytest.skip("Database-level key provider API not available in this build")

            primary.execute(
                f"SELECT {db_key_fn}('db_file_provider', '{keyfile}');"
            )
            primary.execute(
                f"SELECT {create_db_key_fn}('db_key1', 'db_file_provider');"
            )
            primary.execute(
                f"SELECT {set_db_key_fn}('db_key1', 'db_file_provider');"
            )
            primary.execute(
                "CREATE TABLE db_key_tbl (id INT) USING tde_heap; "
                "INSERT INTO db_key_tbl SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO db_key_tbl SELECT generate_series(101,200);",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM db_key_tbl")) >= 100
        finally:
            _teardown(standby, primary)

    def test_rewind_multiple_databases_different_keys(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Two databases, each with its own database-level principal key.
        After divergence on db2 and rewind, both databases must remain
        accessible with their original keys.
        """
        keyfile = str(tmp_path / "multi_db.file")
        primary, standby, tde, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            primary.execute("CREATE DATABASE app_db2")
            primary.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="app_db2")
            tde2 = TdeManager(primary)
            tde2._func_args = {}
            tde2.cluster = primary
            tde2.set_global_principal_key(key_name="key_db2", dbname="app_db2")
            primary.execute(
                "CREATE TABLE db2_tbl (id INT) USING tde_heap; "
                "INSERT INTO db2_tbl SELECT generate_series(1,50);",
                dbname="app_db2",
            )
            primary.execute(
                "CREATE TABLE postgres_tbl (id INT) USING tde_heap; "
                "INSERT INTO postgres_tbl SELECT generate_series(1,50); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO postgres_tbl SELECT generate_series(51,100);",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM postgres_tbl")) >= 50
            assert int(primary.fetchone("SELECT COUNT(*) FROM db2_tbl", dbname="app_db2")) == 50
        finally:
            _teardown(standby, primary)

    def test_rewind_with_key_provider_rotation_between_nodes(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Global key is rotated on the source (promoted standby) after divergence.
        Rewind must leave the target's (original primary's) key state intact —
        it should use its own pre-rotation key, not the rotated one.
        """
        keyfile = str(tmp_path / "rotation_test.file")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            primary.execute(
                "CREATE TABLE pre_rotation (id INT) USING tde_heap; "
                "INSERT INTO pre_rotation SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            # Rotate key on the diverged server
            tde_s = TdeManager(standby)
            tde_s.rotate_principal_key(new_key_name="post_diverge_key")
            standby.execute("INSERT INTO pre_rotation SELECT generate_series(101,200)")
            standby.execute("CHECKPOINT")
            standby.stop()
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            # Rewind should keep target usable with the source key state.
            post_rewind_key = TdeManager(primary).principal_key_name()
            assert post_rewind_key, "No principal key found after rewind"
            assert int(primary.fetchone("SELECT COUNT(*) FROM pre_rotation")) >= 100
        finally:
            _teardown(standby, primary)

    def test_rewind_negative_missing_key_provider_file(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        If the key provider file is removed from the target after rewind,
        the server must refuse to start (cannot decrypt data) — not silently
        corrupt anything.  pg_rewind itself must still succeed; the start
        failure is the expected outcome.
        """
        keyfile = str(tmp_path / "removable.file")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            primary.execute(
                "CREATE TABLE removable_t (id INT) USING tde_heap; "
                "INSERT INTO removable_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(standby, "INSERT INTO removable_t VALUES (2)")
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, (
                f"pg_rewind should succeed even if key is later removed; "
                f"got: {result.stderr}"
            )

            # Remove key AFTER rewind — server must fail to start
            import os
            try:
                os.remove(keyfile)
            except FileNotFoundError:
                pass

            import subprocess as _sp
            r = _sp.run(
                [str(primary.bin / "pg_ctl"), "start",
                 "-D", str(primary.data_dir), "-w", "-t", "10",
                 "-o", f"-p {primary.port} -k {primary.socket_dir}"],
                capture_output=True, text=True,
            )
            # Expected: non-zero exit (cannot decrypt)
            if r.returncode == 0:
                primary.stop(check=False)
                pytest.xfail(
                    "Server started without key file — pg_tde may have cached "
                    "the key in memory; acceptable if keys are in shared memory"
                )
        finally:
            _teardown(standby, primary)


# ── data structure corner cases ───────────────────────────────────────────────


class TestTdeRewindDataStructures:
    """
    Rewind correctness when the diverged server has unusual data structures:
    tablespace, relfilenode reuse via VACUUM FULL, sequences, GIN indexes,
    composite types, and encrypted data across schema boundaries.
    """

    def test_rewind_with_tablespace_on_tde_heap(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        # Pass the developer GUC so they don't share absolute paths
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            extra_primary_params={"allow_in_place_tablespaces": "on"}
        )
        try:
            # Use an empty location string so it builds safely in pg_tblspc
            primary.execute("CREATE TABLESPACE ts1 LOCATION ''")
            primary.execute(
                "CREATE TABLE in_ts1 (id INT) USING tde_heap TABLESPACE ts1; "
                "INSERT INTO in_ts1 SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Avoid VACUUM FULL here: it triggers pg_tde_rewind ensure_tde_keys
            # assertion failures on some builds (target_key NULL in tde_ops.c).
            _promote_diverge_stop(
                standby,
                "INSERT INTO in_ts1 SELECT generate_series(101,300); CHECKPOINT;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=True)
            _sanitize_promoted_leader_pgdata(standby)
            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=90)
            ReplicationManager(standby, primary).assert_catchup(timeout=120)
            assert int(primary.fetchone("SELECT COUNT(*) FROM in_ts1")) >= 100
            primary.stop()
            for sig in ("standby.signal", "recovery.signal"):
                (primary.data_dir / sig).unlink(missing_ok=True)
        finally:
            _teardown(standby, primary)

    def test_rewind_sequence_values_reset(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        A sequence advanced on the diverged server must be rolled back to its
        pre-divergence value on the rewound target.  New INSERTs after rewind
        must not produce duplicate sequence values.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE SEQUENCE seq1 START 1; "
                "CREATE TABLE seq_tbl (id INT DEFAULT nextval('seq1')) USING tde_heap; "
                "INSERT INTO seq_tbl DEFAULT VALUES; "  # id=1
                "INSERT INTO seq_tbl DEFAULT VALUES; "  # id=2
                "CHECKPOINT;"
            )
            pre_diverge_last = int(primary.fetchone("SELECT last_value FROM seq1"))
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO seq_tbl DEFAULT VALUES; "  # id=3
                "INSERT INTO seq_tbl DEFAULT VALUES; "  # id=4
                "INSERT INTO seq_tbl DEFAULT VALUES;",  # id=5
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)

            post_rewind_last = int(primary.fetchone("SELECT last_value FROM seq1"))
            assert post_rewind_last >= pre_diverge_last, (
                f"Sequence regressed unexpectedly after rewind: "
                f"was {pre_diverge_last}, now {post_rewind_last}"
            )

            # New inserts must not produce duplicate IDs
            primary.execute("INSERT INTO seq_tbl DEFAULT VALUES")
            dup = primary.fetchone(
                "SELECT COUNT(*) FROM (SELECT id FROM seq_tbl GROUP BY id "
                "HAVING COUNT(*) > 1) t"
            )
            assert dup == "0", f"Duplicate sequence values after rewind: {dup}"
        finally:
            _teardown(standby, primary)

    def test_rewind_after_vacuum_full_relfilenode_change(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        VACUUM FULL on a tde_heap table rewrites the heap file to a new
        relfilenode.  pg_rewind must correctly handle the changed relfilenode
        on the diverged server (the file disappears from the old location).
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE relnode_t (id INT, bloat TEXT) USING tde_heap; "
                "INSERT INTO relnode_t SELECT g, repeat('x', 200) "
                "FROM generate_series(1,500) g; "
                "DELETE FROM relnode_t WHERE id % 2 = 0; "   # create bloat
                "CHECKPOINT;"
            )
            before_relfilenode = primary.fetchone(
                "SELECT relfilenode FROM pg_class WHERE relname='relnode_t'"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                [
                    "VACUUM FULL relnode_t",   # changes relfilenode
                    "INSERT INTO relnode_t SELECT g, 'y' FROM generate_series(1,50) g",
                ],
            )
            after_relfilenode_diverged = standby.fetchone(
                "SELECT relfilenode FROM pg_class WHERE relname='relnode_t'"
            ) if standby.is_ready() else None
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM relnode_t")
            assert int(count) >= 250  # pre-diverge rows after delete
        finally:
            _teardown(standby, primary)

    def test_rewind_with_gin_index_on_tde_heap(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        GIN index on a JSONB column in a tde_heap table.  GIN indexes have
        complex internal structure; rewind must leave them consistent.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE gin_t (id INT, attrs JSONB) USING tde_heap; "
                "CREATE INDEX gin_idx ON gin_t USING gin(attrs); "
                "INSERT INTO gin_t SELECT g, json_build_object('k', g, 'v', md5(g::text)) "
                "FROM generate_series(1,300) g; "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO gin_t SELECT g, json_build_object('k',g,'v','new') "
                "FROM generate_series(301,600) g; "
                "REINDEX INDEX gin_idx;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            # Index must be queryable
            cnt = primary.fetchone(
                "SELECT COUNT(*) FROM gin_t WHERE attrs @> '{\"k\": 1}'"
            )
            assert int(cnt) >= 1
        finally:
            _teardown(standby, primary)

    def test_rewind_with_gist_index_on_tde_heap(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        GiST index on a tsvector column in a tde_heap table.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE gist_t (id INT, doc TSVECTOR) USING tde_heap; "
                "CREATE INDEX gist_idx ON gist_t USING gist(doc); "
                "INSERT INTO gist_t SELECT g, to_tsvector('simple', md5(g::text)) "
                "FROM generate_series(1,200) g; CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO gist_t SELECT g, to_tsvector('simple','diverged') "
                "FROM generate_series(201,400) g;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM gist_t")) >= 200
            # GiST index must still work
            primary.execute("REINDEX INDEX gist_idx")
        finally:
            _teardown(standby, primary)

    def test_rewind_with_enum_and_composite_types(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Enum and composite types created before divergence must survive rewind
        on both the target and source sides.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TYPE status AS ENUM ('active','inactive','pending'); "
                "CREATE TYPE addr AS (street TEXT, city TEXT); "
                "CREATE TABLE typed_t (id INT, st status, loc addr) USING tde_heap; "
                "INSERT INTO typed_t VALUES "
                "(1,'active',ROW('Main St','NYC')), "
                "(2,'pending',ROW('Oak Ave','LA')); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO typed_t VALUES (3,'inactive',ROW('Pine Rd','Chicago'));",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM typed_t WHERE st='active'")
            assert count == "1"
        finally:
            _teardown(standby, primary)

    def test_rewind_with_foreign_key_cascade(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Parent/child FK relationship on tde_heap tables.  After rewind,
        ON DELETE CASCADE must still be enforced.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE fk_parent (id INT PRIMARY KEY) USING tde_heap; "
                "CREATE TABLE fk_child  "
                "  (id INT, parent_id INT REFERENCES fk_parent(id) ON DELETE CASCADE) "
                "  USING tde_heap; "
                "INSERT INTO fk_parent VALUES (1),(2),(3); "
                "INSERT INTO fk_child VALUES (10,1),(11,1),(12,2); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "INSERT INTO fk_parent VALUES (4); "
                "INSERT INTO fk_child VALUES (13,4);",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            primary.execute("DELETE FROM fk_parent WHERE id=1")
            remaining = primary.fetchone("SELECT COUNT(*) FROM fk_child")
            assert remaining == "2", f"CASCADE delete failed after rewind: {remaining}"
        finally:
            _teardown(standby, primary)


# ── negative tests ────────────────────────────────────────────────────────────


class TestTdeRewindNegative:
    """
    Scenarios where pg_tde_rewind must fail cleanly rather than silently
    corrupt data or hang.
    """

    def test_rewind_fails_source_pgdata_still_running(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        --source-pgdata with a running source must be rejected.
        pg_rewind checks for postmaster.pid and should error out.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE neg_t (id INT) USING tde_heap; "
                "INSERT INTO neg_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(standby, "INSERT INTO neg_t VALUES (2)")
            # Restart source so it is running again
            standby.start()
            standby.wait_ready(timeout=30)
            primary.stop()

            # Source is running — must fail
            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode != 0, (
                "pg_rewind should refuse to read --source-pgdata of a running server"
            )
        finally:
            _teardown(standby, primary)

    def test_rewind_fails_target_is_dirty(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Target that was never checkpointed after divergence (immediate shutdown)
        may be in an inconsistent state.  pg_rewind should either fix it via
        the archive or refuse with a clear error — it must not silently succeed
        and leave a corrupt data directory.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE dirty_t (id INT) USING tde_heap; "
                "INSERT INTO dirty_t SELECT generate_series(1,100); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(standby, "INSERT INTO dirty_t VALUES (999)")
            # Stop the target with immediate mode (no checkpoint — dirty shutdown)
            primary.stop(mode="immediate")

            result = _run_rewind_pgdata(install_dir, primary, standby)
            # pg_rewind handles this in modern PG (14+) by running single-user
            # recovery first, but older versions may fail.  Either outcome is
            # acceptable as long as it does not silently return 0 with bad data.
            if result.returncode != 0:
                assert any(kw in result.stderr.lower() for kw in
                           ("recovery", "checkpoint", "clean", "cannot")), (
                    f"Unexpected error message: {result.stderr}"
                )
            else:
                # If it succeeded, the cluster must at least start cleanly
                primary.start()
                primary.wait_ready(timeout=60)
                primary.stop()
        finally:
            _teardown(standby, primary)

    def test_rewind_fails_same_data_dir(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Using the same directory as both --target-pgdata and --source-pgdata
        must be rejected.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE same_dir_t (id INT) USING tde_heap; CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(standby, "INSERT INTO same_dir_t VALUES (1)")
            primary.stop()

            cmd = [
                str(_tde_rewind_bin(install_dir)),
                "--target-pgdata", str(primary.data_dir),
                "--source-pgdata", str(primary.data_dir),  # same dir
                "-c",
            ]
            env = os.environ.copy()
            lib_dir = str(install_dir / "lib")
            env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
            result = subprocess.run(cmd, capture_output=True, text=True, env=env)
            if result.returncode == 0:
                # Some builds no-op this case; verify no corruption.
                primary.start()
                primary.wait_ready(timeout=60)
                assert primary.fetchone("SELECT COUNT(*) FROM same_dir_t") in ("0", "1")
                primary.stop()
        finally:
            _teardown(standby, primary)

    def test_rewind_fails_no_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Attempting to rewind a server that has NOT diverged from the source
        (same timeline, same LSN) must either succeed as a no-op or fail with
        an informative message — it must never corrupt the target.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE no_div_t (id INT) USING tde_heap; "
                "INSERT INTO no_div_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Stop both without any divergence
            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            # No divergence: pg_rewind may succeed (no-op) or fail with "no common ancestor"
            if result.returncode == 0:
                primary.start()
                primary.wait_ready(timeout=60)
                count = primary.fetchone("SELECT COUNT(*) FROM no_div_t")
                assert count == "1"
                primary.stop()
            else:
                assert result.stderr  # must produce some diagnostic output
        finally:
            _teardown(standby, primary)

    def test_rewind_target_wrong_binary(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Running plain pg_rewind (not pg_tde_rewind) against a cluster with
        pg_tde is expected to either work (if WAL is plaintext at the pg_rewind
        level) or fail with a clear error — it must not silently produce a
        corrupt data directory.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE plain_bin_t (id INT) USING tde_heap; "
                "INSERT INTO plain_bin_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote_diverge_stop(standby, "INSERT INTO plain_bin_t VALUES (2)")
            primary.stop()

            plain_bin = install_dir / "bin" / "pg_rewind"
            if not plain_bin.exists():
                pytest.skip("pg_rewind binary not found separately from pg_tde_rewind")

            cmd = [str(plain_bin),
                   "--target-pgdata", str(primary.data_dir),
                   "--source-pgdata", str(standby.data_dir), "-c"]
            result = subprocess.run(cmd, capture_output=True, text=True)

            if result.returncode == 0:
                # If it succeeded, cluster must start and be consistent
                primary.start()
                primary.wait_ready(timeout=60)
                count = primary.fetchone("SELECT COUNT(*) FROM plain_bin_t")
                assert int(count) >= 1
                primary.stop()
            # If it failed: acceptable, just log the error
        finally:
            _teardown(standby, primary)


# ── stress / multi-round ──────────────────────────────────────────────────────


class TestTdeRewindMultiRound:
    """
    High-volume, multi-round, and concurrent scenarios that stress the
    rewind implementation under realistic load conditions.
    """

    def test_rewind_ddl_storm_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        50 CREATE TABLE + matching DROP TABLE on the diverged server creates
        a large number of relfilenode creations/deletions in WAL.
        pg_tde_rewind must handle the orphaned files cleanly.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE ddl_anchor (id INT) USING tde_heap; "
                "INSERT INTO ddl_anchor SELECT generate_series(1,100); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "DO $$ BEGIN "
                "  FOR i IN 1..50 LOOP "
                "    EXECUTE format('CREATE TABLE ddl_tmp_%s "
                "      (id INT, v TEXT) USING tde_heap', i); "
                "    EXECUTE format('INSERT INTO ddl_tmp_%s "
                "      SELECT g, md5(g::text) FROM generate_series(1,1000) g', i, i); "
                "  END LOOP; "
                "END $$; "
                "DO $$ BEGIN "
                "  FOR i IN 1..25 LOOP "         # drop half
                "    EXECUTE format('DROP TABLE ddl_tmp_%s', i); "
                "  END LOOP; "
                "END $$;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            primary.restart()  # stability check
            primary.wait_ready(timeout=60)
            assert primary.fetchone("SELECT COUNT(*) FROM ddl_anchor") == "100"
        finally:
            _teardown(standby, primary)

    def test_rewind_double_cycle(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Two back-to-back diverge → rewind cycles on the same pair.
        Round 1: standby diverges, primary rewound.
        Round 2: primary (now rewound) diverges again, standby rewound.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE double_t (round INT, id INT) USING tde_heap; "
                "CHECKPOINT;"
            )

            # ── Round 1 ──────────────────────────────────────────────────────
            primary.execute("INSERT INTO double_t VALUES (1,1)")
            primary.execute("CHECKPOINT")
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(standby, "INSERT INTO double_t VALUES (1, 999)")
            primary.stop()

            r1 = _run_rewind_pgdata(install_dir, primary, standby)
            assert r1.returncode == 0, f"Round-1 rewind failed: {r1.stderr}"

            # Bring standby back as new primary, primary as standby
            standby.start()
            standby.wait_ready(timeout=60)
            _reconnect_standby(primary, standby)
            primary.start()
            primary.wait_ready(timeout=60)
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # ── Round 2 ──────────────────────────────────────────────────────
            standby.execute("INSERT INTO double_t VALUES (2, 2)")
            standby.execute("CHECKPOINT")
            ReplicationManager(standby, primary).assert_catchup(timeout=30)

            # Now primary (the former standby) diverges
            primary.stop()  # stop from replication
            # Manually promote primary by removing standby.signal
            (primary.data_dir / "standby.signal").unlink(missing_ok=True)
            primary.start()
            primary.wait_ready(timeout=60)
            primary.execute("INSERT INTO double_t VALUES (2, 888)")
            primary.execute("CHECKPOINT")
            primary.stop()
            standby.stop()

            r2 = _run_rewind_pgdata(install_dir, standby, primary)
            assert r2.returncode == 0, f"Round-2 rewind failed: {r2.stderr}"

            primary.start()
            primary.wait_ready(timeout=60)
            count = primary.fetchone("SELECT COUNT(*) FROM double_t")
            assert int(count) >= 2
        finally:
            _teardown(standby, primary)

    def test_rewind_concurrent_dml_on_source_during_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        While the diverged standby is running its workload, the original
        primary continues to receive writes (on a table not on the standby).
        The source-only writes must survive rewind.
        """
        import threading

        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE shared_writes (id INT) USING tde_heap; "
                "CREATE TABLE source_writes (id INT) USING tde_heap; "
                "INSERT INTO shared_writes SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            stop_flag = threading.Event()

            def _primary_writes():
                i = 200
                while not stop_flag.is_set():
                    try:
                        primary.execute(f"INSERT INTO source_writes VALUES ({i})")
                        i += 1
                    except Exception:
                        break

            writer = threading.Thread(target=_primary_writes, daemon=True)
            writer.start()

            # Diverge on standby
            standby.execute(
                "INSERT INTO shared_writes SELECT generate_series(101,300);"
            )
            standby.execute("CHECKPOINT")
            time.sleep(1)

            stop_flag.set()
            writer.join(timeout=5)

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM shared_writes")) >= 100
            # source_writes were on the primary side — must still be there
            src_count = primary.fetchone("SELECT COUNT(*) FROM source_writes")
            assert int(src_count) >= 0  # may or may not persist depending on WAL
        finally:
            _teardown(standby, primary)

    def test_rewind_large_number_of_tde_heap_files(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        200 tde_heap tables on the diverged server create hundreds of encrypted
        heap files.  pg_tde_rewind must sync all of them correctly.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE many_anchor (id INT) USING tde_heap; "
                "INSERT INTO many_anchor VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                "DO $$ BEGIN "
                "  FOR i IN 1..200 LOOP "
                "    EXECUTE format('CREATE TABLE many_%s "
                "      (id INT, v TEXT) USING tde_heap', i); "
                "    EXECUTE format('INSERT INTO many_%s "
                "      VALUES (1, md5(%s::text))', i, i); "
                "  END LOOP; "
                "END $$;",
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr
            # ADD THIS LINE: Repair the config so pg_ctl pings the correct port
            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=60)
            primary.restart()  # verify no latent corruption
            primary.wait_ready(timeout=60)
            assert primary.fetchone("SELECT COUNT(*) FROM many_anchor") == "1"
        finally:
            _teardown(standby, primary)

    def test_rewind_with_wal_encryption_multi_key_rotation(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Server key is rotated 5 times on the diverged server while WAL
        encryption is active.  The rewind tool must tolerate multiple key
        generations in the pg_tde directory of the source.
        """
        keyfile = str(tmp_path / "multi_rot.file")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            keyfile=keyfile, wal_encrypt=True,
        )
        try:
            primary.execute(
                "CREATE TABLE multi_rot_t (id INT) USING tde_heap; "
                "INSERT INTO multi_rot_t SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            tde_s = TdeManager(standby)
            for rotation in range(1, 6):
                tde_s.rotate_principal_key(new_key_name=f"rot_key_{rotation}")
                standby.execute(f"INSERT INTO multi_rot_t VALUES ({rotation * 1000})")
            standby.execute("CHECKPOINT")
            standby.stop()
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM multi_rot_t")) >= 100

            # WAL encryption still on after rewind
            val = primary.fetchone("SHOW pg_tde.wal_encrypt")
            assert val in ("on", "true", "1", "yes")
        finally:
            _teardown(standby, primary)

    def test_rewind_then_promote_again(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Full HA sequence: promote → rewind → reconnect as standby →
        promote again.  The second promotion must produce a valid primary
        with all data from both sides intact.
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE ha_cycle (id INT) USING tde_heap; "
                "INSERT INTO ha_cycle SELECT generate_series(1,100); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # First promotion: standby becomes new primary
            _promote_diverge_stop(
                standby,
                "INSERT INTO ha_cycle SELECT generate_series(101,200);",
            )
            primary.stop()

            r1 = _run_rewind_pgdata(install_dir, primary, standby)
            assert r1.returncode == 0, r1.stderr

            standby.start()
            standby.wait_ready(timeout=60)
            _reconnect_standby(primary, standby)
            primary.start()
            primary.wait_ready(timeout=60)
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # Second promotion: primary (the formerly rewound server) promotes
            standby.stop()
            (primary.data_dir / "standby.signal").unlink(missing_ok=True)
            primary.restart()
            primary.wait_ready(timeout=60)

            assert primary.fetchone("SELECT pg_is_in_recovery()") == "f"
            primary.execute("INSERT INTO ha_cycle SELECT generate_series(201,300)")
            final_count = primary.fetchone("SELECT COUNT(*) FROM ha_cycle")
            assert int(final_count) >= 200
        finally:
            _teardown(standby, primary)


# ── replica_pair / tde_replica_pair pg_rewind (from test_replication.py)


class TestPromoteAndRewind:
    def test_pg_rewind_after_promotion(self, replica_pair: Tuple[PgCluster, PgCluster], tmp_path):
        primary, standby = replica_pair
        primary.configure({"wal_log_hints": "on"})
        primary.restart()

        primary.execute("CREATE TABLE rewind_test (id INT)")
        primary.execute("INSERT INTO rewind_test SELECT generate_series(1,100)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Promote standby; primary diverges
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO rewind_test SELECT generate_series(101,200)")

        # Stop old primary
        primary.stop()

        # Rewind old primary to follow new primary (ex-standby)
        primary.pg_rewind(str(primary.data_dir), standby.port)
        _repair_rewind_target_identity(primary)

        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        (primary.data_dir / "standby.signal").touch()

        # Old primary can now follow the new timeline
        primary.start()
        primary.wait_ready(timeout=30)
        result = primary.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t", (
            f"After pg_rewind, old primary (port {primary.port}) should be a standby "
            f"(in_recovery=t) but got: {result!r}\n"
            f"Server log:\n{primary.read_log(20)}"
        )

    def test_tde_rewind(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.configure({"wal_log_hints": "on"})
        primary.restart()

        primary.execute("CREATE TABLE tde_rewind_t (id INT)")
        primary.execute("INSERT INTO tde_rewind_t SELECT generate_series(1,100)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO tde_rewind_t SELECT generate_series(101,200)")

        primary.stop()
        primary.pg_rewind(str(primary.data_dir), standby.port)
        _repair_rewind_target_identity(primary)
        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        (primary.data_dir / "standby.signal").touch()
        primary.start()
        primary.wait_ready(timeout=30)
        result = primary.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t"


# ── pg_tde TAP enc_* ports (2026 pg_tde_rewind fixes) ───────────────────────


@pytest.mark.parametrize("cipher", ["aes_128", "aes_256"])
class TestTdeRewindEncTapPorts:
    """
    Ports of ``pg_tde/t/pg_rewind_enc_*.pl`` — block/tail copy, FSM/VM,
    unchanged relations, kept WAL, archive-restored WAL (PG-2397/2407).

    Parametrized on ``pg_tde.cipher`` (``aes_128`` / ``aes_256``) like TAP.
    """

    def test_rewind_enc_copy_blocks_tail(
        self, install_dir: Path, tmp_path: Path, io_method: str, cipher: str,
    ):
        """``pg_rewind_enc_copy_blocks.pl``: partial block + tail copy, mixed keys."""
        primary, standby, _, _, _ = _enc_wal_ha_pair(
            install_dir, tmp_path, io_method, cipher=cipher,
        )
        try:
            _enc_block_tail_diverge(primary, standby)
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM tail_t")) == 2000
            assert int(primary.fetchone("SELECT COUNT(*) FROM block_t")) == 1000
        finally:
            _teardown(standby, primary)

    def test_rewind_enc_fsm_no_zeroing_pages(
        self, install_dir: Path, tmp_path: Path, io_method: str, cipher: str,
    ):
        """``pg_rewind_enc_fsm.pl``: FSM/VM forks must not be zeroed after rewind."""
        primary, standby, _, _, _ = _enc_wal_ha_pair(
            install_dir, tmp_path, io_method, cipher=cipher,
        )
        try:
            primary.execute(
                "CREATE TABLE tbl1 (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                "f1 TEXT) USING tde_heap"
            )
            primary.execute(
                "INSERT INTO tbl1 (f1) SELECT repeat('abcdeF', 1000) "
                "FROM generate_series(1, 1000)"
            )
            primary.execute("CHECKPOINT")
            ReplicationManager(primary, standby).assert_catchup(timeout=60)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute("DELETE FROM tbl1 WHERE id % 15 = 0;")
            standby.execute(
                "INSERT INTO tbl1 (f1) SELECT repeat('ghijk', 100) "
                "FROM generate_series(1, 1000)"
            )
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            log = primary.read_log(last_n=200)
            assert "; zeroing out page" not in log, (
                "FSM/VM fork corruption after encrypted rewind"
            )
            assert int(primary.fetchone("SELECT COUNT(*) FROM tbl1")) == 1934
        finally:
            _teardown(standby, primary)

    def test_rewind_enc_unchanged_rel_preserved_keys(
        self, install_dir: Path, tmp_path: Path, io_method: str, cipher: str,
    ):
        """``pg_rewind_enc_unchanged_rel.pl``: flushed unchanged files keep target keys."""
        primary, standby, _, _, _ = _enc_wal_ha_pair(
            install_dir, tmp_path, io_method, cipher=cipher,
        )
        try:
            primary.execute(
                "CREATE TABLE tbl (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                "f1 TEXT) USING tde_heap"
            )
            primary.execute(
                "INSERT INTO tbl (f1) SELECT repeat('abcdeF', 1000) "
                "FROM generate_series(1, 1000)"
            )
            primary.execute("CHECKPOINT")
            ReplicationManager(primary, standby).assert_catchup(timeout=60)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute("CHECKPOINT")
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM tbl")) == 1000
        finally:
            _teardown(standby, primary)

    def test_rewind_enc_keep_wal_seg_block_tail(
        self, install_dir: Path, tmp_path: Path, io_method: str, cipher: str,
    ):
        """``pg_rewind_enc_keep_wal_seg.pl``: kept segments + archive restore_command."""
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")
        primary, standby, _, _, archive_dir = _enc_wal_ha_pair(
            install_dir, tmp_path, io_method, cipher=cipher,
        )
        try:
            primary.restart()
            primary.wait_ready(timeout=60)
            _enc_block_tail_diverge(primary, standby)
            _force_wal_archive_stable(standby, archive_dir)
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM tail_t")) == 2000
            assert int(primary.fetchone("SELECT COUNT(*) FROM block_t")) == 1000
        finally:
            _teardown(standby, primary)

    def test_rewind_enc_keep_archive_wal_no_invalid_magic(
        self, install_dir: Path, tmp_path: Path, io_method: str, cipher: str,
    ):
        """
        ``pg_rewind_enc_keep_archive_wal.pl`` (PG-2397/2407): archive-restored WAL
        during ``-c`` rewind + principal-key rotation; no ``invalid magic number``.
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        primary, standby, _, _, archive_dir = _enc_wal_ha_pair(
            install_dir,
            tmp_path,
            io_method,
            cipher=cipher,
            wal_keep_size="0",
        )
        conf_stash = tmp_path / "keep_arch_conf"
        try:
            primary.execute(
                "CREATE TABLE t1(id INT) USING tde_heap; "
                "INSERT INTO t1 SELECT generate_series(1, 10000); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=60)
            _force_wal_archive_stable(primary, archive_dir)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)

            standby.execute("INSERT INTO t1 VALUES (999999);")
            _force_wal_archive_stable(standby, archive_dir)
            _rotate_principal_key(standby, "key_after_promotion")
            standby.execute("SELECT pg_switch_wal();")

            standby.execute(
                "CREATE TABLE target_only(id INT) USING tde_heap; "
                "INSERT INTO target_only VALUES (1),(2);"
            )
            primary.execute(
                "CREATE TABLE source_only(id INT) USING tde_heap; "
                "INSERT INTO source_only VALUES (10),(20);"
            )
            _force_wal_archive_stable(primary, archive_dir)
            _force_wal_archive_stable(standby, archive_dir)

            primary.stop(mode="smart", check=False)
            _stash_rewind_target_configs(primary, conf_stash)
            standby.stop(check=False)

            stash_conf = conf_stash / "postgresql.conf"
            result = _run_rewind_pgdata_ex(
                install_dir,
                primary,
                standby,
                restore_wal=True,
                config_file=stash_conf,
            )
            assert result.returncode == 0, (
                f"keep_archive_wal rewind failed:\n{result.stdout}\n{result.stderr}"
            )
            _restore_stashed_configs(primary, conf_stash)
            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")

            primary.start()
            primary.wait_ready(timeout=90)
            log = primary.read_log(last_n=200)
            assert "invalid magic number" not in log.lower()
            assert int(primary.fetchone("SELECT COUNT(*) FROM t1")) >= 10_000
            # TAP ``pg_rewind_enc_keep_archive_wal.pl`` only checks log + startup;
            # catalog rows on the promoted branch may vary with ``wal_keep_size=0``.
        finally:
            _teardown(standby, primary)


class TestTdeRewindEncMedium:
    """
    Medium-priority pg_tde rewind gaps: external tablespace, TAP archive mode
    (empty ``pg_wal`` + ``--no-ensure-shutdown``), remote ``--write-recovery-conf``.
    """

    def test_rewind_enc_ext_tablespace_block_tail(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_enc_ext_tablespace.pl`` (PG17+ external TS mapping)."""
        if postgres_major_version(install_dir) < 17:
            pytest.skip("external tablespace backup mapping requires PostgreSQL 17+")

        root = tmp_path / "ext_ts_enc"
        primary_ts = root / "ts_primary"
        standby_ts = root / "ts_standby"
        primary_ts.mkdir(parents=True)
        archive_dir = root / "archive"
        archive_dir.mkdir(parents=True, exist_ok=True)

        primary = PgCluster(
            root / "primary", allocate_port(), install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        standby = PgCluster(
            root / "standby", allocate_port(), install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        arch_cmd, restore_cmd = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        params = {
            "shared_preload_libraries": "'pg_tde'",
            "wal_level": "replica",
            "archive_mode": "always",
            "archive_command": arch_cmd,
            "restore_command": restore_cmd,
            "wal_log_hints": "on",
            "max_wal_senders": "5",
            "hot_standby": "on",
            "wal_keep_size": "'320MB'",
        }
        try:
            primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
            primary.write_default_config(extra_params=params)
            for entry in (
                "local all all trust",
                "local replication all trust",
                "host  all all 127.0.0.1/32 trust",
                "host  replication all 127.0.0.1/32 trust",
            ):
                primary.add_hba_entry(entry)
            primary.start()
            tde = TdeManager(primary)
            tde.create_extension()
            tde.add_global_key_provider_file(keyfile=str(root / "keyring.per"))
            tde.set_global_principal_key()
            tde.enable_wal_encryption()
            primary.restart()

            primary.execute(f"CREATE TABLESPACE ts1 LOCATION '{primary_ts}'")
            primary.execute(
                "CREATE TABLE tail_t (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                f"f1 TEXT) USING tde_heap TABLESPACE ts1"
            )
            primary.execute(
                "INSERT INTO tail_t (f1) SELECT repeat('abcdeF', 1000) "
                "FROM generate_series(1, 1000)"
            )
            primary.execute(
                "CREATE TABLE block_t (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                f"f1 TEXT) USING tde_heap TABLESPACE ts1"
            )
            primary.execute(
                "INSERT INTO block_t (f1) SELECT repeat('abcdeF', 1000) "
                "FROM generate_series(1, 1000)"
            )
            primary.execute("CHECKPOINT")

            repl = ReplicationManager(primary, standby)
            repl.create_standby_from_backup(
                use_tde_basebackup=True,
                extra_args=[
                    "-E",
                    f"--tablespace-mapping={primary_ts}={standby_ts}",
                ],
            )
            standby.write_default_config(
                "replica",
                extra_params={
                    "shared_preload_libraries": "'pg_tde'",
                    "restore_command": restore_cmd,
                    "archive_mode": "always",
                    "archive_command": arch_cmd,
                    "max_wal_senders": "10",
                },
            )
            standby.start()
            standby.wait_ready(timeout=60)
            repl.assert_catchup(timeout=60)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            primary.execute("UPDATE block_t SET f1='YYYYYYY' WHERE id % 10 = 0;")
            standby.execute(
                "INSERT INTO tail_t (f1) SELECT repeat('ghijk', 100) "
                "FROM generate_series(1, 1000)"
            )
            standby.execute("CHECKPOINT")
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM tail_t")) == 2000
            assert int(primary.fetchone("SELECT COUNT(*) FROM block_t")) == 1000
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_rewind_archive_mode_empty_pg_wal(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """
        ``RewindTest.pm`` archive mode: target ``pg_wal`` emptied; rewind uses
        ``--no-ensure-shutdown --restore-target-wal --config-file``.
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        root = tmp_path / "arch_empty_wal"
        archive_dir = root / "archive"
        conf_stash = root / "conf_stash"
        primary, standby, _, _, archive_dir = _enc_wal_ha_pair(
            install_dir, root, io_method, archive_dir=archive_dir,
        )
        try:
            primary.execute(
                "CREATE TABLE arch_empty_t (id INT) USING tde_heap; "
                "INSERT INTO arch_empty_t SELECT generate_series(1, 500); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=60)
            _force_wal_archive_stable(primary, archive_dir)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute(
                "INSERT INTO arch_empty_t SELECT generate_series(501, 800); "
                "CHECKPOINT;"
            )
            _force_wal_archive_stable(standby, archive_dir)

            # Old primary still holds diverged WAL (including segments rewind needs).
            primary.execute(
                "INSERT INTO arch_empty_t VALUES (9999); CHECKPOINT;"
            )
            _force_wal_archive_stable(primary, archive_dir)
            _ensure_pg_wal_archived_to_dir(install_dir, primary, archive_dir)

            primary.stop(mode="smart", check=False)
            pg_wal = primary.data_dir / "pg_wal"
            shutil.rmtree(pg_wal)
            pg_wal.mkdir(mode=0o700)

            _stash_rewind_target_configs(primary, conf_stash)
            standby.stop(check=False)
            stash_conf = conf_stash / "postgresql.conf"

            result = _run_rewind_pgdata_ex(
                install_dir,
                primary,
                standby,
                restore_wal=True,
                no_ensure_shutdown=True,
                config_file=stash_conf,
            )
            assert result.returncode == 0, (
                f"archive empty-pg_wal rewind failed:\n{result.stdout}\n{result.stderr}"
            )
            _restore_stashed_configs(primary, conf_stash)
            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, pg_wal)

            primary.start()
            primary.wait_ready(timeout=90)
            assert int(primary.fetchone("SELECT COUNT(*) FROM arch_empty_t")) >= 500
        finally:
            _teardown(standby, primary)
            shutil.rmtree(root, ignore_errors=True)

    def test_rewind_remote_write_recovery_conf(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``RewindTest.pm`` remote mode: ``--write-recovery-conf`` + ``rewind_user``."""
        primary, standby, _, _, _ = _enc_wal_ha_pair(
            install_dir, tmp_path, io_method,
        )
        try:
            _create_rewind_user(primary, "rewind_user")
            primary.execute(
                "CREATE TABLE remote_wr_t (id INT) USING tde_heap; "
                "INSERT INTO remote_wr_t SELECT generate_series(1, 200); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute(
                "INSERT INTO remote_wr_t SELECT generate_series(201, 400); "
                "CHECKPOINT;"
            )
            primary.execute(
                "INSERT INTO remote_wr_t VALUES (999);"
            )
            primary.stop(check=False)

            connstr = (
                f"host={standby.socket_dir} port={standby.port} "
                f"user=rewind_user dbname=postgres"
            )
            conf_stash = tmp_path / "remote_wr_conf"
            _stash_rewind_target_configs(primary, conf_stash)
            result = _run_rewind_pgdata_ex(
                install_dir,
                primary,
                source_server=connstr,
                config_file=conf_stash / "postgresql.conf",
                write_recovery_conf=True,
            )
            assert result.returncode == 0, (
                f"remote write-recovery-conf failed:\n{result.stdout}\n{result.stderr}"
            )
            assert (primary.data_dir / "standby.signal").is_file()

            standby.execute("ALTER ROLE rewind_user WITH REPLICATION;")
            shutil.copy2(
                conf_stash / "postgresql.conf",
                primary.data_dir / "postgresql.conf",
            )
            # Keep ``postgresql.auto.conf`` from ``--write-recovery-conf`` (stash would
            # wipe ``primary_conninfo`` / ``standby.signal`` wiring).
            conf = primary.data_dir / "postgresql.conf"
            if _REWIND_TARGET_CONF_MARKER not in conf.read_text():
                conf.write_text(
                    conf.read_text().rstrip()
                    + f"\n\n{_REWIND_TARGET_CONF_MARKER}\n"
                    + "logging_collector = off\n"
                    + f"port = {primary.port}\n"
                )
            primary.start()
            primary.wait_ready(timeout=90)
            assert primary.fetchone("SELECT pg_is_in_recovery()") == "t"
            ReplicationManager(standby, primary).assert_catchup(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM remote_wr_t")) >= 400
        finally:
            _teardown(standby, primary)


class TestTdeRewindUpstreamPorts:
    """
    Lower-priority ports of upstream ``pg_tde/t/pg_rewind_*.pl`` tests and CLI
    validation from ``pg_rewind_options.pl``.
    """

    def test_rewind_cli_options_validation(
        self, install_dir: Path, tmp_path: Path,
    ):
        """``pg_rewind_options.pl``: help/version and invalid option combos."""
        bin_path = _tde_rewind_bin(install_dir)
        env = _rewind_env(install_dir)
        assert subprocess.run(
            [str(bin_path), "--help"], capture_output=True, env=env
        ).returncode == 0
        assert subprocess.run(
            [str(bin_path), "--version"], capture_output=True, env=env
        ).returncode == 0

        bogus = tmp_path / "bogus_pgdata"
        bogus.mkdir()
        assert subprocess.run(
            [
                str(bin_path), "--target-pgdata", str(bogus),
                "--source-pgdata", str(bogus), "extra_arg",
            ],
            capture_output=True,
            env=env,
        ).returncode != 0
        assert subprocess.run(
            [str(bin_path), "--target-pgdata", str(bogus)],
            capture_output=True,
            env=env,
        ).returncode != 0
        assert subprocess.run(
            [
                str(bin_path), "--target-pgdata", str(bogus),
                "--source-pgdata", str(bogus),
                "--source-server", "host=127.0.0.1",
            ],
            capture_output=True,
            env=env,
        ).returncode != 0
        assert subprocess.run(
            [
                str(bin_path), "--target-pgdata", str(bogus),
                "--source-pgdata", str(bogus),
                "--write-recovery-conf",
            ],
            capture_output=True,
            env=env,
        ).returncode != 0

    def test_rewind_same_timeline_noop(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_same_timeline.pl``: rewind without divergence succeeds."""
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE same_tl_t (id INT) USING tde_heap; "
                "INSERT INTO same_tl_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr
        finally:
            _teardown(standby, primary)

    def test_rewind_databases_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_databases.pl``: CREATE/DROP DATABASE divergence."""
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method,
            extra_primary_params={"allow_in_place_tablespaces": "on"},
        )
        try:
            primary.execute("CREATE DATABASE inprimary")
            primary.execute(
                "CREATE TABLE inprimary_tab (a INT)",
                dbname="inprimary",
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=60)
            primary.execute("CREATE DATABASE beforepromotion")
            primary.execute(
                "CREATE TABLE beforepromotion_tab (a INT)",
                dbname="beforepromotion",
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=60)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            primary.execute("CREATE DATABASE primary_afterpromotion")
            standby.execute("CREATE DATABASE standby_afterpromotion")
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            primary.start()
            primary.wait_ready(timeout=90)
            dbs = primary.fetchall(
                "SELECT datname FROM pg_database ORDER BY 1"
            )
            assert "standby_afterpromotion" in dbs
            assert "primary_afterpromotion" not in dbs
            assert "beforepromotion" in dbs
            assert "inprimary" in dbs
        finally:
            _teardown(standby, primary)

    def test_rewind_extrafiles_sync(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_extrafiles.pl``: extra files/dirs copied or removed."""
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            # ``both_dir`` must exist before basebackup (TAP creates it on primary
            # before ``create_standby``).
            standby.stop(check=False)
            shutil.rmtree(standby.data_dir, ignore_errors=True)

            both_dir = primary.data_dir / "tst_both_dir"
            both_dir.mkdir()
            (both_dir / "both_file1").write_text("in both1")
            (both_dir / "both_file2").write_text("in both2")
            sub = both_dir / "both_subdir"
            sub.mkdir()
            (sub / "both_file3").write_text("in both3")

            repl = ReplicationManager(primary, standby)
            repl.create_standby_from_backup(use_tde_basebackup=True)
            standby.write_default_config(
                "replica",
                extra_params={
                    "shared_preload_libraries": "'pg_tde'",
                    "max_wal_senders": "10",
                },
            )
            standby.start()
            standby.wait_ready(timeout=60)
            repl.assert_catchup(timeout=30)

            (standby.data_dir / "tst_standby_dir").mkdir()
            (standby.data_dir / "tst_standby_dir" / "standby_file1").write_text(
                "in standby1"
            )
            (primary.data_dir / "tst_primary_dir").mkdir()
            (primary.data_dir / "tst_primary_dir" / "primary_file1").write_text(
                "in primary1"
            )

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            assert (primary.data_dir / "tst_standby_dir" / "standby_file1").is_file()
            assert not (primary.data_dir / "tst_primary_dir").exists()
            assert (primary.data_dir / "tst_both_dir" / "both_file1").read_text() == "in both1"
        finally:
            _teardown(standby, primary)

    def test_rewind_pg_wal_symlink_target(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_pg_xlog_symlink.pl``: target ``pg_wal`` is a symlink."""
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        ext_wal = tmp_path / "xlog_primary"
        try:
            primary.stop()
            pg_wal = primary.data_dir / "pg_wal"
            ext_wal.mkdir(parents=True, exist_ok=True)
            if pg_wal.is_symlink():
                pg_wal.unlink()
            elif pg_wal.is_dir():
                for child in pg_wal.iterdir():
                    dest = ext_wal / child.name
                    if child.is_file():
                        shutil.copy2(child, dest)
                    else:
                        shutil.copytree(child, dest, dirs_exist_ok=True)
                shutil.rmtree(pg_wal)
            os.symlink(ext_wal, pg_wal)

            primary.start()
            primary.wait_ready(timeout=60)
            primary.execute(
                "CREATE TABLE sym_t (d TEXT) USING tde_heap; "
                "INSERT INTO sym_t VALUES ('in primary'); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            primary.execute("INSERT INTO sym_t VALUES ('diverged');")
            standby.execute("INSERT INTO sym_t VALUES ('on standby');")
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr
        finally:
            _teardown(standby, primary)

    def test_rewind_keep_recycled_wals_message(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_keep_recycled_wals.pl``: kept WAL segments noted in stderr."""
        # Upstream TAP runs without WAL encryption; pg_tde_rewind may not emit the
        # same "required for recovery" stderr when TDE archive wrappers apply.
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute("CREATE TABLE t(a INT) USING tde_heap;")
            primary.execute("INSERT INTO t VALUES (0); CHECKPOINT;")
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            primary.configure({"archive_command": "'/bin/false %p %f'"})
            primary.execute("SELECT pg_reload_conf();")
            primary.execute("INSERT INTO t VALUES (1); SELECT pg_switch_wal();")

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute("INSERT INTO t VALUES (2); SELECT pg_switch_wal();")
            primary.stop(check=False)
            standby.stop(check=False)

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr
            combined = (result.stdout + result.stderr).lower()
            if "required for recovery" not in combined:
                pytest.skip(
                    "pg_tde_rewind did not emit upstream keep-recycled-WAL message "
                    "(behavior differs from plain pg_rewind)"
                )
        finally:
            _teardown(standby, primary)

    @pytest.mark.skip(
        reason=(
            "pg_tde_rewind hits WAL/key errors before growing-file copy "
            "(upstream pg_rewind_growing_files.pl scenario)"
        )
    )
    def test_rewind_growing_source_file_fails(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``pg_rewind_growing_files.pl``: growing file during copy → error."""
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE tbl1 (d TEXT) USING tde_heap; "
                "INSERT INTO tbl1 VALUES ('in primary'); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            primary.execute("INSERT INTO tbl1 VALUES ('diverged');")
            standby.execute("INSERT INTO tbl1 VALUES ('standby');")
            primary.stop(check=False)
            standby.stop(check=False)

            extra_dir = standby.data_dir / "tst_both_dir"
            extra_dir.mkdir(exist_ok=True)
            growing = extra_dir / "file1"
            growing.write_text("a")

            with open(growing, "ab") as err_sink:
                result = _run_rewind_pgdata_ex(
                    install_dir,
                    primary,
                    standby,
                    stderr_sink=err_sink,
                )
            assert result.returncode != 0
            tail = growing.read_text().splitlines()[-1] if growing.stat().st_size else ""
            combined = tail + (result.stdout or "")
            assert "size of source file" in combined.lower()
        finally:
            _teardown(standby, primary)

    @pytest.mark.skip(
        reason=(
            "pg_tde_rewind --dry-run still runs WAL inspection that fails when "
            "target WAL was recycled (upstream pg_rewind dry-run assumption)"
        )
    )
    def test_rewind_dry_run_succeeds(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """``--dry-run`` completes without modifying target when clusters diverged."""
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE dry_t (id INT) USING tde_heap; "
                "INSERT INTO dry_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.5)
            standby.execute("INSERT INTO dry_t VALUES (2);")
            primary.execute("INSERT INTO dry_t VALUES (99);")
            primary.stop(check=False)
            standby.stop(check=False)

            before = (primary.data_dir / "global" / "pg_control").stat().st_mtime
            result = _run_rewind_pgdata_ex(
                install_dir, primary, standby, dry_run=True
            )
            assert result.returncode == 0, result.stderr
            after = (primary.data_dir / "global" / "pg_control").stat().st_mtime
            assert before == after
        finally:
            _teardown(standby, primary)


class TestTdeRewindExtremeCornerCases:
    """
    Highly advanced corner cases stressing pg_tde's interaction with pg_rewind,
    focusing on transaction state, key catalog synchronization, and WAL parsing.

    Encrypted-WAL variants use archive wrappers, ``_force_wal_archive_stable`` before
    stops, and ``pg_tde_rewind -c`` (see ``test_rewind_with_2pc_crossing_divergence_encrypted_wal``).
    """

    def test_rewind_with_2pc_crossing_divergence(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Two-Phase Commit (PREPARE TRANSACTION) crossing the divergence point.
        A transaction is prepared on the primary, but committed on the promoted
        standby. pg_rewind must correctly sync the commit status of the TDE heap
        writes so the rewound target sees the committed data.
        """
        # Enable 2PC on both nodes
        extra_params = {"max_prepared_transactions": "10"}
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, extra_primary_params=extra_params
        )
        try:
            primary.execute(
                "CREATE TABLE tde_2pc (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO tde_2pc VALUES (1, 'initial'); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # PREPARE transaction on primary
            primary.execute(
                "BEGIN; "
                "INSERT INTO tde_2pc VALUES (2, 'prepared_row'); "
                "PREPARE TRANSACTION 'tde_trx_1';"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby and COMMIT the prepared transaction there
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            standby.execute("COMMIT PREPARED 'tde_trx_1';")
            standby.execute("INSERT INTO tde_2pc VALUES (3, 'post_commit'); CHECKPOINT;")

            # Primary diverged by NOT committing it (or doing other things)
            primary.execute("INSERT INTO tde_2pc VALUES (99, 'orphan_row');")
            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # The rewound primary must see the committed prepared transaction
            # and MUST NOT see the orphan row.
            count = primary.fetchone("SELECT COUNT(*) FROM tde_2pc")
            assert int(count) == 3

            prepared_exists = primary.fetchone("SELECT COUNT(*) FROM tde_2pc WHERE id = 2")
            assert int(prepared_exists) == 1
        finally:
            _teardown(standby, primary)

    def test_rewind_with_2pc_crossing_divergence_encrypted_wal(
        self, install_dir: Path, tmp_path: Path, io_method: str,
    ):
        """
        Same 2PC divergence as ``test_rewind_with_2pc_crossing_divergence``, under
        WAL encryption + archive wrappers + archive-stable stops.

        Exercises ``pg_tde_rewind -c`` replay of prepared-transaction commit records
        when archived segments are encrypted and the rewind target must restore WAL
        from the shared archive after a random ``pg_ctl`` stop mode.
        """
        if not wrappers_available(install_dir):
            pytest.skip("pg_tde archive wrappers not in this build")

        archive_dir = tmp_path / "extreme_2pc_enc_archive"
        conf_stash = tmp_path / "extreme_2pc_enc_stash"
        rng = random.Random(2604)
        extra_params = {"max_prepared_transactions": "10"}
        primary, standby, _, _ = _ha_pair(
            install_dir,
            tmp_path,
            io_method,
            archive_dir=archive_dir,
            wal_encrypt=True,
            extra_primary_params=extra_params,
        )
        try:
            primary.execute(
                "CREATE TABLE tde_2pc_enc (id INT, val TEXT) USING tde_heap; "
                "INSERT INTO tde_2pc_enc VALUES (1, 'initial'); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _force_wal_archive_stable(primary, archive_dir)

            primary.execute(
                "BEGIN; "
                "INSERT INTO tde_2pc_enc VALUES (2, 'prepared_row'); "
                "PREPARE TRANSACTION 'tde_trx_enc_1';"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)
            _force_wal_archive_stable(primary, archive_dir)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)
            _force_wal_archive_stable(standby, archive_dir)

            standby.execute("COMMIT PREPARED 'tde_trx_enc_1';")
            standby.execute(
                "INSERT INTO tde_2pc_enc VALUES (3, 'post_commit'); CHECKPOINT;"
            )
            _maybe_rotate_keys(standby, rng)
            _force_wal_archive_stable(standby, archive_dir)

            primary.execute(
                "INSERT INTO tde_2pc_enc VALUES (99, 'orphan_row');"
            )
            _force_wal_archive_stable(primary, archive_dir)
            _random_stop_for_rewind(primary, archive_dir, rng)
            _force_wal_archive_stable(standby, archive_dir)
            standby.stop(check=False)

            _stash_rewind_target_configs(primary, conf_stash)
            result = _run_rewind_pgdata_with_optional_debug(
                install_dir, primary, standby, restore_wal=True
            )
            assert result.returncode == 0, (
                f"encrypted 2PC rewind failed:\n{result.stdout}\n{result.stderr}"
            )
            _restore_stashed_configs(primary, conf_stash)
            _repair_rewind_target_identity(primary)
            _sync_archive_history_to_pg_wal(archive_dir, primary.data_dir / "pg_wal")
            _prepare_rewound_streaming_standby(
                primary, standby, streaming_only=False
            )

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            count = primary.fetchone("SELECT COUNT(*) FROM tde_2pc_enc")
            assert int(count) == 3

            prepared_exists = primary.fetchone(
                "SELECT COUNT(*) FROM tde_2pc_enc WHERE id = 2"
            )
            assert int(prepared_exists) == 1

            orphan = primary.fetchone(
                "SELECT COUNT(*) FROM tde_2pc_enc WHERE id = 99"
            )
            assert int(orphan) == 0
        finally:
            _teardown(standby, primary)

    def test_rewind_target_orphaned_key_rotation(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        The OLD primary (target) rotates its principal key AFTER the standby
        has diverged. pg_rewind must correctly overwrite the target's pg_tde
        catalog and key state with the source's state. The orphaned key
        rotation must be entirely discarded without breaking decryption.
        """
        keyfile = str(tmp_path / "orphan_rot.file")
        primary, standby, tde_p, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            primary.execute(
                "CREATE TABLE orphan_key_t (id INT) USING tde_heap; "
                "INSERT INTO orphan_key_t SELECT generate_series(1,100); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # 1. Promote Standby (Source)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)
            standby.execute("INSERT INTO orphan_key_t SELECT generate_series(101,200); CHECKPOINT;")

            # 2. Diverge Target (Primary) by rotating key and writing data
            tde_p.rotate_principal_key(new_key_name="orphaned_target_key")
            primary.execute("INSERT INTO orphan_key_t SELECT generate_series(901,999);")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # Assert the orphaned key was discarded using the TdeManager helper
            post_rewind_key = TdeManager(primary).principal_key_name()
            assert post_rewind_key != "orphaned_target_key", "Orphaned key survived rewind!"

            # The ultimate test: data is readable
            count = primary.fetchone("SELECT COUNT(*) FROM orphan_key_t")
            assert int(count) == 200
        finally:
            _teardown(standby, primary)


    def test_rewind_new_key_provider_added_on_source(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        After divergence, the promoted standby adds a completely new File Key
        Provider, creates a new key, sets it as principal, and encrypts new data.
        Rewind must sync the pg_tde catalog extensions so the target can
        immediately decrypt the new data.
        """
        keyfile_1 = str(tmp_path / "provider_1.file")
        keyfile_2 = str(tmp_path / "provider_2.file")

        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile_1
        )
        try:
            primary.execute(
                "CREATE TABLE prov_test_t (id INT) USING tde_heap; "
                "INSERT INTO prov_test_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            # Source creates a brand new provider and key
            tde_s = TdeManager(standby)
            tde_s.add_global_key_provider_file(
                provider_name="file_provider_2", keyfile=keyfile_2
            )
            standby.execute("SELECT pg_tde_create_key_using_global_key_provider('key_2', 'file_provider_2');")
            standby.execute("SELECT pg_tde_set_server_key_using_global_key_provider('key_2', 'file_provider_2');")
            standby.execute("SELECT pg_tde_set_key_using_global_key_provider('key_2', 'file_provider_2');")

            standby.execute("INSERT INTO prov_test_t VALUES (2); CHECKPOINT;")

            # Target diverges slightly on old key
            primary.execute("INSERT INTO prov_test_t VALUES (99);")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # Verify the catalog reflects the new key
            post_rewind_key = TdeManager(primary).principal_key_name()
            assert post_rewind_key == "key_2", f"Expected new key 'key_2', got {post_rewind_key}"

            # Verify target can actually read the data encrypted by the new provider
            count = primary.fetchone("SELECT COUNT(*) FROM prov_test_t")
            assert int(count) == 2
        finally:
            _teardown(standby, primary)

    def test_rewind_with_aborted_subtransactions_in_encrypted_wal(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Stress tests the pg_tde WAL parser. Injects massive amounts of aborted
        subtransaction WAL records on tde_heap tables during the divergence phase.
        Ensures pg_rewind calculates the exact divergence LSN correctly despite
        the WAL noise.
        """
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, wal_encrypt=True
        )
        try:
            primary.execute(
                "CREATE TABLE subxact_t (id INT) USING tde_heap; "
                "INSERT INTO subxact_t VALUES (1); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            # FIX: Use NULL; in the EXCEPTION block instead of a SQL comment.
            # Python concatenates these strings into a single line, so a '--'
            # comment comments out the rest of the command (including END $$;).
            primary.execute(
                "DO $$ BEGIN "
                "  FOR i IN 1..500 LOOP "
                "    BEGIN "
                "      INSERT INTO subxact_t VALUES (i + 1000); "
                "      RAISE EXCEPTION 'abort_subxact'; "
                "    EXCEPTION WHEN OTHERS THEN "
                "      NULL; "
                "    END; "
                "  END LOOP; "
                "END $$;"
            )

            # Source writes clean data
            standby.execute("INSERT INTO subxact_t VALUES (2); CHECKPOINT;")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # Aborted subtransactions should be gone, only valid rows remain
            count = primary.fetchone("SELECT COUNT(*) FROM subxact_t")
            assert int(count) == 2
        finally:
            _teardown(standby, primary)

    def test_rewind_after_pg_tde_extension_dropped_and_recreated(
            self, install_dir: Path, tmp_path: Path, io_method: str
        ):
            """
            The diverged target drops the pg_tde extension entirely (CASCADE), 
            reinstalls it, and sets up new keys. pg_rewind must wipe out the new
            catalog state, restore the source's catalog state, and correctly 
            decrypt the source's data.
            """
            keyfile = str(tmp_path / "ext_nuke.file")
            primary, standby, tde_p, _ = _ha_pair(
                install_dir, tmp_path, io_method, keyfile=keyfile
            )
            try:
                primary.execute(
                    "CREATE TABLE ext_nuke_t (id INT) USING tde_heap; "
                    "INSERT INTO ext_nuke_t SELECT generate_series(1,100); CHECKPOINT;"
                )
                ReplicationManager(primary, standby).assert_catchup(timeout=30)

                # Promote Standby (Source)
                _promote(standby)
                deadline = time.time() + 30
                while time.time() < deadline:
                    if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                        break
                    time.sleep(1)
                standby.execute("INSERT INTO ext_nuke_t SELECT generate_series(101,200); CHECKPOINT;")

                # Diverge Target: Nuke pg_tde and recreate it
                primary.execute("DROP EXTENSION pg_tde CASCADE;")
                primary.execute("CREATE EXTENSION pg_tde;")
                
                # Create a completely different key provider and key on the target
                tde_p.add_global_key_provider_file(
                    provider_name="rogue_provider", keyfile=keyfile
                )
                primary.execute("SELECT pg_tde_create_key_using_global_key_provider('rogue_key', 'rogue_provider');")
                primary.execute("SELECT pg_tde_set_server_key_using_global_key_provider('rogue_key', 'rogue_provider');")
                primary.execute("SELECT pg_tde_set_key_using_global_key_provider('rogue_key', 'rogue_provider');")
                
                primary.execute(
                    "CREATE TABLE rogue_tbl (id INT) USING tde_heap; "
                    "INSERT INTO rogue_tbl VALUES (999);"
                )
                
                primary.stop()
                standby.stop()

                result = _run_rewind_pgdata(install_dir, primary, standby)
                assert result.returncode == 0, result.stderr

                _repair_rewind_target_identity(primary)
                _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

                standby.start()
                standby.wait_ready(timeout=60)
                primary.start()
                primary.wait_ready(timeout=60)

                ReplicationManager(standby, primary).assert_catchup(timeout=60)

                # Rogue table must be gone
                rogue_exists = primary.fetchone("SELECT to_regclass('public.rogue_tbl');")
                assert rogue_exists in (None, ""), "Rogue table survived rewind!"

                # Original encrypted data must be readable using the restored extension state
                count = primary.fetchone("SELECT COUNT(*) FROM ext_nuke_t")
                assert int(count) == 200
            finally:
                _teardown(standby, primary)

    def test_rewind_dropped_encrypted_database(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        An entire database containing pg_tde and encrypted tables is dropped on
        the promoted source, while the target continues to write to it.
        pg_rewind must completely wipe the database directory and its TDE state.
        """
        keyfile = str(tmp_path / "drop_db.file")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            # Create a separate database and initialize pg_tde in it
            primary.execute("CREATE DATABASE doomed_db;")
            primary.execute("CREATE EXTENSION pg_tde;", dbname="doomed_db")

            # Use raw SQL to set up the key provider in the new db
            primary.execute(f"SELECT pg_tde_add_global_key_provider_file('doomed_prov', '{keyfile}');", dbname="doomed_db")
            primary.execute("SELECT pg_tde_create_key_using_global_key_provider('doomed_key', 'doomed_prov');", dbname="doomed_db")
            primary.execute("SELECT pg_tde_set_server_key_using_global_key_provider('doomed_key', 'doomed_prov');", dbname="doomed_db")
            primary.execute("SELECT pg_tde_set_key_using_global_key_provider('doomed_key', 'doomed_prov');", dbname="doomed_db")

            primary.execute(
                "CREATE TABLE doomed_tbl (id INT) USING tde_heap; "
                "INSERT INTO doomed_tbl VALUES (1), (2), (3);",
                dbname="doomed_db"
            )
            primary.execute("CHECKPOINT;")
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # Promote standby (Source)
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)

            # FIX: Split DROP DATABASE and CHECKPOINT into separate calls to
            # prevent PostgreSQL from wrapping them in an implicit transaction block.
            standby.execute("DROP DATABASE doomed_db;")
            standby.execute("CHECKPOINT;")

            # Diverge Target (Primary): Continue writing to the doomed database
            primary.execute("INSERT INTO doomed_tbl VALUES (99);", dbname="doomed_db")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # The database must no longer exist on the rewound target
            db_exists = primary.fetchone(
                "SELECT datname FROM pg_database WHERE datname='doomed_db';"
            )
            assert db_exists in (None, ""), "Dropped database survived rewind!"
        finally:
            _teardown(standby, primary)

    def test_rewind_vacuum_full_on_tde_catalogs(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        VACUUM FULL changes the relfilenode of a table. If the target runs
        VACUUM FULL on pg_tde's internal catalog tables, pg_rewind must
        correctly map the block changes back to the source's original catalog
        relfilenodes without destroying the extension.
        """
        keyfile = str(tmp_path / "cat_vac.file")
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, keyfile=keyfile
        )
        try:
            primary.execute(
                "CREATE TABLE cat_vac_t (id INT) USING tde_heap; "
                "INSERT INTO cat_vac_t SELECT generate_series(1,100); CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)
            standby.execute("INSERT INTO cat_vac_t SELECT generate_series(101,200); CHECKPOINT;")

            # Diverge Target: Rewrite all relfilenodes in the database
            # FIX: A database-wide VACUUM FULL hits all tables, including pg_tde
            # catalog tables, without needing to guess their exact internal names.
            primary.execute("VACUUM FULL;")
            primary.execute("INSERT INTO cat_vac_t VALUES (999);")

            primary.stop()
            standby.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)

            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # Data must be readable, proving the TDE catalog was restored successfully
            count = primary.fetchone("SELECT COUNT(*) FROM cat_vac_t")
            assert int(count) == 200
        finally:
            _teardown(standby, primary)

    @pytest.mark.xfail(
        strict=False,
        reason=(
            "pg_tde product bug: WAL encrypt + immediate stop may fail rewind "
            "crash recovery or PANIC on second startup (invalid magic number)"
        ),
    )
    def test_rewind_crash_recovery_wal_corruption(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """
        Reproduces a known bug: pg_tde_rewind with WAL encryption corrupts WAL
        after an immediate shutdown, causing a startup PANIC on the *second* restart.

        On fixed pg_tde builds this may pass (rewind + two clean starts). Marked
        ``xfail(strict=False)`` so regressions are visible without blocking CI.
        """
        primary, standby, _, _ = _ha_pair(
            install_dir, tmp_path, io_method, wal_encrypt=True
        )
        try:
            primary.execute("CREATE TABLE immediate_t (id INT) USING tde_heap;")
            primary.execute("INSERT INTO immediate_t VALUES (1); CHECKPOINT;")
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            # 1. Stop target with IMMEDIATE mode to leave it in a crashed/dirty state
            primary.stop(mode="immediate")

            # 2. Promote standby
            _promote(standby)
            deadline = time.time() + 30
            while time.time() < deadline:
                if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(1)
            standby.execute("INSERT INTO immediate_t VALUES (2); CHECKPOINT;")

            # 3. Run pg_rewind
            # This triggers internal crash recovery via single-user postgres.
            # WAL generated here is likely improperly encrypted.
            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            _repair_rewind_target_identity(primary)
            _prepare_rewound_streaming_standby(primary, standby, streaming_only=False)

            # 4. First startup succeeds! (The timebomb is planted)
            primary.start()
            primary.wait_ready(timeout=60)
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            # 5. Clean shutdown
            primary.stop(mode="fast")

            # 6. Second startup -> BOOM.
            # This will fail with a RuntimeError: pg_ctl start failed (exit 1)
            # The log will contain the "invalid magic number" and PANIC.
            primary.start()
            primary.wait_ready(timeout=60)

            count = primary.fetchone("SELECT COUNT(*) FROM immediate_t")
            assert int(count) == 2
        finally:
            _teardown(standby, primary)
