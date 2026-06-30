"""
HashiCorp Vault and OpenBao key provider tests (pytest).

Ports vault/OpenBao portions of:

  - ``postgresql/automation/tests/pg_tde_functions_test.sh``
  - ``postgresql/automation/tests/pg_tde_open_bao_tests.sh``
  - ``postgresql/t/066_multiple_db_diff_key_prov.pl`` (vault global on db1)
  - ``postgresql/t/064_delete_key_providers.pl`` (vault delete paths)

KMIP coverage is in ``tests/test_kmip.py``.

Prerequisites: ``docs/vault.md``, ``scripts/setup_vault_for_pytest.sh`` or
``scripts/install_openbao.sh`` and ``scripts/setup_openbao_for_pytest.sh``.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.vault import VaultConfig

pytestmark = pytest.mark.encryption


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
    tde: TdeManager,
    vault: VaultConfig,
    provider_name: str,
    tmp_path: Path,
) -> None:
    tde.add_global_key_provider_vault(
        provider_name,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
    )


def _add_db_vault(
    tde: TdeManager,
    vault: VaultConfig,
    provider_name: str,
    tmp_path: Path,
    dbname: str,
) -> None:
    tde.add_database_key_provider_vault(
        provider_name,
        vault_url=vault.addr,
        secret_mount_point=vault.secret_mount,
        token_path=vault.token_sql_arg(tmp_path),
        ca_path=vault.ca_path,
        namespace=vault.namespace,
        dbname=dbname,
    )


def _add_global_kmip(tde: TdeManager, kmip, provider_name: str) -> None:
    tde.add_global_key_provider_kmip(
        provider_name,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )


def _list_global_names(cluster: PgCluster) -> list[str]:
    out = cluster.execute(
        "SELECT name FROM pg_tde_list_all_global_key_providers()"
    )
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def _run_change_kp(install_dir: Path, *args: str) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = (
        f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    return subprocess.run(
        [str(install_dir / "bin" / "pg_tde_change_key_provider"), *args],
        capture_output=True,
        text=True,
        env=env,
    )


def _vault_change_kp_args(
    cluster: PgCluster,
    vault: VaultConfig,
    provider_name: str,
    *,
    token_path: str,
) -> list[str]:
    db_oid = cluster.fetchone(
        "SELECT oid FROM pg_database WHERE datname = 'postgres'"
    )
    args = [
        "-D",
        str(cluster.data_dir),
        str(db_oid),
        provider_name,
        "vault-v2",
        vault.addr,
        vault.secret_mount,
        token_path,
    ]
    if vault.ca_path:
        args.append(vault.ca_path)
    if vault.namespace.strip():
        args.append(vault.namespace)
    return args


@pytest.mark.vault
class TestHashicorpVaultKeyProvider:
    """Vault dev server or ``setup_vault.sh`` (no namespace)."""

    def test_vault_global_provider_restart_read(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_smoke")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "vault_smoke_ring", tmp_path)
        tde.set_global_principal_key("vault_smoke_key", "vault_smoke_ring")
        assert tde.principal_key_name() == "vault_smoke_key"

        cluster.execute(
            "CREATE TABLE vault_t1(id INT) USING tde_heap; "
            "INSERT INTO vault_t1 SELECT generate_series(1, 150);"
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM vault_t1") == "150"

    def test_vault_key_rotation(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_rot")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "vault_rot_ring", tmp_path)
        tde.set_global_principal_key("vault_rot_a", "vault_rot_ring")
        cluster.execute(
            "CREATE TABLE vault_rot_t(id INT) USING tde_heap; "
            "INSERT INTO vault_rot_t VALUES (1);"
        )
        tde.rotate_principal_key("vault_rot_b", "vault_rot_ring")
        assert tde.principal_key_name() == "vault_rot_b"
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM vault_rot_t") == "1"

    def test_vault_and_file_multi_database(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """functions_test scenario 2 — db1 vault, db3 file (no kmip)."""
        keyfile = str(tmp_path / "vault_multi_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_multi_db")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "vault_keyring2", tmp_path)
        tde.add_global_key_provider_file("file_keyring2", keyfile=keyfile)

        for db in ("db1", "db3"):
            cluster.execute(f"CREATE DATABASE {db}")
            cluster.execute("CREATE EXTENSION pg_tde", db)

        tde.set_database_global_key("vault_key2", "vault_keyring2", dbname="db1")
        tde.set_database_global_key("file_key2", "file_keyring2", dbname="db3")

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "db1")
        cluster.execute("CREATE TABLE t3(a INT) USING tde_heap", "db3")
        cluster.execute("INSERT INTO t1 VALUES (100)", "db1")
        cluster.execute("INSERT INTO t3 VALUES (300)", "db3")

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "db1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t3", "db3").strip() == "300"

    def test_vault_database_scoped_provider(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_db_scope")
        tde = TdeManager(cluster)
        cluster.execute("CREATE DATABASE sbtest2")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest2")

        _add_db_vault(tde, vault_config, "vault_keyring4", tmp_path, "sbtest2")
        tde.set_database_principal_key(
            "vault_key4", "vault_keyring4", dbname="sbtest2"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (42)",
            "sbtest2",
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "sbtest2").strip() == "42"

    def test_delete_unused_vault_global_provider(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        keyfile = str(tmp_path / "vault_del_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_del")
        tde = TdeManager(cluster)
        tde.add_global_key_provider_file("file_ring", keyfile=keyfile)
        _add_global_vault(tde, vault_config, "vault_keyring3", tmp_path)
        tde.set_global_principal_key("file_key", "file_ring")

        cluster.execute(
            "SELECT pg_tde_delete_global_key_provider('vault_keyring3')"
        )
        assert "vault_keyring3" not in _list_global_names(cluster)

    def test_delete_vault_global_provider_in_use_fails(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_del_block")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "vault_in_use", tmp_path)
        tde.set_global_principal_key("vault_active", "vault_in_use")
        cluster.execute(
            "CREATE TABLE vdel(id INT) USING tde_heap; INSERT INTO vdel VALUES (1)"
        )

        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('vault_in_use')"
            )

    def test_change_vault_provider_connection_offline(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        vault_config: VaultConfig,
    ):
        """Offline CLI updates Vault connection; keys must already be in Vault."""
        cluster = _tde_cluster(pg_factory, tmp_path, "ckp_vault")
        tde = TdeManager(cluster)
        _add_db_vault(tde, vault_config, "ckp_vault", tmp_path, "postgres")
        tde.set_database_principal_key("ckp_key", "ckp_vault", dbname="postgres")
        cluster.execute(
            "CREATE TABLE ckp_vault_t(id INT) USING tde_heap; "
            "INSERT INTO ckp_vault_t VALUES (7);"
        )
        cluster.execute("CHECKPOINT")
        token_path = vault_config.token_sql_arg(tmp_path)
        token_path_new = str(tmp_path / "ckp_vault_token_new")
        shutil.copy(token_path, token_path_new)
        cluster.stop(check=False)

        result = _run_change_kp(
            install_dir,
            *_vault_change_kp_args(
                cluster,
                vault_config,
                "ckp_vault",
                token_path=token_path_new,
            ),
        )
        assert result.returncode == 0, (
            f"change_key_provider vault-v2 failed:\n{result.stdout}\n{result.stderr}"
        )

        cluster.start()
        cluster.wait_ready(timeout=60)
        cluster.execute("SELECT pg_tde_verify_key();")
        assert cluster.fetchone("SELECT * FROM ckp_vault_t").strip() == "7"


@pytest.mark.vault
@pytest.mark.openbao
class TestOpenBaoKeyProvider:
    """
    OpenBao with KV mount ``pg_tde`` and namespace ``pg_tde_ns1/``.

    Requires ``--vault-namespace`` (set by ``setup_openbao_for_pytest.sh``).
    """

    def test_openbao_database_provider_outside_db_catalog_scope(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
    ):
        """open_bao_tests scenario 1 — DB-scoped vault provider on db1."""
        assert vault_config.namespace.strip()
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_s1")
        tde = TdeManager(cluster)
        cluster.execute("CREATE DATABASE db1")
        cluster.execute("CREATE EXTENSION pg_tde", "db1")

        _add_db_vault(tde, vault_config, "vault_keyring", tmp_path, "db1")
        tde.set_database_principal_key(
            "vault_key1", "vault_keyring", dbname="db1"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (1)",
            "db1",
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "db1").strip() == "1"

    def test_openbao_global_vault_multi_db_with_kmip_and_file(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config,
    ):
        """open_bao_tests scenario 2 — db1 vault, db2 kmip, db3 file."""
        keyfile = str(tmp_path / "bao_multi_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_multi")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "vault_keyring2", tmp_path)
        _add_global_kmip(tde, kmip_config, "kmip_keyring2")
        tde.add_global_key_provider_file("file_keyring2", keyfile=keyfile)

        for db in ("db1", "db2", "db3"):
            cluster.execute(f"CREATE DATABASE {db}")
            cluster.execute("CREATE EXTENSION pg_tde", db)

        for db, key, ring in (
            ("db1", "vault_key2", "vault_keyring2"),
            ("db2", "kmip_key2", "kmip_keyring2"),
            ("db3", "file_key2", "file_keyring2"),
        ):
            tde.set_database_global_key(key, ring, dbname=db)

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "db1")
        cluster.execute("CREATE TABLE t2(a INT) USING tde_heap", "db2")
        cluster.execute("CREATE TABLE t3(a INT) USING tde_heap", "db3")
        cluster.execute("INSERT INTO t1 VALUES (100)", "db1")
        cluster.execute("INSERT INTO t2 VALUES (50)", "db2")
        cluster.execute("INSERT INTO t3 VALUES (300)", "db3")

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "db1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t2", "db2").strip() == "50"
        assert cluster.fetchone("SELECT * FROM t3", "db3").strip() == "300"

    def test_openbao_local_db_vault_and_global_kmip_default(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        kmip_config,
    ):
        """open_bao_tests scenario 3 — test1 vault DB provider, test2 kmip default."""
        cluster = _tde_cluster(pg_factory, tmp_path, "bao_default")
        tde = TdeManager(cluster)

        _add_global_kmip(tde, kmip_config, "kmip_keyring3")
        tde.set_global_default_principal_key("kmip_key3", "kmip_keyring3")

        cluster.execute("CREATE DATABASE test1")
        cluster.execute("CREATE DATABASE test2")
        cluster.execute("CREATE EXTENSION pg_tde", "test1")
        cluster.execute("CREATE EXTENSION pg_tde", "test2")

        _add_db_vault(tde, vault_config, "vault_keyring3", tmp_path, "test1")
        tde.set_database_principal_key(
            "vault_key3", "vault_keyring3", dbname="test1"
        )

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "test1")
        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "test2")
        cluster.execute("INSERT INTO t1 VALUES (100)", "test1")
        cluster.execute("INSERT INTO t1 VALUES (1)", "test2")

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "test1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t1", "test2").strip() == "1"
