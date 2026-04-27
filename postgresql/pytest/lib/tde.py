"""pg_tde extension management."""
import logging
import subprocess
from pathlib import Path
from typing import Optional

from .cluster import PgCluster

log = logging.getLogger(__name__)


class TdeManager:
    """Handles pg_tde setup, key management, and encryption state queries."""

    def __init__(self, cluster: PgCluster) -> None:
        self.cluster = cluster

    # ── configuration ─────────────────────────────────────────────────────

    def enable_preload(self) -> None:
        """Add pg_tde to shared_preload_libraries (before first start)."""
        self.cluster.configure({"shared_preload_libraries": "'pg_tde'"})

    def enable_tde_heap(self) -> None:
        """Set default_table_access_method to tde_heap."""
        self.cluster.configure({"default_table_access_method": "'tde_heap'"})

    def create_extension(self, dbname: str = "postgres") -> None:
        self.cluster.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname)

    # ── key providers ─────────────────────────────────────────────────────

    def add_global_key_provider_file(
        self,
        provider_name: str = "file_provider",
        keyfile: str = "/tmp/pg_tde_test.per",
        *,
        in_place: bool = True,
    ) -> None:
        sql = (
            f"SELECT pg_tde_add_global_key_provider_file("
            f"'{provider_name}', '{keyfile}', {'true' if in_place else 'false'})"
        )
        self.cluster.execute(sql)

    def add_global_key_provider_vault(
        self,
        provider_name: str = "vault_provider",
        vault_url: str = "",
        secret_mount_point: str = "secret",
        vault_token: str = "",
        ca_path: str = "",
    ) -> None:
        sql = (
            f"SELECT pg_tde_add_global_key_provider_vault_v2("
            f"'{provider_name}', '{vault_url}', '{secret_mount_point}', '{vault_token}', '{ca_path}')"
        )
        self.cluster.execute(sql)

    def set_global_principal_key(
        self,
        key_name: str = "test_key",
        provider_name: str = "file_provider",
        dbname: str = "postgres",
    ) -> None:
        self.cluster.execute(
            f"SELECT pg_tde_set_global_principal_key('{key_name}', '{provider_name}')",
            dbname,
        )

    def rotate_principal_key(
        self,
        new_key_name: str = "test_key_rotated",
        provider_name: str = "file_provider",
        dbname: str = "postgres",
    ) -> None:
        self.cluster.execute(
            f"SELECT pg_tde_rotate_principal_key('{new_key_name}', '{provider_name}')",
            dbname,
        )

    # ── WAL encryption ────────────────────────────────────────────────────

    def enable_wal_encryption(self) -> None:
        self.cluster.execute("SELECT pg_tde_enable_wal_encryption()")

    def disable_wal_encryption(self) -> None:
        self.cluster.execute("SELECT pg_tde_disable_wal_encryption()")

    def is_wal_encrypted(self) -> bool:
        val = self.cluster.fetchone("SELECT pg_tde_is_wal_encryption_enabled()")
        return val == "t"

    # ── encryption state queries ──────────────────────────────────────────

    def is_table_encrypted(self, table: str, dbname: str = "postgres") -> bool:
        val = self.cluster.fetchone(
            f"SELECT pg_tde_is_encrypted('{table}')", dbname
        )
        return val == "t"

    def get_access_method(self, table: str, dbname: str = "postgres") -> str:
        return self.cluster.fetchone(
            f"SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            f"WHERE c.relname = '{table}'",
            dbname,
        )

    # ── basebackup with TDE ───────────────────────────────────────────────

    def tde_basebackup(self, target_dir: str, extra_args=None) -> None:
        """Use pg_tde_basebackup instead of standard pg_basebackup."""
        bin_path = self.cluster.bin / "pg_tde_basebackup"
        cmd = [
            str(bin_path),
            "-h", str(self.cluster.socket_dir),
            "-p", str(self.cluster.port),
            "-D", target_dir,
            "-R", "--checkpoint=fast",
        ]
        if extra_args:
            cmd.extend(extra_args)
        subprocess.run(cmd, check=True)
        log.info("pg_tde_basebackup completed to %s", target_dir)

    # ── convenience: full setup ───────────────────────────────────────────

    def full_setup(
        self,
        key_name: str = "test_key",
        keyfile: str = "/tmp/pg_tde_test.per",
        dbname: str = "postgres",
        *,
        enable_wal_enc: bool = False,
        set_tde_heap: bool = True,
    ) -> None:
        """Enable pg_tde, create extension, set up file key provider and principal key."""
        self.enable_preload()
        if set_tde_heap:
            self.enable_tde_heap()
        self.cluster.restart()
        self.create_extension(dbname)
        self.add_global_key_provider_file(keyfile=keyfile)
        self.set_global_principal_key(key_name, dbname=dbname)
        if enable_wal_enc:
            self.enable_wal_encryption()
        log.info("pg_tde fully configured on port %d", self.cluster.port)
