"""
Crash recovery, pg_rewind, WAL utilities, and relfilenode reuse tests.

Covers scenarios from:
  - rewind.sh
  - pg_relfilenode_reuse_test.sh
  - pg_resetwal.sh / pg_resetwal_iteration.sh
  - pg_receivewal.sh
  - pg_archivecleanup.sh
"""
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager, ReplicationManager
from lib.cluster import libpq_superuser


pytestmark = pytest.mark.recovery


# ── crash recovery ────────────────────────────────────────────────────────────


class TestCrashRecovery:
    def test_data_survives_crash_plain(self, primary_cluster: PgCluster):
        primary_cluster.execute("CREATE TABLE crash_test (id INT)")
        primary_cluster.execute("INSERT INTO crash_test SELECT generate_series(1,1000)")
        # Force checkpoint so data is flushed
        primary_cluster.execute("CHECKPOINT")
        primary_cluster.crash()
        primary_cluster.start()
        primary_cluster.wait_ready()
        count = primary_cluster.fetchone("SELECT COUNT(*) FROM crash_test")
        assert count == "1000"

    def test_data_survives_crash_tde(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE tde_crash_test (id INT)")
        tde_primary.execute("INSERT INTO tde_crash_test SELECT generate_series(1,500)")
        tde_primary.execute("CHECKPOINT")
        tde_primary.crash()
        tde_primary.start()
        tde_primary.wait_ready()
        count = tde_primary.fetchone("SELECT COUNT(*) FROM tde_crash_test")
        assert count == "500"

    def test_immediate_shutdown_recovery(self, primary_cluster: PgCluster):
        primary_cluster.execute("CREATE TABLE imm_stop_test (id INT)")
        primary_cluster.execute("INSERT INTO imm_stop_test SELECT generate_series(1,200)")
        primary_cluster.stop(mode="immediate")
        primary_cluster.start()
        primary_cluster.wait_ready()
        count = primary_cluster.fetchone("SELECT COUNT(*) FROM imm_stop_test")
        assert int(count) >= 0  # data may or may not be flushed, recovery should still succeed

    def test_crash_then_insert(self, primary_cluster: PgCluster):
        primary_cluster.execute("CREATE TABLE post_crash (id INT)")
        primary_cluster.execute("INSERT INTO post_crash SELECT generate_series(1,100)")
        primary_cluster.execute("CHECKPOINT")
        primary_cluster.crash()
        primary_cluster.start()
        primary_cluster.wait_ready()
        primary_cluster.execute("INSERT INTO post_crash SELECT generate_series(101,200)")
        count = primary_cluster.fetchone("SELECT COUNT(*) FROM post_crash")
        assert count == "200"


# ── pg_rewind ─────────────────────────────────────────────────────────────────


class TestPgRewind:
    def test_rewind_basic(self, replica_pair, tmp_path: Path, install_dir: Path, io_method: str):
        primary, standby = replica_pair
        primary.configure({"wal_log_hints": "on", "summarize_wal": "on"})
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
        primary.configure({"wal_log_hints": "on", "summarize_wal": "on"})
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


# ── relfilenode reuse ─────────────────────────────────────────────────────────


class TestRelfilenodeReuse:
    """
    Port of the upstream 032_relfilenode_reuse.pl test.
    Tests that a standby correctly handles relfilenode reuse when
    a template database is dropped and recreated with the same OID.
    """

    def test_relfilenode_reuse_with_template_db(self, replica_pair):
        primary, standby = replica_pair
        primary.configure({"hot_standby_feedback": "on"})
        primary.restart()

        # Create template DB and a database based on it
        primary.execute("CREATE DATABASE template_reuse TEMPLATE template0")
        primary.execute("CREATE TABLE public.shared_data (id INT) TABLESPACE pg_default",
                        dbname="template_reuse")
        primary.execute("INSERT INTO public.shared_data SELECT generate_series(1,100)",
                        dbname="template_reuse")
        primary.execute("CREATE DATABASE conflict_db TEMPLATE template_reuse")

        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Drop the template and recreate with same name (relfilenode reuse scenario)
        primary.execute("DROP DATABASE template_reuse")
        primary.execute("CREATE DATABASE template_reuse TEMPLATE template0")
        primary.execute("CREATE TABLE public.new_data (id INT)", dbname="template_reuse")
        primary.execute("INSERT INTO public.new_data SELECT generate_series(1,50)",
                        dbname="template_reuse")

        repl.assert_catchup(timeout=30)

        # Standby must be able to query both databases
        count = standby.fetchone("SELECT COUNT(*) FROM public.new_data", dbname="template_reuse")
        assert count == "50"
        count = standby.fetchone("SELECT COUNT(*) FROM public.shared_data", dbname="conflict_db")
        assert count == "100"

    def test_relfilenode_reuse_with_tde(self, tde_replica_pair):
        primary, standby = tde_replica_pair
        primary.execute("CREATE DATABASE reuse_enc TEMPLATE template0")
        primary.execute(
            "CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="reuse_enc"
        )
        # Each new database needs its own database-level principal key even
        # though the global key provider and server key are already configured.
        tde = TdeManager(primary)
        tde.set_global_principal_key(dbname="reuse_enc")
        primary.execute(
            "CREATE TABLE reuse_tbl (id INT)", dbname="reuse_enc"
        )
        primary.execute("INSERT INTO reuse_tbl SELECT generate_series(1,100)", dbname="reuse_enc")

        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        primary.execute("DROP DATABASE reuse_enc")
        primary.execute("CREATE DATABASE reuse_enc TEMPLATE template0")
        primary.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="reuse_enc")
        tde.set_global_principal_key(dbname="reuse_enc")
        primary.execute("CREATE TABLE new_tbl (id INT)", dbname="reuse_enc")
        primary.execute("INSERT INTO new_tbl SELECT generate_series(1,50)", dbname="reuse_enc")

        repl.assert_catchup(timeout=30)
        count = standby.fetchone("SELECT COUNT(*) FROM new_tbl", dbname="reuse_enc")
        assert count == "50"


