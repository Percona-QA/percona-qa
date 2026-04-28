"""
Backup and PITR tests.

Covers scenarios from:
  - pg_tde_basebackup.sh
  - pg_tde_pgbackrest_backup_restore_matrix_test.sh
  - pg_tde_pgbackrest_ha_failover_rebuild_test.sh
  - pg_tde_restore_encrypt_using_archive_decrypt.sh
  - pitr_encrypted_wal.sh
"""
import shutil
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager, BackupManager
from lib.backup import PgBaseBackup


pytestmark = pytest.mark.backup


# ── pg_basebackup ─────────────────────────────────────────────────────────────


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


# ── pgBackRest ────────────────────────────────────────────────────────────────


@pytest.mark.slow
class TestPgBackRest:
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

    def test_backup_with_tde(self, tde_primary: PgCluster, tmp_path: Path):
        tde_primary.execute("CREATE TABLE tde_pgbr_test (id INT, secret TEXT)")
        tde_primary.execute(
            "INSERT INTO tde_pgbr_test SELECT i, md5(i::text) FROM generate_series(1,1000) i"
        )

        bm = BackupManager(stanza="tde_test", repo_path=str(tmp_path / "repo"))
        bm.write_config(
            pg_path=str(tde_primary.data_dir),
            pg_port=tde_primary.port,
            pg_socket_path=str(tde_primary.socket_dir),
        )
        bm.configure_postgres(tde_primary)
        tde_primary.restart()
        bm.stanza_create()
        bm.backup()
        info = bm.info()
        assert "full" in info.lower()

    def test_ha_failover_and_rebuild(
        self, tde_replica_pair, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """Simulate HA failover: promote standby, rebuild old primary from backup."""
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE ha_test (id INT)")
        primary.execute("INSERT INTO ha_test SELECT generate_series(1,1000)")

        from lib import ReplicationManager
        repl = ReplicationManager(primary, standby)
        assert repl.wait_for_catchup(timeout=30)

        # Simulate primary failure; promote standby
        primary.stop()
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO ha_test SELECT generate_series(1001,2000)")

        # Rebuild old primary as new standby via basebackup from new primary
        shutil.rmtree(primary.data_dir)
        tde_new_primary = TdeManager(standby)
        tde_new_primary.tde_basebackup(str(primary.data_dir))
        primary.write_default_config("replica")
        # Update primary_conninfo to point to new primary
        auto_conf = primary.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(
                f"primary_conninfo = 'host={standby.socket_dir} port={standby.port} user=postgres'\n"
            )
        primary.start()
        primary.wait_ready(timeout=60)

        repl2 = ReplicationManager(standby, primary)
        assert repl2.wait_for_catchup(timeout=60)
        count = primary.fetchone("SELECT COUNT(*) FROM ha_test")
        assert count == "2000"


# ── PITR ──────────────────────────────────────────────────────────────────────


@pytest.mark.slow
class TestPitr:
    def test_pitr_plain(self, primary_cluster: PgCluster, tmp_path: Path,
                        install_dir: Path, io_method: str):
        """Point-in-time recovery to a checkpoint before a DROP TABLE."""
        archive_dir = tmp_path / "wal_archive"
        archive_dir.mkdir()
        primary_cluster.configure(
            {
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": f"'cp %p {archive_dir}/%f'",
            }
        )
        primary_cluster.restart()

        primary_cluster.execute("CREATE TABLE pitr_tbl (id INT)")
        primary_cluster.execute("INSERT INTO pitr_tbl SELECT generate_series(1,100)")
        pitr_time = primary_cluster.fetchone("SELECT now()")
        time.sleep(1)
        primary_cluster.execute("DROP TABLE pitr_tbl")
        primary_cluster.stop()

        from conftest import allocate_port
        restore_port = allocate_port()
        restore_dir = tmp_path / "pitr_restore"
        shutil.copytree(str(primary_cluster.data_dir), str(restore_dir))

        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        restored.write_default_config()
        recovery_conf = restore_dir / "postgresql.auto.conf"
        with recovery_conf.open("a") as f:
            f.write(f"recovery_target_time = '{pitr_time}'\n")
            f.write("recovery_target_action = 'promote'\n")
            f.write(f"restore_command = 'cp {archive_dir}/%f %p'\n")
        (restore_dir / "recovery.signal").touch()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready(timeout=60)

        count = restored.fetchone("SELECT COUNT(*) FROM pitr_tbl")
        assert count == "100"
        restored.stop()

    def test_pitr_encrypted_wal(self, tde_primary: PgCluster, tmp_path: Path,
                                install_dir: Path, io_method: str):
        """PITR with WAL encryption enabled."""
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()

        archive_dir = tmp_path / "enc_wal_archive"
        archive_dir.mkdir()
        tde_primary.configure(
            {
                "archive_mode": "on",
                "archive_command": f"'cp %p {archive_dir}/%f'",
            }
        )
        tde_primary.restart()

        tde_primary.execute("CREATE TABLE pitr_enc_tbl (id INT)")
        tde_primary.execute("INSERT INTO pitr_enc_tbl SELECT generate_series(1,100)")
        pitr_time = tde_primary.fetchone("SELECT now()")
        time.sleep(1)
        tde_primary.execute("DROP TABLE pitr_enc_tbl")
        tde_primary.execute("SELECT pg_switch_wal()")
        tde_primary.stop()

        from conftest import allocate_port
        restore_port = allocate_port()
        restore_dir = tmp_path / "pitr_enc_restore"
        shutil.copytree(str(tde_primary.data_dir), str(restore_dir))

        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        restored.write_default_config()
        auto_conf = restore_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(f"recovery_target_time = '{pitr_time}'\n")
            f.write("recovery_target_action = 'promote'\n")
            f.write(f"restore_command = 'cp {archive_dir}/%f %p'\n")
        (restore_dir / "recovery.signal").touch()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready(timeout=60)

        count = restored.fetchone("SELECT COUNT(*) FROM pitr_enc_tbl")
        assert count == "100"
        restored.stop()
