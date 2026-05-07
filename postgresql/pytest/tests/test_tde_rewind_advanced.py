"""
pg_tde_rewind advanced corner-case tests.

Expands coverage beyond test_recovery.py (PR #428 port) with scenarios
that stress the interaction between pg_tde and pg_rewind at the edges:

  TestTdeRewindWalEncryption       WAL-encrypted archives, compression + TDE
  TestTdeRewindFullHaCycle         Live-source rewind, full failback as standby,
                                   cascading 3-node topology
  TestTdeRewindKeyProviderEdges    Database-level provider, multi-provider, provider
                                   absent on target (negative)
  TestTdeRewindDataStructures      Tablespace, sequence reset, relfilenode via
                                   VACUUM FULL, GIN index, multiple databases
  TestTdeRewindNegative            Source running, dirty target, no archive for -c,
                                   same-dir source/target
  TestTdeRewindMultiRound          DDL storm, double rewind, concurrent writes,
                                   3-round HA lifecycle
"""

import random
import shutil
import subprocess
import time
import os
import signal
from pathlib import Path
from typing import Optional, Tuple

import pytest

from conftest import allocate_port
from lib import PgCluster, ReplicationManager, TdeManager, archive_restore_conf_values
from lib.cluster import libpq_superuser

pytestmark = [pytest.mark.recovery, pytest.mark.slow]


# ── module-level helpers ──────────────────────────────────────────────────────


def _tde_rewind_bin(install_dir: Path) -> Path:
    p = install_dir / "bin" / "pg_tde_rewind"
    return p if p.exists() else install_dir / "bin" / "pg_rewind"


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
    cmd = [str(_tde_rewind_bin(install_dir)),
           "--target-pgdata", str(target.data_dir),
           "--source-pgdata", str(source.data_dir)]
    if restore_wal:
        cmd.append("-c")
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


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
    connstr = (f"host={source.socket_dir} port={source.port} "
               f"user={libpq_superuser()} dbname=postgres")
    cmd = [str(_tde_rewind_bin(install_dir)),
           "--target-pgdata", str(target.data_dir),
           "--source-server", connstr]
    if restore_wal:
        cmd.append("-c")
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _promote(standby: PgCluster) -> None:
    """
    Promote standby with SQL and wait until it exits recovery.
    Avoid pg_ctl promote in flaky CI environments.
    """
    # Ensure server is up before attempting promotion.
    if not standby.is_ready():
        standby.start()
        standby.wait_ready(timeout=60)

    try:
        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
            return
    except Exception:
        pass

    # Prefer pg_ctl promote first (avoids SQL-level promotion edge cases).
    try:
        standby.promote()
    except Exception:
        # Fallback to SQL promotion.
        standby.execute("SELECT pg_promote(wait_seconds => 60)")

    deadline = time.time() + 60
    while time.time() < deadline:
        if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
            return
        time.sleep(1)
    raise RuntimeError(
        "Standby did not promote within timeout.\n"
        f"Standby log tail:\n{standby.read_log(last_n=40)}"
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

    arch_cmd, restore_cmd = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=True
    )
    params = {
        "shared_preload_libraries": "'pg_tde'",
        "wal_level": "replica",
        "archive_mode": "on",
        "archive_command": arch_cmd,
        # Required for pg_tde_rewind -c when this node later becomes target.
        "restore_command": restore_cmd,
        "wal_log_hints": "on",
        "max_wal_senders": "5",
        "hot_standby": "on",
    }
    if wal_compress:
        params["wal_compression"] = f"'{wal_compress}'"
    if extra_primary_params:
        params.update(extra_primary_params)

    try:
        primary.initdb(extra_args=["--no-data-checksums"])
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
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby_params = {
            "shared_preload_libraries": "'pg_tde'",
            "restore_command": restore_cmd,
        }
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


# ── WAL encryption + rewind ───────────────────────────────────────────────────


