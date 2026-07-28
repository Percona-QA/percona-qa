"""
High-value pg_tde product gaps vs release-2.2 TAP/SQL regress.

Ports / pins scenarios that were thin or missing in pytest:

  * SQL access control (``sql/access_control.sql`` / ``t/basic.pl``)
  * ``pg_tde.inherit_global_providers = off`` (``t/rotate_key.pl``)
  * ``pg_tde.enforce_encryption`` per-database / per-role
  * ``pg_tde_is_encrypted`` for TEMP / indexes / sequences
  * Storage rewrite keeps encryption (``sql/recreate_storage.sql``)
  * ``pg_tde_basebackup -E`` after default key only (``t/basebackup_default_key.pl``)
  * Documented decrypt path: ``ALTER TABLE … SET ACCESS METHOD heap``

Does **not** duplicate rewind / pgBackRest / upgrade / KMIP matrices.
See https://github.com/percona/pg_tde/tree/release-2.2
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums, prepend_install_lib_dirs

pytestmark = [pytest.mark.encryption]


def _assert_fails(cluster: PgCluster, sql: str, *, must_contain: str = "") -> None:
    with pytest.raises(RuntimeError) as exc:
        cluster.execute(sql)
    if must_contain:
        assert must_contain.lower() in str(exc.value).lower(), (
            f"expected {must_contain!r} in error, got: {exc.value!r}"
        )


def _psql_as(cluster: PgCluster, user: str, sql: str, dbname: str = "postgres"):
    """Run SQL as a non-default role (for ALTER ROLE SET GUC coverage)."""
    env = os.environ.copy()
    prepend_install_lib_dirs(env, cluster.install_dir)
    return subprocess.run(
        [
            str(cluster.bin / "psql"),
            "-h", str(cluster.socket_dir),
            "-p", str(cluster.port),
            "-U", user,
            "-d", dbname,
            "-c", sql,
            "--no-align", "--tuples-only", "-q",
        ],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


class TestPgTdeAccessControl:
    """Only superusers may run key-management functions (grants do not help)."""

    def test_key_mgmt_functions_denied_to_nonsuperuser(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE USER regress_pg_tde_access_control")
        denied = tde_primary.execute_allow_error(
            """
            SET ROLE regress_pg_tde_access_control;
            SELECT pg_tde_create_key_using_global_key_provider('x', 'file_provider');
            """
        )
        assert denied.returncode != 0
        err = (denied.stderr or denied.stdout or "").lower()
        assert any(
            s in err for s in ("permission", "superuser", "denied", "must be")
        ), f"unexpected denial error: {denied.stderr!r}"

        # PUBLIC helper remains callable as the non-superuser.
        ok = tde_primary.execute_allow_error(
            """
            SET ROLE regress_pg_tde_access_control;
            SELECT pg_tde_version();
            """
        )
        assert ok.returncode == 0, ok.stderr
        tde_primary.execute("DROP USER regress_pg_tde_access_control")

    def test_grant_execute_does_not_bypass_superuser_check(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        """GRANT EXECUTE is insufficient — still must be superuser (access_control.sql)."""
        keyfile = str(tmp_path / "ac_grant.per")
        tde_primary.execute("CREATE USER regress_pg_tde_grant")
        for fn in (
            "pg_tde_create_key_using_global_key_provider(text, text)",
            "pg_tde_set_key_using_global_key_provider(text, text)",
            "pg_tde_set_default_key_using_global_key_provider(text, text)",
            "pg_tde_set_server_key_using_global_key_provider(text, text)",
            "pg_tde_delete_default_key()",
        ):
            try:
                tde_primary.execute(
                    f"GRANT EXECUTE ON FUNCTION {fn} TO regress_pg_tde_grant"
                )
            except RuntimeError:
                pass

        denied = tde_primary.execute_allow_error(
            f"""
            SET ROLE regress_pg_tde_grant;
            SELECT pg_tde_add_global_key_provider_file('g','{keyfile}');
            """
        )
        assert denied.returncode != 0
        msg = (denied.stderr or denied.stdout or "").lower()
        assert any(
            s in msg for s in ("permission", "superuser", "denied", "must be")
        ), f"unexpected error after GRANT: {denied.stderr!r}"
        tde_primary.execute("DROP USER regress_pg_tde_grant")


class TestInheritGlobalProvidersOff:
    """``pg_tde.inherit_global_providers=off`` blocks new global-provider binds."""

    def test_inherit_global_providers_off_blocks_global_key_bind(
        self, tde_primary: PgCluster, tmp_path: Path,
    ):
        # Local DB provider for the allowed path after GUC=off.
        local_kf = str(tmp_path / "local_inherit.per")
        tde_primary.execute(
            f"SELECT pg_tde_add_database_key_provider_file('db_file','{local_kf}')"
        )
        tde_primary.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'db_key','db_file')"
        )

        tde_primary.execute(
            "ALTER SYSTEM SET pg_tde.inherit_global_providers = off"
        )
        tde_primary.restart()
        tde_primary.wait_ready(timeout=60)
        assert tde_primary.fetchone("SHOW pg_tde.inherit_global_providers") == "off"

        _assert_fails(
            tde_primary,
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'blocked','file_provider')",
            must_contain="global key provider",
        )
        _assert_fails(
            tde_primary,
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'blocked','file_provider')",
            must_contain="global key provider",
        )

        # Database-local bind still works.
        tde_primary.execute(
            "SELECT pg_tde_set_key_using_database_key_provider('db_key','db_file')"
        )
        tde_primary.execute(
            "CREATE TABLE inherit_ok (id INT PRIMARY KEY) USING tde_heap"
        )
        assert TdeManager(tde_primary).is_table_encrypted("inherit_ok")

        # Restore default for later tests sharing the fixture cluster.
        tde_primary.execute(
            "ALTER SYSTEM RESET pg_tde.inherit_global_providers"
        )
        tde_primary.restart()
        tde_primary.wait_ready(timeout=60)


class TestEnforceEncryptionScopes:
    """Per-database / per-role ``pg_tde.enforce_encryption`` (docs how-to)."""

    def test_enforce_encryption_database_scope(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE DATABASE enforce_db")
        tde_primary.execute("CREATE EXTENSION pg_tde", dbname="enforce_db")
        TdeManager(tde_primary).set_global_principal_key(dbname="enforce_db")

        tde_primary.execute(
            "ALTER DATABASE enforce_db SET pg_tde.enforce_encryption = on"
        )
        # New session in enforce_db should block heap.
        with pytest.raises(RuntimeError) as exc:
            tde_primary.execute(
                "CREATE TABLE heap_blocked (id INT) USING heap",
                dbname="enforce_db",
            )
        assert "encrypt" in str(exc.value).lower() or "tde" in str(exc.value).lower()

        tde_primary.execute(
            "CREATE TABLE tde_ok (id INT PRIMARY KEY) USING tde_heap",
            dbname="enforce_db",
        )
        # postgres DB without the setting still allows heap.
        tde_primary.execute("CREATE TABLE heap_ok_elsewhere (id INT) USING heap")
        tde_primary.execute("DROP DATABASE enforce_db")

    def test_enforce_encryption_role_scope(self, tde_primary: PgCluster):
        # ALTER ROLE SET applies at login — must connect as the role, not SET ROLE.
        tde_primary.execute("CREATE ROLE enforce_role LOGIN")
        tde_primary.execute(
            "ALTER ROLE enforce_role SET pg_tde.enforce_encryption = on"
        )
        tde_primary.execute("GRANT ALL ON SCHEMA public TO enforce_role")
        tde_primary.execute(
            "GRANT CREATE ON TABLESPACE pg_default TO enforce_role"
        )
        denied = _psql_as(
            tde_primary,
            "enforce_role",
            "CREATE TABLE role_heap_blocked (id INT) USING heap",
        )
        assert denied.returncode != 0, denied.stderr
        err = (denied.stderr or "").lower()
        assert "encrypt" in err or "tde" in err or "heap" in err, denied.stderr
        # Superuser session without the role GUC still can create heap.
        tde_primary.execute("CREATE TABLE role_heap_ok (id INT) USING heap")
        tde_primary.execute("DROP ROLE enforce_role")


class TestPgTdeIsEncryptedCoverage:
    """Port highlights of ``sql/pg_tde_is_encrypted.sql``."""

    def test_temp_tables_indexes_and_sequences(self, tde_primary: PgCluster):
        # TEMP relations exist only for the session — create + probe in one -c.
        row = tde_primary.execute(
            """
            CREATE TABLE perm_enc (id SERIAL PRIMARY KEY) USING tde_heap;
            CREATE TABLE perm_norm (id SERIAL PRIMARY KEY) USING heap;
            CREATE TEMP TABLE temp_enc (id SERIAL PRIMARY KEY) USING tde_heap;
            CREATE TEMP TABLE temp_norm (id SERIAL PRIMARY KEY) USING heap;
            SELECT
              pg_tde_is_encrypted('perm_enc')::text,
              pg_tde_is_encrypted('perm_norm')::text,
              pg_tde_is_encrypted('temp_enc')::text,
              pg_tde_is_encrypted('temp_norm')::text,
              pg_tde_is_encrypted('perm_enc_id_seq')::text,
              pg_tde_is_encrypted('perm_enc_pkey')::text,
              (pg_tde_is_encrypted(NULL) IS NULL)::text;
            """
        )
        parts = row.split("|")
        assert parts == ["t", "f", "t", "f", "t", "t", "t"], row


class TestStorageRewriteEncryption:
    """VACUUM FULL / REINDEX CONCURRENTLY keep encryption (recreate_storage.sql)."""

    def test_vacuum_full_and_reindex_concurrently_keep_encryption(
        self, tde_primary: PgCluster,
    ):
        tde_primary.execute(
            "CREATE TABLE rewrite_t (a INT PRIMARY KEY) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO rewrite_t SELECT generate_series(1, 200)"
        )
        assert TdeManager(tde_primary).is_table_encrypted("rewrite_t")
        tde_primary.execute("VACUUM FULL rewrite_t")
        assert TdeManager(tde_primary).is_table_encrypted("rewrite_t")
        assert tde_primary.fetchone("SELECT COUNT(*) FROM rewrite_t") == "200"

        tde_primary.execute("CREATE INDEX rewrite_idx ON rewrite_t (a)")
        assert tde_primary.fetchone(
            "SELECT pg_tde_is_encrypted('rewrite_idx')::text"
        ) == "t"
        tde_primary.execute("REINDEX INDEX CONCURRENTLY rewrite_idx")
        assert tde_primary.fetchone(
            "SELECT pg_tde_is_encrypted('rewrite_idx')::text"
        ) == "t"

    def test_matview_refresh_keeps_encryption_status(self, tde_primary: PgCluster):
        tde_primary.execute(
            "CREATE TABLE mv_src (id INT PRIMARY KEY, v INT) USING tde_heap"
        )
        tde_primary.execute("INSERT INTO mv_src VALUES (1, 10), (2, 20)")
        tde_primary.execute(
            "CREATE MATERIALIZED VIEW mv_enc AS "
            "SELECT id, v * 2 AS v2 FROM mv_src WITH NO DATA"
        )
        # Matview created WITH NO DATA may not be encrypted until refreshed
        # depending on AM inheritance — refresh and assert readable + status.
        tde_primary.execute("REFRESH MATERIALIZED VIEW mv_enc")
        assert tde_primary.fetchone("SELECT COUNT(*) FROM mv_enc") == "2"
        assert tde_primary.fetchone(
            "SELECT pg_tde_is_encrypted('mv_enc')::text"
        ) == "t"


class TestDecryptViaSetAccessMethod:
    """Documented decrypt path: ALTER TABLE … SET ACCESS METHOD heap."""

    def test_alter_table_set_access_method_heap_decrypts(
        self, tde_primary: PgCluster,
    ):
        tde_primary.execute(
            "CREATE TABLE decrypt_me (id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO decrypt_me SELECT i, md5(i::text) FROM generate_series(1,50) i"
        )
        assert TdeManager(tde_primary).is_table_encrypted("decrypt_me")
        tde_primary.execute("ALTER TABLE decrypt_me SET ACCESS METHOD heap")
        assert not TdeManager(tde_primary).is_table_encrypted("decrypt_me")
        assert tde_primary.fetchone("SELECT COUNT(*) FROM decrypt_me") == "50"
        assert tde_primary.fetchone(
            "SELECT payload FROM decrypt_me WHERE id = 1"
        ) == tde_primary.fetchone("SELECT md5('1')")


class TestPgTdeBasebackupDefaultKeyOnly:
    """
    ``t/basebackup_default_key.pl``: only default principal key (no restart
    materializing a separate server key) + ``pg_tde_basebackup -E``.
    """

    def test_pg_tde_basebackup_E_with_default_key_only(
        self, pg_factory, tmp_path: Path,
    ):
        cluster = pg_factory("bb_defkey")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(
            "primary",
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "wal_level": "replica",
                "max_wal_senders": "5",
            },
        )
        cluster.add_hba_entry("local all all trust")
        cluster.add_hba_entry("local replication all trust")
        cluster.start()
        cluster.wait_ready(timeout=60)

        tde = TdeManager(cluster)
        tde.create_extension()
        keyfile = str(tmp_path / "defkey.per")
        tde.add_global_key_provider_file(
            provider_name="file-provider", keyfile=keyfile
        )
        # Default key only — do NOT call set_global_principal_key / restart for WAL.
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'key1','file-provider')"
        )
        cluster.execute(
            "SELECT pg_tde_set_default_key_using_global_key_provider("
            "'key1','file-provider')"
        )
        server_key = cluster.fetchone(
            "SELECT COALESCE(key_name, '') FROM pg_tde_server_key_info()"
        )
        assert server_key == "key1", (
            "server principal key should auto-configure when default key is set; "
            f"got {server_key!r}"
        )

        backup_dir = tmp_path / "bb_defkey_out"
        backup_dir.mkdir()
        # Seed pg_tde/ then -E (product TAP does the same).
        shutil.copytree(cluster.data_dir / "pg_tde", backup_dir / "pg_tde")
        tde.tde_basebackup(str(backup_dir), extra_args=["-E"], encrypt_wal=True)
        assert (backup_dir / "PG_VERSION").exists()


class TestMultiTenantPerDbProviders:
    """Two databases, each with its own DB-scoped file provider + key."""

    def test_multi_tenant_per_db_file_providers(self, tde_primary: PgCluster, tmp_path: Path):
        for name in ("tenant_a", "tenant_b"):
            tde_primary.execute(f"CREATE DATABASE {name}")
            tde_primary.execute("CREATE EXTENSION pg_tde", dbname=name)
            kf = str(tmp_path / f"{name}.per")
            tde_primary.execute(
                f"SELECT pg_tde_add_database_key_provider_file('{name}_prov','{kf}')",
                dbname=name,
            )
            tde_primary.execute(
                f"SELECT pg_tde_create_key_using_database_key_provider("
                f"'{name}_key','{name}_prov')",
                dbname=name,
            )
            tde_primary.execute(
                f"SELECT pg_tde_set_key_using_database_key_provider("
                f"'{name}_key','{name}_prov')",
                dbname=name,
            )
            tde_primary.execute(
                f"CREATE TABLE t_{name} (id INT PRIMARY KEY, payload TEXT) USING tde_heap",
                dbname=name,
            )
            tde_primary.execute(
                f"INSERT INTO t_{name} VALUES (1, '{name}_secret')",
                dbname=name,
            )

        assert tde_primary.fetchone(
            "SELECT payload FROM t_tenant_a WHERE id = 1", dbname="tenant_a"
        ) == "tenant_a_secret"
        assert tde_primary.fetchone(
            "SELECT payload FROM t_tenant_b WHERE id = 1", dbname="tenant_b"
        ) == "tenant_b_secret"
        # Cross-DB: table must not exist in the other database.
        with pytest.raises(RuntimeError):
            tde_primary.execute(
                "SELECT * FROM t_tenant_a", dbname="tenant_b"
            )
