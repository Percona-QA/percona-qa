"""pg_tde extension management with runtime API version detection."""
import logging
import subprocess
from typing import Dict, Optional

from .cluster import PgCluster

log = logging.getLogger(__name__)


class TdeManager:
    """
    Handles pg_tde setup and key management.

    pg_tde function signatures vary across minor releases.  All calls go
    through _sql() which probes the real argument list once and picks the
    right form automatically.
    """

    def __init__(self, cluster: PgCluster) -> None:
        self.cluster = cluster
        self._func_args: Dict[str, int] = {}   # cache: func_name → pronargs

    # ── internal helpers ──────────────────────────────────────────────────

    def _nargs(self, func_name: str) -> int:
        """Return pronargs for func_name (after CREATE EXTENSION)."""
        if func_name not in self._func_args:
            result = self.cluster.fetchone(
                f"SELECT pronargs FROM pg_proc "
                f"WHERE proname = '{func_name}' LIMIT 1"
            )
            self._func_args[func_name] = int(result) if result else -1
        return self._func_args[func_name]

    def _has_func(self, func_name: str) -> bool:
        return self._nargs(func_name) >= 0

    # ── configuration ─────────────────────────────────────────────────────

    def enable_preload(self) -> None:
        self.cluster.configure({"shared_preload_libraries": "'pg_tde'"})

    def enable_tde_heap(self) -> None:
        self.cluster.configure({"default_table_access_method": "'tde_heap'"})

    def create_extension(self, dbname: str = "postgres") -> None:
        self.cluster.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname)
        self._func_args.clear()   # flush cache after extension is created

    # ── key providers ─────────────────────────────────────────────────────

    def _first_func(self, candidates: list) -> Optional[str]:
        """Return the first function name from candidates that exists in pg_proc."""
        for fn in candidates:
            if self._nargs(fn) >= 0:
                return fn
        return None

    def available_functions(self) -> list:
        """Return all pg_tde function names visible in pg_proc (useful for debugging)."""
        rows = self.cluster.fetchall(
            "SELECT proname FROM pg_proc WHERE proname LIKE 'pg_tde%' ORDER BY proname"
        )
        return rows

    def add_global_key_provider_file(
        self,
        provider_name: str = "file_provider",
        keyfile: str = "/tmp/pg_tde_test.per",
        *,
        in_place: bool = True,
    ) -> None:
        fn = self._first_func([
            "pg_tde_add_global_key_provider_file",
            "pg_tde_add_key_provider_file",
        ])
        if fn is None:
            raise RuntimeError("No pg_tde add_key_provider_file function found in pg_proc")
        nargs = self._nargs(fn)
        if nargs == 3:
            sql = (f"SELECT {fn}('{provider_name}'::text, '{keyfile}'::text, "
                   f"{'true' if in_place else 'false'})")
        else:
            sql = f"SELECT {fn}('{provider_name}'::text, '{keyfile}'::text)"
        self.cluster.execute(sql)

    def add_global_key_provider_vault(
        self,
        provider_name: str = "vault_provider",
        vault_url: str = "",
        secret_mount_point: str = "secret",
        vault_token: str = "",
        ca_path: str = "",
    ) -> None:
        fn = self._first_func([
            "pg_tde_add_global_key_provider_vault_v2",
            "pg_tde_add_global_key_provider_vault",
            "pg_tde_add_key_provider_vault_v2",
            "pg_tde_add_key_provider_vault",
        ])
        if fn is None:
            raise RuntimeError("No pg_tde add_key_provider_vault function found in pg_proc")
        sql = (f"SELECT {fn}('{provider_name}'::text, '{vault_url}'::text, "
               f"'{secret_mount_point}'::text, '{vault_token}'::text, '{ca_path}'::text)")
        self.cluster.execute(sql)

    def set_global_principal_key(
        self,
        key_name: str = "test_key",
        provider_name: str = "file_provider",
        dbname: str = "postgres",
    ) -> None:
        """
        Create and activate encryption keys.

        Current Percona pg_tde API (two-step per key):
          pg_tde_create_key_using_global_key_provider(key, provider)
          pg_tde_set_server_key_using_global_key_provider(key, provider)  -- WAL / server
          pg_tde_set_key_using_global_key_provider(key, provider)         -- per-database tables
        """
        create_fn = self._first_func(["pg_tde_create_key_using_global_key_provider"])
        server_fn = self._first_func(["pg_tde_set_server_key_using_global_key_provider"])
        db_fn = self._first_func(["pg_tde_set_key_using_global_key_provider"])

        if create_fn and (server_fn or db_fn):
            self.cluster.execute(
                f"SELECT {create_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
            )
            if server_fn:
                self.cluster.execute(
                    f"SELECT {server_fn}('{key_name}'::text, '{provider_name}'::text)"
                )
            if db_fn:
                self.cluster.execute(
                    f"SELECT {db_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
                )
            return

        # Legacy API fallback (older pg_tde releases)
        fn = self._first_func([
            "pg_tde_set_global_principal_key",
            "pg_tde_set_server_principal_key",
            "pg_tde_set_principal_key",
        ])
        if fn is None:
            raise RuntimeError(
                f"No pg_tde set_principal_key function found. "
                f"Available: {self.available_functions()}"
            )
        nargs = self._nargs(fn)
        if nargs == 1:
            sql = f"SELECT {fn}('{key_name}'::text)"
        else:
            sql = f"SELECT {fn}('{key_name}'::text, '{provider_name}'::text)"
        self.cluster.execute(sql, dbname)

    def rotate_principal_key(
        self,
        new_key_name: str = "test_key_rotated",
        provider_name: str = "file_provider",
        dbname: str = "postgres",
    ) -> None:
        """Create a new key and promote it to active for server and database."""
        create_fn = self._first_func(["pg_tde_create_key_using_global_key_provider"])
        server_fn = self._first_func(["pg_tde_set_server_key_using_global_key_provider"])
        db_fn = self._first_func(["pg_tde_set_key_using_global_key_provider"])

        if create_fn and (server_fn or db_fn):
            self.cluster.execute(
                f"SELECT {create_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
            )
            if server_fn:
                self.cluster.execute(
                    f"SELECT {server_fn}('{new_key_name}'::text, '{provider_name}'::text)"
                )
            if db_fn:
                self.cluster.execute(
                    f"SELECT {db_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
                )
            return

        # Legacy API fallback
        fn = self._first_func([
            "pg_tde_rotate_principal_key",
            "pg_tde_rotate_global_principal_key",
        ])
        if fn is None:
            raise RuntimeError(
                f"No pg_tde rotate_principal_key function found. "
                f"Available: {self.available_functions()}"
            )
        nargs = self._nargs(fn)
        if nargs == 0:
            sql = f"SELECT {fn}()"
        elif nargs == 1:
            sql = f"SELECT {fn}('{new_key_name}'::text)"
        else:
            sql = f"SELECT {fn}('{new_key_name}'::text, '{provider_name}'::text)"
        self.cluster.execute(sql, dbname)

    # ── WAL encryption ────────────────────────────────────────────────────

    def enable_wal_encryption(self) -> None:
        self.cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = 'on'")
        self.cluster.execute("SELECT pg_reload_conf()")

    def disable_wal_encryption(self) -> None:
        self.cluster.execute("ALTER SYSTEM RESET pg_tde.wal_encrypt")
        self.cluster.execute("SELECT pg_reload_conf()")

    def is_wal_encrypted(self) -> bool:
        try:
            val = self.cluster.fetchone("SHOW pg_tde.wal_encrypt")
            return val in ("on", "true", "1", "yes")
        except RuntimeError:
            return False

    # ── encryption state queries ──────────────────────────────────────────

    def is_table_encrypted(self, table: str, dbname: str = "postgres") -> bool:
        for fn in ("pg_tde_is_encrypted", "pg_tde_is_encrypted_rel"):
            if self._has_func(fn):
                val = self.cluster.fetchone(f"SELECT {fn}('{table}'::text)", dbname)
                return val in ("t", "true", "on", "1")
        return False

    def get_access_method(self, table: str, dbname: str = "postgres") -> str:
        return self.cluster.fetchone(
            f"SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            f"WHERE c.relname = '{table}'",
            dbname,
        )

    def list_key_providers(self) -> int:
        """Return the count of registered key providers."""
        for fn in (
            "pg_tde_list_key_providers",
            "pg_tde_key_providers",
            "pg_tde_list_global_key_providers",
        ):
            if self._has_func(fn):
                result = self.cluster.fetchone(f"SELECT COUNT(*) FROM {fn}()")
                return int(result) if result else 0
        return 0

    def principal_key_name(self) -> Optional[str]:
        for fn in (
            "pg_tde_get_key_info",
            "pg_tde_key_info",
            "pg_tde_principal_key_info",
            "pg_tde_get_principal_key_info",
        ):
            if self._has_func(fn):
                return self.cluster.fetchone(f"SELECT key_name FROM {fn}()")
        return None

    # ── basebackup with TDE ───────────────────────────────────────────────

    def tde_basebackup(self, target_dir: str, extra_args=None) -> None:
        bin_path = self.cluster.bin / "pg_tde_basebackup"
        if not bin_path.exists():
            # Fall back to standard pg_basebackup if tde variant not present
            log.warning("pg_tde_basebackup not found, using pg_basebackup")
            self.cluster.basebackup(target_dir, extra_args)
            return
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
