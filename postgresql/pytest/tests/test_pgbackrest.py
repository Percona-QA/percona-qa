"""
pgBackRest integration tests.

Covers scenarios from:
  - pg_tde_pgbackrest_backup_restore_matrix_test.sh
"""
from pathlib import Path

import pytest

from lib import BackupManager, PgCluster, TdeManager


pytestmark = pytest.mark.backup


@pytest.mark.slow
class TestPgBackRest:
    @pytest.mark.pgbackrest
    def test_full_backup_and_restore(self, primary_cluster: PgCluster, tmp_path: Path,
                                     install_dir: Path, io_method: str):
        primary_cluster.execute("CREATE TABLE pgbr_test (id INT, data TEXT)")
        primary_cluster.execute(
            "INSERT INTO pgbr_test SELECT i, md5(i::text) FROM generate_series(1,5000) i"
        )

        bm = BackupManager(stanza="full_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary_cluster.data_dir),
            pg_port=primary_cluster.port,
            pg_socket_path=str(primary_cluster.socket_dir),
        )
        bm.configure_postgres(primary_cluster)
        primary_cluster.restart()  # apply archive settings
        bm.stanza_create()
        bm.backup(backup_type="full")

        restore_dir = tmp_path / "pgbr_restore"
        from conftest import allocate_port
        restore_port = allocate_port()
        bm.restore(str(restore_dir))

        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        restored.write_default_config()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready()
        count = restored.fetchone("SELECT COUNT(*) FROM pgbr_test")
        assert count == "5000"
        restored.stop()

    @pytest.mark.pgbackrest
    def test_incremental_backup(self, primary_cluster: PgCluster, tmp_path: Path):
        bm = BackupManager(stanza="incr_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(primary_cluster.data_dir),
            pg_port=primary_cluster.port,
            pg_socket_path=str(primary_cluster.socket_dir),
        )
        bm.configure_postgres(primary_cluster)
        primary_cluster.restart()

        bm.stanza_create()
        bm.backup(backup_type="full")

        primary_cluster.execute("CREATE TABLE incr_data (id INT)")
        primary_cluster.execute("INSERT INTO incr_data SELECT generate_series(1,1000)")
        bm.backup(backup_type="incr")

        info = bm.info()
        assert "incr" in info.lower()

    @pytest.mark.pgbackrest
    def test_backup_with_tde(
        self,
        tde_primary: PgCluster,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        pgBackRest + pg_tde: WAL encryption on, archive via pg_tde_archive_decrypt,
        restore via pg_tde_restore_encrypt (Percona walkthrough).
        """
        tde_primary.execute("CREATE TABLE tde_pgbr_test (id INT, secret TEXT)")
        tde_primary.execute(
            "INSERT INTO tde_pgbr_test SELECT i, md5(i::text) FROM generate_series(1,1000) i"
        )

        TdeManager(tde_primary).enable_wal_encryption()

        bm = BackupManager(stanza="tde_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(tde_primary.data_dir),
            pg_port=tde_primary.port,
            pg_socket_path=str(tde_primary.socket_dir),
            pg_bin=str(tde_primary.bin),
        )
        bm.configure_postgres(tde_primary, pg_tde_wal_archiving=True)
        tde_primary.restart()
        bm.stanza_create()
        tde_primary.execute("CHECKPOINT")
        tde_primary.execute("SELECT pg_switch_wal()")
        bm.backup()
        info = bm.info()
        assert "full" in info.lower()

        restore_dir = tmp_path / "tde_pgbr_restore"
        from conftest import allocate_port

        restore_port = allocate_port()
        bm.restore(str(restore_dir), pg_tde_wal_restore=True)

        restored = PgCluster(
            restore_dir, restore_port, install_dir, socket_dir=tmp_path, io_method=io_method
        )
        restored.write_default_config(
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            }
        )
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready(timeout=120)

        count = restored.fetchone("SELECT COUNT(*) FROM tde_pgbr_test")
        assert count == "1000"
        restored.stop()
