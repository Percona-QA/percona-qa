"""
Key-provider lifecycle verification for pg_tde SQL APIs.

Covers add / set / change / rotate / delete of global and database-scoped
providers across Vault (HashiCorp or OpenBao), Cosmian KMIP, and file
keyrings — including isolation, dump/restore migration, and server-key +
WAL-encrypt handoff. Port of ``pg_tde_functions_test.sh``.

Unlike ``test_openbao_key_providers.py`` (OpenBao + ``VAULT_NAMESPACE`` required),
this module has no namespace gate.

Scenario map:
  1  DB-scoped vault provider; not usable from another database
  2  Multi-DB global vault + kmip + file
  3  Local vault + global KMIP default; delete/list cleanup
  4  Single DB with vault, kmip, and file providers
  5  ``change_global_key_provider_file`` + restart
  6  Global KMIP then DB vault principal keys
  7  Default key rotation vault → kmip → file
  8  pg_dump / restore + rotate to KMIP
  9  Default global + local file keys
  10 Delete global provider must fail while DB key is active
  11 Server key on vault → WAL encrypt → migrate to file → delete vault
  12 Delete unused global after default moved to file
"""
from __future__ import annotations

import shutil
import subprocess
import uuid
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig
from lib.vault import VaultConfig

pytestmark = [
    pytest.mark.encryption,
    pytest.mark.vault,
]


def _uid() -> str:
    return uuid.uuid4().hex[:8]


def _tde_cluster(pg_factory, tmp_path: Path, name: str) -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(
        extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
        }
    )
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


def _add_global_vault(
    tde: TdeManager, vault: VaultConfig, name: str, tmp_path: Path
) -> None:
    tde.add_global_key_provider_vault(
        name,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
    )


def _add_db_vault(
    tde: TdeManager,
    vault: VaultConfig,
    name: str,
    tmp_path: Path,
    dbname: str,
) -> None:
    tde.add_database_key_provider_vault(
        name,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
        dbname=dbname,
    )


def _add_global_kmip(tde: TdeManager, kmip: KmipConfig, name: str) -> None:
    tde.add_global_key_provider_kmip(
        name,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )


def _set_db_key(cluster: PgCluster, key: str, ring: str, dbname: str) -> None:
    TdeManager(cluster).set_database_principal_key(key, ring, dbname=dbname)


def _provider_names(cluster: PgCluster, sql: str, dbname: str = "postgres") -> set[str]:
    out = cluster.execute(sql, dbname)
    return {
        ln.strip()
        for ln in out.splitlines()
        if ln.strip() and not ln.strip().startswith("(")
    }