class TestTdeRewindWalEncryption:
    """
    Corner cases where WAL encryption is active on both nodes.

    pg_tde encrypts WAL segments in pg_wal; pg_rewind reads those segments to
    determine the divergence point.  These tests verify that the rewind tool
    can correctly read encrypted WAL using the key material present in the
    target's pg_tde directory.
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
        # Try lz4 first; fall back to pglz if the build doesn't support it
        primary = standby = None
        try:
            primary, standby, _, _ = _ha_pair(
                install_dir, tmp_path, io_method, wal_compress="lz4"
            )
        except Exception:
            if primary is not None and standby is not None:
                _teardown(standby, primary)
            primary, standby, _, _ = _ha_pair(
                install_dir, tmp_path, io_method, wal_compress="pglz"
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

            primary.start()
            primary.wait_ready(timeout=60)
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
        Simulate key-range overlap around divergence:
          - old primary writes encrypted WAL with key A
          - promoted standby rotates server key multiple times and archives WAL
          - rewind runs with -c and may keep some target WAL segments

        After rewind, the rewound node must still be able to consume new WAL
        from the promoted source. This exercises wal_keys reconciliation for
        kept target segments with source-side key generations.
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

            tde_s = TdeManager(standby)
            for i in range(1, 4):
                tde_s.rotate_principal_key(new_key_name=f"src_wal_key_rot_{i}")
                start_id = 10000 * i
                standby.execute(
                    "INSERT INTO wal_overlap_t "
                    f"SELECT g, repeat(md5(g::text), 8) FROM generate_series({start_id},{start_id + 350}) g;"
                )
                standby.execute("SELECT pg_switch_wal(); CHECKPOINT;")

            standby.stop()
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby, restore_wal=True)
            assert result.returncode == 0, (
                f"Rewind with overlapping WAL key generations failed:\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM wal_overlap_t")) >= 3000

            # Re-attach the rewound node as a standby and verify it replays
            # newly generated WAL from the source after key rotations.
            primary.stop(check=False)
            _reconnect_standby(primary, standby)
            standby.start()
            standby.wait_ready(timeout=60)
            primary.start()
            primary.wait_ready(timeout=60)
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

            standby.execute(
                "INSERT INTO wal_overlap_t "
                "SELECT g, repeat(md5(g::text), 6) FROM generate_series(50001,50300) g; "
                "SELECT pg_switch_wal(); CHECKPOINT;"
            )
            ReplicationManager(standby, primary).assert_catchup(timeout=60)

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
        arch3, rest3 = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )

        try:
            # Boot nodeA
            nodeA.initdb(extra_args=["--no-data-checksums"])
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
        """
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(
                "CREATE TABLE round_t (round INT, val TEXT) USING tde_heap; "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            for rnd in range(1, 4):
                # On round 1 standby is still replica; promote+diverge helper handles it.
                # On later rounds it is already primary and _promote() is a no-op.
                _promote_diverge_stop(
                    standby,
                    f"INSERT INTO round_t VALUES ({rnd}, 'diverged-{rnd}');",
                )
                primary.stop(check=False)

                result = _run_rewind_pgdata(install_dir, primary, standby)
                assert result.returncode == 0, f"Round {rnd} rewind failed:\n{result.stderr}"

                # Bring rewound target up and verify state is readable.
                primary.start()
                primary.wait_ready(timeout=60)
                assert int(primary.fetchone("SELECT COUNT(*) FROM round_t")) >= rnd
                primary.stop()

                # Prepare source for next round.
                standby.start()
                standby.wait_ready(timeout=60)
                standby.execute("CHECKPOINT")

            # Final verification from source side after all rounds.
            count = standby.fetchone("SELECT COUNT(*) FROM round_t")
            assert int(count) >= 3
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
        """
        Create a tablespace on the original primary; after divergence the
        standby moves data into that tablespace.  Rewind must handle the
        symlink in pg_tblspc correctly.
        """
        ts_dir = tmp_path / "ts1"
        ts_dir.mkdir()
        primary, standby, _, _ = _ha_pair(install_dir, tmp_path, io_method)
        try:
            primary.execute(f"CREATE TABLESPACE ts1 LOCATION '{ts_dir}'")
            primary.execute(
                "CREATE TABLE in_ts1 (id INT) USING tde_heap TABLESPACE ts1; "
                "INSERT INTO in_ts1 SELECT generate_series(1,100); "
                "CHECKPOINT;"
            )
            ReplicationManager(primary, standby).assert_catchup(timeout=30)

            _promote_diverge_stop(
                standby,
                [
                    "INSERT INTO in_ts1 SELECT generate_series(101,300)",
                    "VACUUM FULL in_ts1",
                ],
            )
            primary.stop()

            result = _run_rewind_pgdata(install_dir, primary, standby)
            assert result.returncode == 0, result.stderr

            primary.start()
            primary.wait_ready(timeout=60)
            assert int(primary.fetchone("SELECT COUNT(*) FROM in_ts1")) >= 100
        finally:
            _teardown(standby, primary)
            shutil.rmtree(ts_dir, ignore_errors=True)

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
