"""
OpenBao automation script parity — ``pg_tde_open_bao_tests.sh`` scenarios 4–12.

Scenarios 1–3 and the mount-metadata warning test are in ``test_vault_providers.py``
and ``test_external_key_provider_regressions.py``. Scenario 11 is in regressions.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig
from lib.vault import VaultConfig

pytestmark = [pytest.mark.vault, pytest.mark.openbao, pytest.mark.encryption]


def _require_openbao(vault_config: VaultConfig) -> None:
    if not vault_config.namespace.strip():
        pytest.skip("OpenBao bash parity requires --vault-namespace")


def _tde_cluster(pg_factory, tmp_path: Path, name: str) -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
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


def _set_db_key(
    cluster: PgCluster, key: str, ring: str, dbname: str
) -> None:
    cluster.execute(
        f"SELECT pg_tde_create_key_using_database_key_provider("
        f"'{key}', '{ring}')",
        dbname,
    )
    cluster.execute(
        f"SELECT pg_tde_set_key_using_database_key_provider('{key}', '{ring}')",
        dbname,
    )


@pytest.mark.vault
@pytest.mark.openbao
class TestOpenBaoBashParity:
    """Remaining ``pg_tde_open_bao_tests.sh`` scenarios."""

    def test_openbao_scenario4_multi_provider_single_database(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 4 — sbtest2: vault, kmip, and file DB providers."""
        _require_openbao(vault_config)
        keyfile = str(tmp_path / "bao_s4_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s4")
        tde = TdeManager(cluster)
        cluster.execute("CREATE DATABASE sbtest2")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest2")

        _add_db_vault(tde, vault_config, "vault_keyring4", tmp_path, "sbtest2")
        _set_db_key(cluster, "vault_key4", "vault_keyring4", "sbtest2")
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
        _set_db_key(cluster, "kmip_key4", "kmip_keyring4", "sbtest2")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t2 VALUES (100,'a')",
            "sbtest2",
        )

        tde.add_database_key_provider_file(
            "file_keyring", keyfile=keyfile, dbname="sbtest2"
        )
        _set_db_key(cluster, "file_key1", "file_keyring", "sbtest2")
        cluster.execute(
            "CREATE TABLE t3(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t3 VALUES (100,'a')",
            "sbtest2",
        )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT a FROM t1 WHERE a=100", "sbtest2").strip() == "100"
        assert cluster.fetchone("SELECT COUNT(*) FROM t2", "sbtest2") == "1"
        assert cluster.fetchone("SELECT COUNT(*) FROM t3", "sbtest2") == "1"

    def test_openbao_scenario5_global_file_provider_change(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 5 — ``change_global_key_provider_file`` + data integrity."""
        _require_openbao(vault_config)
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s5")
        tde = TdeManager(cluster)
        key_old = str(tmp_path / "keyring5.per")
        key_new = str(tmp_path / "keyring5_new.per")

        cluster.execute("CREATE DATABASE sbtest5")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest5")
        tde.add_global_key_provider_file("file_keyring5", keyfile=key_old)
        _add_global_kmip(tde, kmip_config, "kmip_keyring5")
        _add_global_vault(tde, vault_config, "vault_keyring5", tmp_path)

        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'file_key5', 'file_keyring5')",
            "sbtest5",
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'file_key5', 'file_keyring5')",
            "sbtest5",
        )
        cluster.execute(
            "CREATE TABLE t1(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t1 VALUES (100,'x')",
            "sbtest5",
        )
        shutil.copy(key_old, key_new)
        tde.change_global_key_provider_file("file_keyring5", key_new, dbname="sbtest5")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t2 VALUES (200,'y')",
            "sbtest5",
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM t1", "sbtest5").strip() == "100|x"
        assert cluster.fetchone("SELECT * FROM t2", "sbtest5").strip() == "200|y"

    def test_openbao_scenario6_local_and_global_vault_providers(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 6 — global kmip table t1, DB vault table t2 on postgres."""
        _require_openbao(vault_config)
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s6")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "kmip_keyring6")
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'kmip_key6', 'kmip_keyring6')"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'kmip_key6', 'kmip_keyring6')"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t1 VALUES (100,'a'),(200,'b')"
        )
        _add_db_vault(tde, vault_config, "vault_keyring6", tmp_path, "postgres")
        _set_db_key(cluster, "vault_key6", "vault_keyring6", "postgres")
        cluster.execute(
            "CREATE TABLE t2(a INT, b TEXT) USING tde_heap; "
            "INSERT INTO t2 VALUES (100,'a'),(200,'b')"
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT COUNT(*) FROM t1") == "2"
        assert cluster.fetchone("SELECT COUNT(*) FROM t2") == "2"

    def test_openbao_scenario7_default_key_rotation(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig, kmip_config: KmipConfig
    ):
        """Scenario 7 — rotate global default key across vault/kmip/file."""
        _require_openbao(vault_config)
        keyfile = str(tmp_path / "bao_s7_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s7")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "keyring_vault7", tmp_path)
        tde.set_global_default_principal_key("my_global_default_key1", "keyring_vault7")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t1 VALUES (101, 'bond')"
        )
        tde.set_global_default_principal_key("my_global_default_key2", "keyring_vault7")
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

        _add_global_kmip(tde, kmip_config, "keyring_kmip7")
        tde.set_global_default_principal_key("my_global_default_key3", "keyring_kmip7")
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

        tde.add_global_key_provider_file("keyring_file7", keyfile=keyfile)
        tde.set_global_default_principal_key("my_global_default_key4", "keyring_file7")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101").strip() == "bond"

    @pytest.mark.slow
    def test_openbao_scenario8_dump_restore_provider_migration(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        vault_config: VaultConfig,
        kmip_config: KmipConfig,
    ):
        """Scenario 8 — pg_dump, restore, rotate keys, add KMIP provider."""
        _require_openbao(vault_config)
        keyfile = str(tmp_path / "bao_s8_file.per")
        dump_path = tmp_path / "t1.sql"
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s8")
        tde = TdeManager(cluster)

        cluster.execute("CREATE DATABASE db8")
        cluster.execute("CREATE EXTENSION pg_tde", "db8")
        _add_db_vault(tde, vault_config, "keyring_vault", tmp_path, "db8")
        _set_db_key(cluster, "vault_key", "keyring_vault", "db8")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING heap; "
            "INSERT INTO t1 VALUES (101, 'bond'); INSERT INTO t2 VALUES (101, 'bond')",
            "db8",
        )

        cluster.execute("CREATE DATABASE db8_new")
        cluster.execute("CREATE EXTENSION pg_tde", "db8_new")
        tde.add_database_key_provider_file("keyring_file", keyfile=keyfile, dbname="db8_new")
        _set_db_key(cluster, "file_key", "keyring_file", "db8_new")

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

        _set_db_key(cluster, "file_key3", "keyring_file", "db8_new")
        tde.add_database_key_provider_kmip(
            "keyring_kmip",
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="db8_new",
        )
        _set_db_key(cluster, "file_key2", "keyring_kmip", "db8_new")
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101", "db8_new").strip() == "bond"
        assert cluster.fetchone("SELECT b FROM t2 WHERE a=101", "db8_new").strip() == "bond"

    def test_openbao_scenario9_default_and_local_keys(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 9 — default global vault key + local file provider."""
        _require_openbao(vault_config)
        keyfile = str(tmp_path / "bao_s9_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s9")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "vault_keyring9", tmp_path)
        tde.set_global_default_principal_key("vault_key9", "vault_keyring9")

        cluster.execute("CREATE DATABASE test9")
        cluster.execute("CREATE EXTENSION pg_tde", "test9")
        cluster.execute(
            "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t1 VALUES (101, 't1')",
            "test9",
        )
        tde.set_global_default_principal_key("vault_key91", "vault_keyring9")
        cluster.execute(
            "CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t2 VALUES (101, 't2')",
            "test9",
        )
        assert cluster.fetchone("SELECT b FROM t1 WHERE a=101", "test9").strip() == "t1"

        tde.add_database_key_provider_file("keyring_file9", keyfile=keyfile, dbname="test9")
        _set_db_key(cluster, "file_key9", "keyring_file9", "test9")
        cluster.execute(
            "CREATE TABLE t3(a INT PRIMARY KEY, b VARCHAR) USING tde_heap; "
            "INSERT INTO t3 VALUES (101, 't3')",
            "test9",
        )
        tde.set_global_principal_key("vault_key92", "vault_keyring9", dbname="test9")
        cluster.execute("SELECT pg_tde_delete_database_key_provider('keyring_file9')", "test9")
        cluster.execute("SELECT pg_tde_delete_key()", "test9")
        assert cluster.fetchone("SELECT COUNT(*) FROM t1", "test9") == "1"
        cluster.execute("SELECT pg_tde_delete_default_key()", "test9")

    def test_openbao_scenario10_delete_global_with_active_db_key(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 10 — DB uses global vault provider; survives restart."""
        _require_openbao(vault_config)
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s10")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "vault_keyring10", tmp_path)

        cluster.execute("CREATE DATABASE test10")
        cluster.execute("CREATE EXTENSION pg_tde", "test10")
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'vault_key10', 'vault_keyring10')",
            "test10",
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'vault_key10', 'vault_keyring10')",
            "test10",
        )
        cluster.execute(
            "CREATE TABLE t10(a INT) USING tde_heap; INSERT INTO t10 VALUES (10)",
            "test10",
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM t10", "test10").strip() == "10"

    def test_openbao_scenario12_delete_unused_global_provider(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """Scenario 12 — delete inactive vault global after default moves to file."""
        _require_openbao(vault_config)
        keyfile = str(tmp_path / "bao_s12_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s12")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "vault_keyring12", tmp_path)
        tde.set_global_default_principal_key("vault_key12", "vault_keyring12")
        tde.add_global_key_provider_file("keyring_file12", keyfile=keyfile)
        tde.set_global_default_principal_key("keyring_key12", "keyring_file12")

        cluster.execute("SELECT pg_tde_delete_global_key_provider('vault_keyring12')")
        names = [
            ln.strip()
            for ln in cluster.execute(
                "SELECT name FROM pg_tde_list_all_global_key_providers()"
            ).splitlines()
            if ln.strip()
        ]
        assert "vault_keyring12" not in names
        cluster.execute("SELECT pg_tde_delete_default_key()")
        cluster.execute("SELECT pg_tde_delete_global_key_provider('keyring_file12')")
