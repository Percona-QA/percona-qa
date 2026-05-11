"""
Point-in-time recovery (PITR) via WAL archive + restore_command.

This is not the same as ``test_pg_basebackup.py`` (filesystem basebackup) or
``test_pgbackrest.py`` (external backup tool): PITR replays archived WAL to a
timestamp target after restoring a **data-directory copy**, which exercises
``recovery_target_time``, ``restore_command``, and (for TDE) decrypt wrappers.

Covers scenarios from:
  - pg_tde_restore_encrypt_using_archive_decrypt.sh
  - pitr_encrypted_wal.sh
"""
import shutil
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager, archive_restore_conf_values, restore_conf_line_raw


pytestmark = pytest.mark.backup


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
        pitr_time = (primary_cluster.fetchone("SELECT now()") or "").strip()
        time.sleep(1)
        primary_cluster.execute("DROP TABLE pitr_tbl")
        primary_cluster.execute("CHECKPOINT")
        primary_cluster.execute("SELECT pg_switch_wal()")
        primary_cluster.stop()

        from conftest import allocate_port
        restore_port = allocate_port()
        restore_dir = tmp_path / "pitr_restore"
        shutil.copytree(str(primary_cluster.data_dir), str(restore_dir))

        restored = PgCluster(restore_dir, restore_port, install_dir,
                             socket_dir=tmp_path, io_method=io_method)
        restored.write_default_config()
        recovery_conf = restore_dir / "postgresql.auto.conf"
        # Do not append: the copy still carries the primary's postgresql.auto.conf ALTER
        # SYSTEM lines (archive_command, etc.) which can break recovery on the new port.
        with recovery_conf.open("w") as f:
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
        arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        tde_primary.configure(
            {
                "archive_mode": "on",
                "archive_command": arch_cmd,
            }
        )
        tde_primary.restart()

        tde_primary.execute("CREATE TABLE pitr_enc_tbl (id INT)")
        tde_primary.execute("INSERT INTO pitr_enc_tbl SELECT generate_series(1,100)")
        pitr_time = (tde_primary.fetchone("SELECT now()") or "").strip()
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
        restored.write_default_config(
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            }
        )
        auto_conf = restore_dir / "postgresql.auto.conf"
        with auto_conf.open("w") as f:
            # Replacing the copied primary auto.conf drops ALTER SYSTEM lines; WAL decrypt
            # during recovery still requires this (same as TdeManager.enable_wal_encryption).
            f.write("pg_tde.wal_encrypt = 'on'\n")
            f.write(f"recovery_target_time = '{pitr_time}'\n")
            f.write("recovery_target_action = 'promote'\n")
            f.write(restore_conf_line_raw(archive_dir, install_dir, use_tde_wrappers=True))
        (restore_dir / "recovery.signal").touch()
        restored.add_hba_entry("local all all trust")
        restored.start()
        restored.wait_ready(timeout=60)

        count = restored.fetchone("SELECT COUNT(*) FROM pitr_enc_tbl")
        assert count == "100"
        restored.stop()
