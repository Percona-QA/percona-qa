"""
pg_basebackup / pg_tde_basebackup tests.

Covers scenarios from:
  - pg_tde_basebackup.sh
  - pg_tde_pgbackrest_ha_failover_rebuild_test.sh (HA rebuild via basebackup only)
"""
import shutil
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import libpq_superuser
from lib.backup import PgBaseBackup


pytestmark = pytest.mark.backup


class TestPgBaseBackup:
    def test_basebackup_plain_cluster(self, primary_cluster: PgCluster, tmp_path: Path):
        primary_cluster.execute("CREATE TABLE bb_test (id INT)")
        primary_cluster.execute("INSERT INTO bb_test SELECT generate_series(1,100)")

        backup_dir = str(tmp_path / "basebackup")
        backup = PgBaseBackup(primary_cluster)
        backup.take(backup_dir)
        assert Path(backup_dir, "PG_VERSION").exists()

    def test_basebackup_with_tde(self, tde_primary: PgCluster, tmp_path: Path, install_dir: Path):
        tde_primary.execute("CREATE TABLE tde_bb_test (id INT)")
        tde_primary.execute("INSERT INTO tde_bb_test SELECT generate_series(1,100)")

        backup_dir = str(tmp_path / "tde_basebackup")
        tde = TdeManager(tde_primary)
        tde.tde_basebackup(backup_dir)
        assert Path(backup_dir, "PG_VERSION").exists()

    def test_restore_from_basebackup(self, primary_cluster: PgCluster, tmp_path: Path, install_dir: Path, io_method: str):
        primary_cluster.execute("CREATE TABLE restore_test (id INT, data TEXT)")
        primary_cluster.execute(
            "INSERT INTO restore_test SELECT i, md5(i::text) FROM generate_series(1,1000) i"
        )

        backup_dir = str(tmp_path / "backup")
        restore_dir = tmp_path / "restored"

        PgBaseBackup(primary_cluster).take(backup_dir)

        from conftest import allocate_port
        restore_port = allocate_port()
        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        shutil.copytree(backup_dir, str(restore_dir))
        restored.write_default_config()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready()

        count = restored.fetchone("SELECT COUNT(*) FROM restore_test")
        assert count == "1000"
        restored.stop()


class TestTdeHaFailoverRebuild:
    """Rebuild former primary as standby using pg_tde_basebackup (not pgBackRest)."""

    def test_ha_failover_and_rebuild(
        self, tde_replica_pair, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """Simulate HA failover: promote standby, rebuild old primary from backup."""
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE ha_test (id INT)")
        primary.execute("INSERT INTO ha_test SELECT generate_series(1,1000)")

        from lib import ReplicationManager
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Simulate primary failure; promote standby
        primary.stop()
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO ha_test SELECT generate_series(1001,2000)")

        # Rebuild old primary as new standby via basebackup from new primary
        shutil.rmtree(primary.data_dir)
        tde_new_primary = TdeManager(standby)
        tde_new_primary.tde_basebackup(str(primary.data_dir))
        primary.write_default_config("replica", extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        # Update primary_conninfo to point to new primary
        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} "
                f"user={libpq_superuser()}'\n"
            )
        primary.start()
        primary.wait_ready(timeout=60)

        repl2 = ReplicationManager(standby, primary)
        repl2.assert_catchup(timeout=60)
        count = primary.fetchone("SELECT COUNT(*) FROM ha_test")
        assert count == "2000"