# ── WAL utilities ─────────────────────────────────────────────────────────────


class TestWalUtilities:
    def test_pg_resetwal(self, pg_factory, tmp_path: Path, install_dir: Path):
        cluster = pg_factory("resetwal")
        cluster.initdb()
        cluster.write_default_config()
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        cluster.execute("CREATE TABLE resetwal_tbl (id INT)")
        cluster.execute("INSERT INTO resetwal_tbl SELECT generate_series(1,100)")
        cluster.stop()

        result = subprocess.run(
            [str(install_dir / "bin" / "pg_resetwal"), "-f", str(cluster.data_dir)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"pg_resetwal failed: {result.stderr}"
        cluster.start()
        cluster.wait_ready()
        cluster.stop()

    def test_pg_archivecleanup(self, primary_cluster: PgCluster, tmp_path: Path, install_dir: Path):
        archive_dir = tmp_path / "archive"
        archive_dir.mkdir()
        primary_cluster.configure(
            {
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": f"'cp %p {archive_dir}/%f'",
            }
        )
        primary_cluster.restart()
        primary_cluster.execute("SELECT pg_switch_wal()")
        primary_cluster.execute("CHECKPOINT")
        time.sleep(2)

        segments = list(archive_dir.iterdir())
        if not segments:
            pytest.skip("No WAL segments archived yet")

        last_seg = sorted(segments)[-1].name
        result = subprocess.run(
            [str(install_dir / "bin" / "pg_archivecleanup"),
             str(archive_dir), last_seg],
            capture_output=True, text=True,
        )
        assert result.returncode == 0

    def test_pg_receivewal(self, primary_cluster: PgCluster, tmp_path: Path, install_dir: Path):
        primary_cluster.configure(
            {"wal_level": "replica", "max_wal_senders": "5"}
        )
        primary_cluster.add_hba_entry("local replication all trust")
        primary_cluster.restart()

        receive_dir = tmp_path / "received_wal"
        receive_dir.mkdir()

        proc = subprocess.Popen(
            [
                str(install_dir / "bin" / "pg_receivewal"),
                "-h", str(primary_cluster.socket_dir),
                "-p", str(primary_cluster.port),
                "-D", str(receive_dir),
            ]
        )
        try:
            primary_cluster.execute("SELECT pg_switch_wal()")
            time.sleep(3)
            segments = list(receive_dir.iterdir())
            assert len(segments) > 0, "pg_receivewal produced no segments"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


# ── pg_tde_rewind: shared helpers ─────────────────────────────────────────────


def _pg_tde_rewind_bin(install_dir: Path) -> Path:
    """Return pg_tde_rewind if present, otherwise fall back to pg_rewind."""
    tde_bin = install_dir / "bin" / "pg_tde_rewind"
    return tde_bin if tde_bin.exists() else install_dir / "bin" / "pg_rewind"


def _run_pg_tde_rewind(
    install_dir: Path,
    target: PgCluster,
    source: PgCluster,
) -> subprocess.CompletedProcess:
    """
    Execute pg_tde_rewind with --source-pgdata (offline source).

    Both clusters must be stopped before calling this function.

    Use ``-c`` so rewind can fetch missing WAL via restore_command when the
    divergence point WAL has already been recycled from target pg_wal.
    """
    cmd = [
        str(_pg_tde_rewind_bin(install_dir)),
        "--target-pgdata", str(target.data_dir),
        "--source-pgdata", str(source.data_dir),
        "-c",
    ]
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    ld_var = "LD_LIBRARY_PATH"
    existing = env.get(ld_var, "")
    env[ld_var] = f"{lib_dir}:{existing}" if existing else lib_dir
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


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
    from conftest import allocate_port

    archive_dir = archive_dir or tmp_path / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    keyfile = keyfile or str(tmp_path / "keyring.file")

    primary = PgCluster(
        tmp_path / primary_subdir, allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
    )
    standby = PgCluster(
        tmp_path / standby_subdir, allocate_port(), install_dir,
        socket_dir=tmp_path, io_method=io_method,
    )

    primary.initdb(extra_args=["--no-data-checksums"])
    primary.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "wal_level": "replica",
        "archive_mode": "on",
        "archive_command": f"'cp %p {archive_dir}/%f'",
        # Needed by pg_tde_rewind -c when primary later becomes rewind target.
        "restore_command": f"'cp {archive_dir}/%f %p'",
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
        "restore_command": f"'cp {archive_dir}/%f %p'",
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
    from lib.cluster import libpq_superuser  # noqa: F401 — available here
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


def _reconnect_as_standby(rewound: PgCluster, new_primary: PgCluster) -> None:
    """After pg_rewind, configure the rewound server to stream from new_primary."""
    auto_conf = rewound.data_dir / "postgresql.auto.conf"
    with auto_conf.open("a") as f:
        f.write(
            f"primary_conninfo = 'host={new_primary.socket_dir} "
            f"port={new_primary.port} user={libpq_superuser()}'\n"
        )
    (rewound.data_dir / "standby.signal").touch()


# ── PR-428: pg_tde_rewind extended edge cases ─────────────────────────────────


@pytest.mark.slow
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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

            result = _run_pg_tde_rewind(install_dir, primary, standby)
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