@pytest.mark.vault
class TestKeyProviderLifecycle:
    """pg_tde key-provider SQL lifecycle (add/set/rotate/change/delete)."""

    def test_fn_s1_db_scoped_vault_not_visible_in_other_db(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 1 — DB-scoped vault provider; other DB cannot use it."""
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s1")
        tde = TdeManager(cluster)
        cluster.execute("CREATE DATABASE db1")
        cluster.execute("CREATE DATABASE db2")
        cluster.execute("CREATE EXTENSION pg_tde", "db1")
        cluster.execute("CREATE EXTENSION pg_tde", "db2")

        _add_db_vault(tde, vault_config, "vault_keyring", tmp_path, "db1")
        key = f"vault_key1_{_uid()}"
        tde.set_database_principal_key(key, "vault_keyring", dbname="db1")

        # Provider is not in db2's catalog — create/set must fail.
        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_create_key_using_database_key_provider("
                f"'{key}_x', 'vault_keyring')",
                "db2",
            )
        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_set_key_using_database_key_provider("
                f"'{key}', 'vault_keyring')",
                "db2",
            )

    @pytest.mark.kmip
    def test_fn_s2_multi_db_vault_kmip_file(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 2 — db1 vault, db2 kmip, db3 file; restart."""
        keyfile = str(tmp_path / "fn_s2.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s2")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "vault_keyring2", tmp_path)
        _add_global_kmip(tde, kmip_config, "kmip_keyring2")
        tde.add_global_key_provider_file("file_keyring2", keyfile=keyfile)

        for db in ("db1", "db2", "db3"):
            cluster.execute(f"CREATE DATABASE {db}")
            cluster.execute("CREATE EXTENSION pg_tde", db)

        u = _uid()
        tde.set_database_global_key(f"vault_key2_{u}", "vault_keyring2", dbname="db1")
        tde.set_database_global_key(f"kmip_key2_{u}", "kmip_keyring2", dbname="db2")
        tde.set_database_global_key(f"file_key2_{u}", "file_keyring2", dbname="db3")

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (100)", "db1")
        cluster.execute("CREATE TABLE t2(a INT) USING tde_heap; INSERT INTO t2 VALUES (100)", "db2")
        cluster.execute("CREATE TABLE t3(a INT) USING tde_heap; INSERT INTO t3 VALUES (100)", "db3")

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM t1", "db1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t2", "db2").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t3", "db3").strip() == "100"

    @pytest.mark.kmip
    def test_fn_s3_default_key_and_provider_cleanup(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 3 — local vault + KMIP default; delete keys/providers; empty lists."""
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s3")
        tde = TdeManager(cluster)
        u = _uid()

        _add_global_kmip(tde, kmip_config, "kmip_keyring3")
        tde.set_global_default_principal_key(f"kmip_key3_{u}", "kmip_keyring3")

        cluster.execute("CREATE DATABASE test1")
        cluster.execute("CREATE DATABASE test2")
        cluster.execute("CREATE EXTENSION pg_tde", "test1")
        cluster.execute("CREATE EXTENSION pg_tde", "test2")

        _add_db_vault(tde, vault_config, "vault_keyring3", tmp_path, "test1")
        tde.set_database_principal_key(f"vault_key3_{u}", "vault_keyring3", dbname="test1")

        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (100)", "test1"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (1)", "test2"
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM t1", "test1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t1", "test2").strip() == "1"

        cluster.execute("DROP TABLE t1", "test1")
        cluster.execute("DROP TABLE t1", "test2")
        # Drop DB key / default so providers become deletable (bash cleanup path).
        cluster.execute("SELECT pg_tde_delete_key()", "test1")
        try:
            cluster.execute("SELECT pg_tde_delete_default_key()", "test1")
        except RuntimeError:
            cluster.execute("SELECT pg_tde_delete_default_key()")
        cluster.execute(
            "SELECT pg_tde_delete_database_key_provider('vault_keyring3')", "test1"
        )
        cluster.execute("SELECT pg_tde_delete_global_key_provider('kmip_keyring3')")

        cluster.restart()
        cluster.wait_ready(timeout=90)
        db_names = _provider_names(
            cluster, "SELECT name FROM pg_tde_list_all_database_key_providers()", "test1"
        )
        g_names = _provider_names(
            cluster, "SELECT name FROM pg_tde_list_all_global_key_providers()", "test1"
        )
        assert "vault_keyring3" not in db_names
        assert "kmip_keyring3" not in g_names

    @pytest.mark.kmip
    def test_fn_s4_single_db_multi_providers(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 4 — sbtest2 vault → kmip → file; verify_key; restart."""
        keyfile = str(tmp_path / "fn_s4.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s4")
        tde = TdeManager(cluster)
        u = _uid()
        cluster.execute("CREATE DATABASE sbtest2")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest2")

        _add_db_vault(tde, vault_config, "vault_keyring4", tmp_path, "sbtest2")
        _set_db_key(cluster, f"vault_key4_{u}", "vault_keyring4", "sbtest2")
        cluster.execute("SELECT pg_tde_verify_key()", "sbtest2")
        cluster.execute(
            "CREATE TABLE t1(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t1 VALUES (100,'a'); UPDATE t1 SET b='b' WHERE a=100",
            "sbtest2",
        )

        tde.add_database_key_provider_kmip(
            "kmip_keyring4",
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="sbtest2",
        )
        _set_db_key(cluster, f"kmip_key4_{u}", "kmip_keyring4", "sbtest2")
        cluster.execute("SELECT pg_tde_verify_key()", "sbtest2")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; INSERT INTO t2 VALUES (100,'a')",
            "sbtest2",
        )

        tde.add_database_key_provider_file(
            "file_keyring", keyfile=keyfile, dbname="sbtest2"
        )
        _set_db_key(cluster, f"file_key1_{u}", "file_keyring", "sbtest2")
        cluster.execute("SELECT pg_tde_verify_key()", "sbtest2")
        cluster.execute(
            "CREATE TABLE t3(a INT, b TEXT) USING tde_heap; INSERT INTO t3 VALUES (100,'a')",
            "sbtest2",
        )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT a FROM t1 WHERE a=100", "sbtest2").strip() == "100"
        assert cluster.fetchone("SELECT COUNT(*) FROM t2", "sbtest2") == "1"
        assert cluster.fetchone("SELECT COUNT(*) FROM t3", "sbtest2") == "1"

    @pytest.mark.kmip
    def test_fn_s5_change_global_file_provider(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 5 — change_global_key_provider_file after copying key material."""
        key_old = str(tmp_path / "keyring5.per")
        key_new = str(tmp_path / "keyring5_new.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s5")
        tde = TdeManager(cluster)
        u = _uid()

        cluster.execute("CREATE DATABASE sbtest5")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest5")
        tde.add_global_key_provider_file("file_keyring5", keyfile=key_old)
        _add_global_kmip(tde, kmip_config, "kmip_keyring5")
        _add_global_vault(tde, vault_config, "vault_keyring5", tmp_path)

        tde.set_database_global_key(f"file_key5_{u}", "file_keyring5", dbname="sbtest5")
        cluster.execute(
            "CREATE TABLE t1(a INT, b TEXT) USING tde_heap; INSERT INTO t1 VALUES (100,'x')",
            "sbtest5",
        )
        shutil.copy(key_old, key_new)
        tde.change_global_key_provider_file("file_keyring5", key_new, dbname="sbtest5")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; INSERT INTO t2 VALUES (200,'y')",
            "sbtest5",
        )
        cluster.execute("SELECT pg_tde_verify_key()", "sbtest5")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert "100" in cluster.fetchone("SELECT * FROM t1", "sbtest5")
        assert "200" in cluster.fetchone("SELECT * FROM t2", "sbtest5")

    @pytest.mark.kmip
    def test_fn_s6_global_kmip_then_db_vault(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 6 — global KMIP t1, then DB vault t2."""
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s6")
        tde = TdeManager(cluster)
        u = _uid()
        _add_global_kmip(tde, kmip_config, "kmip_keyring6")
        tde.set_global_principal_key(f"kmip_key6_{u}", "kmip_keyring6")
        cluster.execute(
            "CREATE TABLE t1(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t1 VALUES (100,'a'),(200,'b')"
        )
        _add_db_vault(tde, vault_config, "vault_keyring6", tmp_path, "postgres")
        _set_db_key(cluster, f"vault_key6_{u}", "vault_keyring6", "postgres")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t2 VALUES (100,'a'),(200,'b')"
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT COUNT(*) FROM t1") == "2"
        assert cluster.fetchone("SELECT COUNT(*) FROM t2") == "2"

    @pytest.mark.kmip
    def test_fn_s7_default_key_rotation_vault_kmip_file(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 7 — rotate global default across vault / kmip / file."""
        keyfile = str(tmp_path / "fn_s7.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s7")
        tde = TdeManager(cluster)
        u = _uid()

        _add_global_vault(tde, vault_config, "keyring_vault7", tmp_path)
        tde.set_global_default_principal_key(f"def1_{u}", "keyring_vault7")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t1 VALUES (101, 'bond')"
        )
        tde.set_global_default_principal_key(f"def2_{u}", "keyring_vault7")
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

        _add_global_kmip(tde, kmip_config, "keyring_kmip7")
        tde.set_global_default_principal_key(f"def3_{u}", "keyring_kmip7")
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

        tde.add_global_key_provider_file("keyring_file7", keyfile=keyfile)
        tde.set_global_default_principal_key(f"def4_{u}", "keyring_file7")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

    @pytest.mark.kmip
    @pytest.mark.slow
    def test_fn_s8_dump_restore_provider_migration(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 8 — dump vault DB into file-keyed DB; rotate to KMIP."""
        keyfile = str(tmp_path / "fn_s8.per")
        dump_path = tmp_path / "t1.sql"
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s8")
        tde = TdeManager(cluster)
        u = _uid()

        cluster.execute("CREATE DATABASE db8")
        cluster.execute("CREATE EXTENSION pg_tde", "db8")
        _add_db_vault(tde, vault_config, "keyring_vault", tmp_path, "db8")
        _set_db_key(cluster, f"vault_key_{u}", "keyring_vault", "db8")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING heap; "
            "INSERT INTO t1 VALUES (101, 'bond'); INSERT INTO t2 VALUES (101, 'bond')",
            "db8",
        )

        cluster.execute("CREATE DATABASE db8_new")
        cluster.execute("CREATE EXTENSION pg_tde", "db8_new")
        tde.add_database_key_provider_file(
            "keyring_file", keyfile=keyfile, dbname="db8_new"
        )
        _set_db_key(cluster, f"file_key_{u}", "keyring_file", "db8_new")

        subprocess.run(
            [
                str(install_dir / "bin" / "pg_dump"),
                "-h", "127.0.0.1",
                "-p", str(cluster.port),
                "-d", "db8",
                "-t", "t1",
                "-t", "t2",
                "-f", str(dump_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            [
                str(install_dir / "bin" / "psql"),
                "-h", "127.0.0.1",
                "-p", str(cluster.port),
                "-d", "db8_new",
                "-f", str(dump_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101", "db8_new").strip() == "bond"

        _set_db_key(cluster, f"file_key3_{u}", "keyring_file", "db8_new")
        tde.add_database_key_provider_kmip(
            "keyring_kmip",
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="db8_new",
        )
        _set_db_key(cluster, f"file_key2_{u}", "keyring_kmip", "db8_new")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101", "db8_new").strip() == "bond"
        assert cluster.fetchone("SELECT b FROM t2 WHERE a=101", "db8_new").strip() == "bond"

    def test_fn_s9_default_and_local_keys(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 9 — global default vault + local file; switch back to global."""
        keyfile = str(tmp_path / "fn_s9.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s9")
        tde = TdeManager(cluster)
        u = _uid()

        _add_global_vault(tde, vault_config, "vault_keyring9", tmp_path)
        tde.set_global_default_principal_key(f"vault_key9_{u}", "vault_keyring9")

        cluster.execute("CREATE DATABASE test9")
        cluster.execute("CREATE EXTENSION pg_tde", "test9")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t1 VALUES (101, 't1')",
            "test9",
        )
        tde.set_global_default_principal_key(f"vault_key91_{u}", "vault_keyring9")
        cluster.execute(
            "CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t2 VALUES (101, 't2')",
            "test9",
        )

        tde.add_database_key_provider_file(
            "keyring_file9", keyfile=keyfile, dbname="test9"
        )
        _set_db_key(cluster, f"file_key9_{u}", "keyring_file9", "test9")
        cluster.execute(
            "CREATE TABLE t3(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t3 VALUES (101, 't3')",
            "test9",
        )
        tde.set_global_principal_key(
            f"vault_key92_{u}", "vault_keyring9", dbname="test9"
        )
        cluster.execute(
            "SELECT pg_tde_delete_database_key_provider('keyring_file9')", "test9"
        )
        cluster.execute("SELECT pg_tde_delete_key()", "test9")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        for table in ("t1", "t2", "t3"):
            assert cluster.fetchone(f"SELECT COUNT(*) FROM {table}", "test9") == "1"
            cluster.execute(f"DROP TABLE {table}", "test9")
        cluster.execute("SELECT pg_tde_delete_default_key()", "test9")

    def test_fn_s10_delete_global_with_active_db_key_fails(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 10 — delete global provider must fail while DB key is active."""
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s10")
        tde = TdeManager(cluster)
        u = _uid()
        _add_global_vault(tde, vault_config, "vault_keyring10", tmp_path)

        cluster.execute("CREATE DATABASE test10")
        cluster.execute("CREATE EXTENSION pg_tde", "test10")
        tde.set_database_global_key(
            f"vault_key10_{u}", "vault_keyring10", dbname="test10"
        )
        cluster.execute(
            "CREATE TABLE t10(a INT) USING tde_heap; INSERT INTO t10 VALUES (10)",
            "test10",
        )

        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('vault_keyring10')"
            )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM t10", "test10").strip() == "10"

    def test_fn_s11_server_key_wal_migrate_delete_vault(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 11 — server key on vault, WAL encrypt, move to file, delete vault."""
        keyfile = str(tmp_path / "fn_s11.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s11")
        tde = TdeManager(cluster)
        u = _uid()

        _add_global_vault(tde, vault_config, "vault_keyring11", tmp_path)
        # Server / WAL key on vault.
        create_fn = "pg_tde_create_key_using_global_key_provider"
        server_fn = "pg_tde_set_server_key_using_global_key_provider"
        try:
            cluster.execute(
                f"SELECT {create_fn}('server_key_{u}', 'vault_keyring11')"
            )
        except RuntimeError as e:
            if "already exists" not in str(e).lower():
                raise
        cluster.execute(
            f"SELECT {server_fn}('server_key_{u}', 'vault_keyring11')"
        )

        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('vault_keyring11')"
            )

        cluster.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = on")
        cluster.restart()
        cluster.wait_ready(timeout=90)

        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('vault_keyring11')"
            )

        tde.add_global_key_provider_file("keyring_file11", keyfile=keyfile)
        try:
            cluster.execute(
                f"SELECT {create_fn}('server_key_file_{u}', 'keyring_file11')"
            )
        except RuntimeError as e:
            if "already exists" not in str(e).lower():
                raise
        cluster.execute(
            f"SELECT {server_fn}('server_key_file_{u}', 'keyring_file11')"
        )
        cluster.execute(
            "SELECT pg_tde_delete_global_key_provider('vault_keyring11')"
        )

    def test_fn_s12_delete_unused_global_provider(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 12 — delete vault global after default moves to file."""
        keyfile = str(tmp_path / "fn_s12.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "fn_s12")
        tde = TdeManager(cluster)
        u = _uid()

        _add_global_vault(tde, vault_config, "vault_keyring12", tmp_path)
        tde.set_global_default_principal_key(f"vault_key12_{u}", "vault_keyring12")
        tde.add_global_key_provider_file("keyring_file12", keyfile=keyfile)
        tde.set_global_default_principal_key(f"keyring_key12_{u}", "keyring_file12")

        cluster.execute("SELECT pg_tde_delete_global_key_provider('vault_keyring12')")
        g_names = _provider_names(
            cluster, "SELECT name FROM pg_tde_list_all_global_key_providers()"
        )
        assert "vault_keyring12" not in g_names
        cluster.execute("SELECT pg_tde_delete_default_key()")
        cluster.execute("SELECT pg_tde_delete_global_key_provider('keyring_file12')")
