"""pg_tde extension management with runtime API version detection."""
import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Dict, Optional, Tuple, Union

from .cluster import PgCluster, libpq_superuser

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
        """Return pronargs for func_name (after CREATE EXTENSION).

        pg_tde 2.1+ adds a 6-arg ``*_vault_v2`` overload (namespace) alongside
        the original 5-arg form.  Always pick the highest arity so OpenBao tests
        pass ``pg_tde_ns1/`` — using the 5-arg overload omits
        ``X-Vault-Namespace`` and yields HTTP 404 on create_key.
        """
        if func_name not in self._func_args:
            result = self.cluster.fetchone(
                f"SELECT pronargs FROM pg_proc "
                f"WHERE proname = '{func_name}' "
                f"ORDER BY pronargs DESC LIMIT 1"
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

    def _execute_create_global_key_allow_duplicate(self, sql: str, dbname: str = "postgres") -> None:
        """Run pg_tde_create_key_using_* ; succeed if the key material already exists in the provider."""
        try:
            self.cluster.execute(sql, dbname)
        except RuntimeError as e:
            err = str(e).lower()
            if "already exists" in err:
                log.debug("pg_tde create_key skipped (already exists): %s", sql[:200])
                return
            raise

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

    def add_database_key_provider_file(
        self,
        provider_name: str,
        keyfile: str,
        *,
        in_place: bool = True,
        dbname: str = "postgres",
    ) -> None:
        fn = self._first_func([
            "pg_tde_add_database_key_provider_file",
            "pg_tde_add_key_provider_file",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde_add_database_key_provider_file function found in pg_proc"
            )
        nargs = self._nargs(fn)
        if nargs == 3:
            sql = (
                f"SELECT {fn}('{provider_name}'::text, '{keyfile}'::text, "
                f"{'true' if in_place else 'false'})"
            )
        else:
            sql = f"SELECT {fn}('{provider_name}'::text, '{keyfile}'::text)"
        self.cluster.execute(sql, dbname)

    def _sql_add_vault_v2_provider(
        self,
        fn: str,
        provider_name: str,
        vault_url: str,
        secret_mount_point: str,
        token_arg: str,
        ca_path: str,
        namespace: str,
        dbname: str = "postgres",
    ) -> None:
        """``vault_v2`` SQL: url, mount, token_path, ca, optional namespace."""
        def esc(s: str) -> str:
            return s.replace("'", "''")

        provider_name = esc(provider_name)
        vault_url = esc(vault_url)
        secret_mount_point = esc(secret_mount_point)
        token_arg = esc(token_arg)
        ca_sql = "NULL" if not ca_path else f"'{esc(ca_path)}'::text"
        namespace = esc(namespace) if namespace else ""
        nargs = self._nargs(fn)

        if namespace and nargs < 6:
            raise RuntimeError(
                f"{fn} has pronargs={nargs} but namespace "
                f"'{namespace}' was requested — upgrade pg_tde to 2.1+ "
                f"(6-arg vault_v2 with namespace support)"
            )

        if nargs >= 6:
            ns_sql = f"'{namespace}'::text" if namespace else "NULL"
            sql = (
                f"SELECT {fn}('{provider_name}'::text, '{vault_url}'::text, "
                f"'{secret_mount_point}'::text, '{token_arg}'::text, "
                f"{ca_sql}, {ns_sql})"
            )
        elif nargs >= 5:
            sql = (
                f"SELECT {fn}('{provider_name}'::text, '{vault_url}'::text, "
                f"'{secret_mount_point}'::text, '{token_arg}'::text, {ca_sql})"
            )
        else:
            raise RuntimeError(
                f"{fn} has unexpected pronargs={nargs} (expected 5 or 6)"
            )
        self.cluster.execute(sql, dbname)

    def add_global_key_provider_vault(
        self,
        provider_name: str = "vault_provider",
        vault_url: str = "",
        secret_mount_point: str = "secret",
        vault_token: str = "",
        ca_path: str = "",
        *,
        token_path: str = "",
        namespace: str = "",
        dbname: str = "postgres",
    ) -> None:
        """
        Register a global Vault/OpenBao provider (``vault_v2`` API).

        Pass either ``vault_token`` (inline) or ``token_path`` (file). Bash
        automation uses a token file path as the 4th argument.
        """
        fn = self._first_func([
            "pg_tde_add_global_key_provider_vault_v2",
            "pg_tde_add_global_key_provider_vault",
            "pg_tde_add_key_provider_vault_v2",
            "pg_tde_add_key_provider_vault",
        ])
        if fn is None:
            raise RuntimeError("No pg_tde add_key_provider_vault function found in pg_proc")
        token_arg = token_path or vault_token
        if "vault_v2" in fn or fn.endswith("_vault_v2"):
            self._sql_add_vault_v2_provider(
                fn,
                provider_name,
                vault_url,
                secret_mount_point,
                token_arg,
                ca_path,
                namespace,
                dbname=dbname,
            )
            return
        def esc(s: str) -> str:
            return s.replace("'", "''")

        sql = (
            f"SELECT {fn}('{esc(provider_name)}'::text, "
            f"'{esc(vault_url)}'::text, "
            f"'{esc(secret_mount_point)}'::text, "
            f"'{esc(token_arg)}'::text, "
            f"'{esc(ca_path)}'::text)"
        )
        self.cluster.execute(sql, dbname)

    def add_database_key_provider_vault(
        self,
        provider_name: str,
        *,
        vault_url: str,
        secret_mount_point: str = "secret",
        vault_token: str = "",
        token_path: str = "",
        ca_path: str = "",
        namespace: str = "",
        dbname: str = "postgres",
    ) -> None:
        fn = self._first_func([
            "pg_tde_add_database_key_provider_vault_v2",
            "pg_tde_add_database_key_provider_vault",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde_add_database_key_provider_vault_v2 found in pg_proc"
            )
        token_arg = token_path or vault_token
        if "vault_v2" in fn:
            self._sql_add_vault_v2_provider(
                fn,
                provider_name,
                vault_url,
                secret_mount_point,
                token_arg,
                ca_path,
                namespace,
                dbname=dbname,
            )
        else:
            def esc(s: str) -> str:
                return s.replace("'", "''")

            sql = (
                f"SELECT {fn}('{esc(provider_name)}'::text, "
                f"'{esc(vault_url)}'::text, "
                f"'{esc(secret_mount_point)}'::text, "
                f"'{esc(token_arg)}'::text, "
                f"'{esc(ca_path)}'::text)"
            )
            self.cluster.execute(sql, dbname)

    def change_database_key_provider_vault(
        self,
        provider_name: str,
        *,
        vault_url: str,
        secret_mount_point: str,
        token_path: str,
        ca_path: str = "",
        namespace: str = "",
        dbname: str = "postgres",
    ) -> None:
        fn = self._first_func(["pg_tde_change_database_key_provider_vault_v2"])
        if fn is None:
            raise RuntimeError(
                "pg_tde_change_database_key_provider_vault_v2 not found in pg_proc"
            )
        self._sql_add_vault_v2_provider(
            fn,
            provider_name,
            vault_url,
            secret_mount_point,
            token_path,
            ca_path,
            namespace,
            dbname=dbname,
        )

    def change_global_key_provider_file(
        self,
        provider_name: str,
        keyfile: str,
        dbname: str = "postgres",
    ) -> None:
        fn = self._first_func(["pg_tde_change_global_key_provider_file"])
        if fn is None:
            raise RuntimeError(
                "pg_tde_change_global_key_provider_file not found in pg_proc"
            )
        path = keyfile.replace("'", "''")
        self.cluster.execute(
            f"SELECT {fn}('{provider_name}'::text, '{path}'::text)",
            dbname,
        )

    def _sql_add_kmip_provider(
        self,
        fn: str,
        provider_name: str,
        host: str,
        port: int,
        cert_path: str,
        key_path: str,
        ca_path: str,
        dbname: str = "postgres",
    ) -> None:
        cert_path = cert_path.replace("'", "''")
        key_path = key_path.replace("'", "''")
        ca_path = (ca_path or "").replace("'", "''")
        host = host.replace("'", "''")
        nargs = self._nargs(fn)
        if nargs >= 6 and ca_path:
            sql = (
                f"SELECT {fn}('{provider_name}'::text, '{host}'::text, "
                f"{port}::integer, '{cert_path}'::text, '{key_path}'::text, "
                f"'{ca_path}'::text)"
            )
        elif nargs >= 5:
            sql = (
                f"SELECT {fn}('{provider_name}'::text, '{host}'::text, "
                f"{port}::integer, '{cert_path}'::text, '{key_path}'::text)"
            )
        else:
            raise RuntimeError(
                f"{fn} has unexpected pronargs={nargs} (expected 5 or 6)"
            )
        self.cluster.execute(sql, dbname)

    def add_global_key_provider_kmip(
        self,
        provider_name: str = "kmip_provider",
        *,
        host: str,
        port: int,
        cert_path: str,
        key_path: str,
        ca_path: str = "",
    ) -> None:
        """Register a global KMIP key provider (TLS + KMIP protocol)."""
        fn = self._first_func([
            "pg_tde_add_global_key_provider_kmip",
            "pg_tde_add_key_provider_kmip",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde add_global_key_provider_kmip function found in pg_proc"
            )
        self._sql_add_kmip_provider(
            fn, provider_name, host, port, cert_path, key_path, ca_path
        )

    def add_database_key_provider_kmip(
        self,
        provider_name: str,
        *,
        host: str,
        port: int,
        cert_path: str,
        key_path: str,
        ca_path: str = "",
        dbname: str = "postgres",
    ) -> None:
        fn = self._first_func([
            "pg_tde_add_database_key_provider_kmip",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde_add_database_key_provider_kmip function found in pg_proc"
            )
        self._sql_add_kmip_provider(
            fn,
            provider_name,
            host,
            port,
            cert_path,
            key_path,
            ca_path,
            dbname=dbname,
        )

    def change_database_key_provider_kmip(
        self,
        provider_name: str,
        *,
        host: str,
        port: int,
        cert_path: str,
        key_path: str,
        ca_path: str = "",
        dbname: str = "postgres",
    ) -> None:
        """Reconfigure an existing database-scope KMIP provider (online SQL)."""
        fn = self._first_func(["pg_tde_change_database_key_provider_kmip"])
        if fn is None:
            raise RuntimeError(
                "pg_tde_change_database_key_provider_kmip not found in pg_proc"
            )
        self._sql_add_kmip_provider(
            fn,
            provider_name,
            host,
            port,
            cert_path,
            key_path,
            ca_path,
            dbname=dbname,
        )

    def change_global_key_provider_kmip(
        self,
        provider_name: str,
        *,
        host: str,
        port: int,
        cert_path: str,
        key_path: str,
        ca_path: str = "",
    ) -> None:
        """Reconfigure an existing global-scope KMIP provider (online SQL)."""
        fn = self._first_func(["pg_tde_change_global_key_provider_kmip"])
        if fn is None:
            raise RuntimeError(
                "pg_tde_change_global_key_provider_kmip not found in pg_proc"
            )
        self._sql_add_kmip_provider(
            fn,
            provider_name,
            host,
            port,
            cert_path,
            key_path,
            ca_path,
        )

    def set_global_default_principal_key(
        self,
        key_name: str,
        provider_name: str,
        dbname: str = "postgres",
    ) -> None:
        """Create + activate global default principal key (KMIP default-key scenarios)."""
        create_fn = self._first_func(["pg_tde_create_key_using_global_key_provider"])
        set_fn = self._first_func([
            "pg_tde_set_default_key_using_global_key_provider",
        ])
        if not create_fn or not set_fn:
            raise RuntimeError(
                "pg_tde global default key functions not found "
                f"(installed: {self.available_functions()})"
            )
        self._execute_create_global_key_allow_duplicate(
            f"SELECT {create_fn}('{key_name}'::text, '{provider_name}'::text)",
            dbname,
        )
        self.cluster.execute(
            f"SELECT {set_fn}('{key_name}'::text, '{provider_name}'::text)",
            dbname,
        )

    def set_database_principal_key(
        self,
        key_name: str,
        provider_name: str,
        dbname: str = "postgres",
    ) -> None:
        create_fn = self._first_func([
            "pg_tde_create_key_using_database_key_provider",
        ])
        set_fn = self._first_func([
            "pg_tde_set_key_using_database_key_provider",
        ])
        if not create_fn or not set_fn:
            raise RuntimeError(
                "pg_tde database key functions not found "
                f"(installed: {self.available_functions()})"
            )
        self._execute_create_global_key_allow_duplicate(
            f"SELECT {create_fn}('{key_name}'::text, '{provider_name}'::text)",
            dbname,
        )
        self.cluster.execute(
            f"SELECT {set_fn}('{key_name}'::text, '{provider_name}'::text)",
            dbname,
        )

    def set_global_principal_key(
        self,
        key_name: str = "test_key",
        provider_name: str = "file_provider",
        dbname: str = "postgres",
    ) -> None:
        """
        Create and activate encryption keys (Percona pg_tde API):
          1. pg_tde_create_key_using_global_key_provider(key, provider)
          2. pg_tde_set_server_key_using_global_key_provider(key, provider)  -- WAL key
          3. pg_tde_set_key_using_global_key_provider(key, provider)         -- table key
        """
        create_fn = self._first_func(["pg_tde_create_key_using_global_key_provider"])
        server_fn = self._first_func(["pg_tde_set_server_key_using_global_key_provider"])
        db_fn = self._first_func(["pg_tde_set_key_using_global_key_provider"])

        if create_fn and server_fn and db_fn:
            # Preferred: explicit server + database keys (matches Percona docs)
            self._execute_create_global_key_allow_duplicate(
                f"SELECT {create_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
            )
            self.cluster.execute(
                f"SELECT {server_fn}('{key_name}'::text, '{provider_name}'::text)"
            )
            self.cluster.execute(
                f"SELECT {db_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
            )
            return

        # Fallback: set_default covers both server and database in some builds
        set_default_fn = self._first_func(["pg_tde_set_default_key_using_global_key_provider"])
        if create_fn and set_default_fn:
            self._execute_create_global_key_allow_duplicate(
                f"SELECT {create_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
            )
            self.cluster.execute(
                f"SELECT {set_default_fn}('{key_name}'::text, '{provider_name}'::text)", dbname
            )
            return

        # Legacy API (older pg_tde releases)
        fn = self._first_func([
            "pg_tde_set_global_principal_key",
            "pg_tde_set_server_principal_key",
            "pg_tde_set_principal_key",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde set_principal_key-style function found in pg_proc. "
                f"Installed pg_tde functions: {self.available_functions()}"
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

        if create_fn and server_fn and db_fn:
            self._execute_create_global_key_allow_duplicate(
                f"SELECT {create_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
            )
            self.cluster.execute(
                f"SELECT {server_fn}('{new_key_name}'::text, '{provider_name}'::text)"
            )
            self.cluster.execute(
                f"SELECT {db_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
            )
            return

        set_default_fn = self._first_func(["pg_tde_set_default_key_using_global_key_provider"])
        if create_fn and set_default_fn:
            self._execute_create_global_key_allow_duplicate(
                f"SELECT {create_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
            )
            self.cluster.execute(
                f"SELECT {set_default_fn}('{new_key_name}'::text, '{provider_name}'::text)", dbname
            )
            return

        fn = self._first_func([
            "pg_tde_rotate_principal_key",
            "pg_tde_rotate_global_principal_key",
        ])
        if fn is None:
            raise RuntimeError(
                "No pg_tde rotate_principal_key function found (modern builds use "
                "create_key + set_default_key). "
                f"Installed pg_tde functions: {self.available_functions()}"
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
        # pg_tde.wal_encrypt is not reloadable; must restart to take effect.
        self.cluster.restart()

    def disable_wal_encryption(self) -> None:
        self.cluster.execute("ALTER SYSTEM RESET pg_tde.wal_encrypt")
        self.cluster.restart()

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
                val = self.cluster.fetchone(f"SELECT {fn}('{table}'::regclass)", dbname)
                return val in ("t", "true", "on", "1")
        return False

    def get_access_method(self, table: str, dbname: str = "postgres") -> str:
        return self.cluster.fetchone(
            f"SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            f"WHERE c.relname = '{table}'",
            dbname,
        )

    def list_key_providers(self, *, scope: str = "global") -> int:
        """Return the count of registered key providers (global or database-local).

        Current pg_tde exposes ``pg_tde_list_all_global_key_providers`` /
        ``pg_tde_list_all_database_key_providers`` (see Percona docs); older builds
        used shorter names.
        """
        if scope == "database":
            candidates = (
                "pg_tde_list_all_database_key_providers",
                "pg_tde_list_database_key_providers",
                "pg_tde_key_providers",
            )
        else:
            candidates = (
                "pg_tde_list_all_global_key_providers",
                "pg_tde_list_global_key_providers",
                "pg_tde_list_key_providers",
                "pg_tde_key_providers",
            )
        for fn in candidates:
            if self._has_func(fn):
                result = self.cluster.fetchone(f"SELECT COUNT(*) FROM {fn}()")
                return int(result) if result else 0
        return 0

    def principal_key_name(self) -> Optional[str]:
        # Current pg_tde: *_key_info(); older builds used principal_key_info names.
        for fn in (
            "pg_tde_key_info",
            "pg_tde_default_key_info",
            "pg_tde_server_key_info",
            "pg_tde_principal_key_info",
            "pg_tde_get_key_info",
            "pg_tde_get_principal_key_info",
        ):
            if self._has_func(fn):
                row = self.cluster.fetchone(f"SELECT key_name FROM {fn}()")
                if row:
                    return row
        return None

    def principal_key_info_snapshot(self, dbname: str = "postgres") -> str:
        """
        Raw ``SELECT *`` output from the first supported pg_tde key-info SRF.

        pg_tde renamed these helpers across releases (``pg_tde_key_info`` vs
        ``pg_tde_principal_key_info``, etc.); tests should not hard-code one name.
        """
        for fn in (
            "pg_tde_key_info",
            "pg_tde_default_key_info",
            "pg_tde_server_key_info",
            "pg_tde_principal_key_info",
            "pg_tde_get_key_info",
            "pg_tde_get_principal_key_info",
        ):
            if not self._has_func(fn):
                continue
            try:
                return self.cluster.execute(
                    f"SELECT * FROM {fn}()", dbname
                ).strip()
            except RuntimeError:
                continue
        return ""

    # ── basebackup with TDE ───────────────────────────────────────────────

    def tde_basebackup(
        self,
        target_dir: str,
        extra_args=None,
        *,
        encrypt_wal: Optional[bool] = None,
    ) -> None:
        """
        Run ``pg_tde_basebackup`` against ``self.cluster``.

        Args:
            target_dir: backup destination (will be created if missing).
            extra_args: list of extra CLI flags to forward to pg_tde_basebackup.
            encrypt_wal: controls the ``-E`` flag (encrypted WAL on the target):

                - ``None`` (default): auto-detect — pass ``-E`` iff
                  ``pg_tde.wal_encrypt = on`` on the source. Suppresses the
                  ``"source has WAL keys, but no WAL encryption configured…"``
                  warning when the source is WAL-encrypted, and avoids it
                  meaninglessly when the source runs plaintext WAL.
                - ``True``: always pass ``-E`` and pre-seed the destination's
                  ``pg_tde/`` keyring (required so pg_tde_basebackup can
                  encrypt the streamed WAL on the way in).
                - ``False``: never pass ``-E``. The warning will appear if
                  the source has any pg_tde keys configured — that's expected
                  and harmless for tests that intentionally run with
                  plaintext WAL.

            Backwards compatibility: passing ``-E`` (or ``--wal-encrypted``)
            via ``extra_args`` still works and is treated as ``encrypt_wal=True``.
        """
        bin_path = self.cluster.bin / "pg_tde_basebackup"
        if not bin_path.exists():
            # Fall back to standard pg_basebackup if tde variant not present
            log.warning("pg_tde_basebackup not found, using pg_basebackup")
            self.cluster.basebackup(target_dir, extra_args)
            return
        env = os.environ.copy()
        lib_dir = str(self.cluster.install_dir / "lib")
        ld_var = "LD_LIBRARY_PATH"
        existing = env.get(ld_var, "")
        env[ld_var] = f"{lib_dir}:{existing}" if existing else lib_dir

        bb_args = list(extra_args or [])
        e_in_args = "-E" in bb_args or "--wal-encrypted" in bb_args
        if encrypt_wal is None:
            # Auto: enable -E iff the source is actually running with WAL
            # encryption on. Defensive — is_wal_encrypted() returns False if
            # the GUC can't be read for any reason, so the default mirrors
            # the historical no-op behaviour.
            encrypt_wal = self.is_wal_encrypted()
        # Honour explicit -E in extra_args even if encrypt_wal=False (consistent
        # with the previous behaviour where callers could opt in via extra_args).
        use_E = bool(encrypt_wal) or e_in_args
        if use_E and not e_in_args:
            bb_args.append("-E")

        # Pre-seed pg_tde only for encrypted WAL streaming (-E): pg_tde_basebackup
        # needs keys in the destination before the stream; for normal backups it
        # creates pg_tde itself and fails with "File exists" if we copy first.
        if use_E:
            tgt = Path(target_dir)
            src_pg_tde = self.cluster.data_dir / "pg_tde"
            if src_pg_tde.is_dir():
                tgt.mkdir(parents=True, exist_ok=True)
                dst_pg_tde = tgt / "pg_tde"
                if dst_pg_tde.exists():
                    shutil.rmtree(dst_pg_tde)
                shutil.copytree(src_pg_tde, dst_pg_tde)
        cmd = [
            str(bin_path),
            "-h", str(self.cluster.socket_dir),
            "-p", str(self.cluster.port),
            "-U", libpq_superuser(),
            "-D", target_dir,
            "-R", "--checkpoint=fast",
        ]
        cmd.extend(bb_args)
        subprocess.run(cmd, check=True, env=env)
        log.info("pg_tde_basebackup completed to %s (encrypt_wal=%s)",
                 target_dir, use_E)

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


# ── WAL archive / restore_command helpers (was lib.tde_wal_archive) ──────────


def wrappers_available(install_dir: Path) -> bool:
    decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
    encrypt = install_dir / "bin" / "pg_tde_restore_encrypt"
    return decrypt.is_file() and encrypt.is_file()


def archive_restore_conf_values(
    install_dir: Path,
    archive_dir: Union[Path, str],
    *,
    use_tde_wrappers: bool = True,
) -> Tuple[str, str]:
    """
    Return (archive_command, restore_command) for ``extra_params`` to postgresql.conf
    (each value is single-quoted).

    With ``use_tde_wrappers`` True and binaries present: ``pg_tde_archive_decrypt``
    / ``pg_tde_restore_encrypt`` around ``cp`` (see automation pg_tde_rewind_wal_encryption.sh).
    Otherwise plain ``cp``.
    """
    ad = str(archive_dir).rstrip("/")
    if use_tde_wrappers and wrappers_available(install_dir):
        decrypt = install_dir / "bin" / "pg_tde_archive_decrypt"
        encrypt = install_dir / "bin" / "pg_tde_restore_encrypt"
        arch = f'{decrypt} %f %p "cp %%p {ad}/%%f"'
        rst = f'{encrypt} %f %p "cp {ad}/%%f %%p"'
    else:
        arch = f"cp %p {ad}/%f"
        rst = f"cp {ad}/%f %p"
    return (f"'{arch}'", f"'{rst}'")


def restore_conf_line_raw(
    archive_dir: Union[Path, str],
    install_dir: Path,
    *,
    use_tde_wrappers: bool = True,
) -> str:
    _, rst_val = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=use_tde_wrappers
    )
    inner = rst_val.strip("'")
    return f"restore_command = '{inner}'\n"
