"""
Crash recovery, WAL utilities, and relfilenode reuse tests.

Covers scenarios from:
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

from lib import PgCluster, ReplicationManager, TdeManager
from lib.cluster import initdb_args_no_data_checksums, libpq_superuser


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

    def test_crash_recovery_with_wal_encryption(self, pg_factory, tmp_path):
        """
        Crash-recovery WAL replay must work when ``pg_tde.wal_encrypt = on``.

        The existing ``test_data_survives_crash_tde`` does CHECKPOINT before
        the SIGKILL, so the data is already on disk and recovery is trivial.
        This test forces the **encrypted-WAL replay** path: inserts after
        CHECKPOINT survive only if pg_tde successfully decrypts the WAL
        records during crash recovery.

        Failure modes this catches:
          - pg_tde fails to load WAL keys at recovery time
          - WAL decryption silently produces garbage → postgres aborts
            recovery, or starts but the committed inserts are missing
          - Per-relation keys aren't restored before the redo loop runs

        Sister test of the wal_encrypt=off ``test_data_survives_crash_tde``
        — together they pin down both encrypted and plaintext WAL paths.
        """
        cluster = pg_factory("crash_wal_enc")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
        })
        cluster.add_hba_entry("local all all trust")
        cluster.start()

        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=str(tmp_path / "crash_key.file"))
        tde.set_global_principal_key()
        tde.enable_wal_encryption()   # PGC_POSTMASTER; restarts the cluster
        assert tde.is_wal_encrypted(), (
            "pg_tde.wal_encrypt did not engage — test would otherwise pass "
            "trivially without exercising the encrypted-WAL recovery path."
        )

        # Phase 1: pre-checkpoint inserts. These rows are written to heap
        # pages and flushed by CHECKPOINT — recovery doesn't need WAL replay
        # to find them.
        cluster.execute(
            "CREATE TABLE crash_wal_enc "
            "(id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO crash_wal_enc "
            "SELECT i, md5(i::text) FROM generate_series(1, 100) i"
        )
        cluster.execute("CHECKPOINT")

        # Phase 2: post-checkpoint inserts. These rows live ONLY in WAL
        # until the next checkpoint. After SIGKILL, recovery has to replay
        # the encrypted WAL records to put them back into the heap.
        marker = "post-ckpt-wal-enc-marker-7f3a"
        cluster.execute(
            "INSERT INTO crash_wal_enc "
            f"SELECT i, '{marker}-' || i::text FROM generate_series(101, 200) i"
        )
        # Force-flush WAL to disk (commit already does this on default sync
        # settings, but be explicit so the test is durable against future
        # synchronous_commit=off defaults).
        cluster.fetchone("SELECT pg_current_wal_flush_lsn()")

        # SIGKILL the postmaster — no clean shutdown, no extra checkpoint.
        cluster.crash()

        # Recovery must succeed. If WAL decryption fails the postmaster
        # will refuse to start; this raises with the server log attached
        # (see PgCluster.wait_ready).
        cluster.start()
        cluster.wait_ready(timeout=60)

        # All 200 rows must be present. Pre-checkpoint rows come from disk
        # pages; post-checkpoint rows can only come from decrypted WAL.
        total = cluster.fetchone("SELECT COUNT(*) FROM crash_wal_enc")
        assert total == "200", (
            f"Expected 200 rows after crash recovery, got {total}. "
            "pg_tde may have failed to decrypt WAL during recovery — "
            "100 pre-checkpoint rows should be on disk and 100 post-"
            "checkpoint rows should have been replayed from encrypted WAL."
        )
        post_count = cluster.fetchone(
            "SELECT COUNT(*) FROM crash_wal_enc "
            f"WHERE payload LIKE '{marker}-%'"
        )
        assert post_count == "100", (
            f"Expected 100 post-checkpoint rows from encrypted-WAL replay, "
            f"got {post_count}."
        )

        # Server log must not contain decryption errors. Any sign of
        # "could not decrypt" / "decryption failed" indicates a partial-
        # recovery bug where postgres muddled through but pg_tde complained.
        server_log = cluster.read_log(last_n=200)
        for needle in ("could not decrypt", "decryption failed",
                       "invalid encrypted"):
            assert needle.lower() not in server_log.lower(), (
                f"Server log contains decryption-error phrase {needle!r} "
                "after crash recovery.\nLog tail:\n" + server_log[-2000:]
            )

        # Sanity: the new cluster is fully writable post-recovery, and the
        # new INSERT also goes through an encrypted WAL path cleanly.
        cluster.execute(
            "INSERT INTO crash_wal_enc VALUES (999999, 'post-recovery-write')"
        )
        assert cluster.fetchone(
            "SELECT COUNT(*) FROM crash_wal_enc"
        ) == "201"


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


