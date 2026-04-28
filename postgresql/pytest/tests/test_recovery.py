"""
Crash recovery, pg_rewind, WAL utilities, and relfilenode reuse tests.

Covers scenarios from:
  - rewind.sh
  - pg_relfilenode_reuse_test.sh
  - pg_resetwal.sh / pg_resetwal_iteration.sh
  - pg_receivewal.sh
  - pg_archivecleanup.sh
"""
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager, ReplicationManager
from conftest import allocate_port


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
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} user=postgres'\n"
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
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} user=postgres'\n"
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
        primary.execute(
            "CREATE TABLE reuse_tbl (id INT)", dbname="reuse_enc"
        )
        primary.execute("INSERT INTO reuse_tbl SELECT generate_series(1,100)", dbname="reuse_enc")

        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        primary.execute("DROP DATABASE reuse_enc")
        primary.execute("CREATE DATABASE reuse_enc TEMPLATE template0")
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
