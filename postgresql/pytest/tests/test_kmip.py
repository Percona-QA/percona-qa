"""
KMIP key provider tests (pytest).

Ports the KMIP portions of:

  - ``postgresql/automation/tests/pg_tde_functions_test.sh``
  - ``postgresql/t/066_multiple_db_diff_key_prov.pl`` (KMIP database)
  - ``postgresql/t/064_delete_key_providers.pl`` (global KMIP delete)
  - TAP 067–072 (database/global KMIP provider + data integrity)

Builds that include `percona/pg_tde PR #595
<https://github.com/percona/pg_tde/pull/595>`_ use the C++ **libkmip**
(``subprojects/libkmip``, ``kmipclient::Kmip``) instead of the legacy C
API. These tests exercise that stack at runtime via:

  - **validate** — ``add_global_key_provider_kmip`` (TLS connect)
  - **register** — ``pg_tde_create_key_using_*`` (``op_register_key``)
  - **locate + get** — read encrypted data after restart (``op_locate_by_name``,
    ``op_get_key``)

Vault / OpenBao: ``tests/test_vault_providers.py`` (``@pytest.mark.vault``).

Prerequisites: see ``docs/kmip.md`` and ``scripts/setup_kmip_for_pytest.sh``.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig

pytestmark = [pytest.mark.kmip, pytest.mark.encryption]


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


def _add_global_kmip(tde: TdeManager, kmip: KmipConfig, provider_name: str) -> None:
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


class TestKmipKeyProviderBasics:
    """Smoke tests: add provider, principal key, encrypted table, restart."""

    def test_kmip_global_provider_register_locate_get_after_restart(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_config: KmipConfig,
    ):
        """
        PR #595 path: validate on add, register on create_key, locate+get on read.

        After restart the cluster must still decrypt rows (exercises GET after
        LOCATE in the new kmipclient stack).
        """
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_smoke")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "kmip_smoke_ring")
        tde.set_global_principal_key("kmip_smoke_key", "kmip_smoke_ring")
        assert tde.list_key_providers() >= 1
        assert tde.principal_key_name() == "kmip_smoke_key"

        cluster.execute(
            "CREATE TABLE kmip_t1(id INT) USING tde_heap; "
            "INSERT INTO kmip_t1 SELECT generate_series(1, 200);"
        )
        assert cluster.fetchone("SELECT COUNT(*) FROM kmip_t1") == "200"

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM kmip_t1") == "200"
        assert tde.principal_key_name() == "kmip_smoke_key"

    def test_kmip_key_rotation_register_second_key(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """Second key name on the same KMIP provider (another REGISTER)."""
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_rot")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "kmip_rot_ring")
        tde.set_global_principal_key("kmip_rot_a", "kmip_rot_ring")
        cluster.execute(
            "CREATE TABLE kmip_rot_t(id INT) USING tde_heap; "
            "INSERT INTO kmip_rot_t VALUES (1);"
        )
        tde.rotate_principal_key("kmip_rot_b", "kmip_rot_ring")
        assert tde.principal_key_name() == "kmip_rot_b"
        cluster.execute("INSERT INTO kmip_rot_t VALUES (2);")
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM kmip_rot_t") == "2"


class TestKmipBashParityScenarios:
    """
    Scenarios aligned with ``pg_tde_functions_test.sh`` / TAP suite.

    Uses file provider alongside KMIP where the bash script also uses vault.
    """

    def test_multiple_databases_file_and_kmip_providers(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """
        Port of functions_test scenario 2 / t/066 (KMIP on db2 only).

        db1 → file principal key; db2 → KMIP principal key; both survive restart.
        """
        keyfile = str(tmp_path / "multi_kmip_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_multi_db")
        tde = TdeManager(cluster)

        tde.add_global_key_provider_file(
            provider_name="file_keyring2", keyfile=keyfile
        )
        _add_global_kmip(tde, kmip_config, "kmip_keyring2")

        for db in ("db1", "db2"):
            cluster.execute(f"CREATE DATABASE {db}")
            cluster.execute(f"CREATE EXTENSION pg_tde", db)

        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'file_key2', 'file_keyring2')",
            "db1",
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'file_key2', 'file_keyring2')",
            "db1",
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'kmip_key2', 'kmip_keyring2')",
            "db2",
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'kmip_key2', 'kmip_keyring2')",
            "db2",
        )

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "db1")
        cluster.execute("CREATE TABLE t2(a INT) USING tde_heap", "db2")
        cluster.execute("INSERT INTO t1 SELECT generate_series(1, 100)", "db1")
        cluster.execute("INSERT INTO t2 SELECT generate_series(1, 50)", "db2")

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM t1", "db1") == "100"
        assert cluster.fetchone("SELECT COUNT(*) FROM t2", "db2") == "50"

    def test_kmip_global_default_principal_key_two_databases(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """
        Port of functions_test scenario 3: global default key in KMIP.

        test2 inherits default; test1 uses its own database vault/file key in bash —
        here test1 uses a database-scoped file provider only.
        """
        keyfile = str(tmp_path / "kmip_default_db1.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_default")
        tde = TdeManager(cluster)

        _add_global_kmip(tde, kmip_config, "kmip_keyring3")
        tde.set_global_default_principal_key("kmip_key3", "kmip_keyring3")

        cluster.execute("CREATE DATABASE test1")
        cluster.execute("CREATE DATABASE test2")
        cluster.execute("CREATE EXTENSION pg_tde", "test1")
        cluster.execute("CREATE EXTENSION pg_tde", "test2")

        cluster.execute(
            f"SELECT pg_tde_add_database_key_provider_file("
            f"'file_local', '{keyfile}')",
            "test1",
        )
        tde.set_database_principal_key("file_key3", "file_local", dbname="test1")

        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "test1")
        cluster.execute("CREATE TABLE t1(a INT) USING tde_heap", "test2")
        cluster.execute("INSERT INTO t1 VALUES (100)", "test1")
        cluster.execute("INSERT INTO t1 VALUES (1)", "test2")

        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "test1").strip() == "100"
        assert cluster.fetchone("SELECT * FROM t1", "test2").strip() == "1"

    def test_kmip_database_scoped_provider(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """Port of functions_test: local KMIP provider on ``sbtest2`` database."""
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_db_scope")
        tde = TdeManager(cluster)
        cluster.execute("CREATE DATABASE sbtest2")
        cluster.execute("CREATE EXTENSION pg_tde", "sbtest2")

        tde.add_database_key_provider_kmip(
            "kmip_keyring4",
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="sbtest2",
        )
        tde.set_database_principal_key(
            "kmip_key4", "kmip_keyring4", dbname="sbtest2"
        )
        cluster.execute(
            "CREATE TABLE t1(a INT) USING tde_heap; INSERT INTO t1 VALUES (42)",
            "sbtest2",
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM t1", "sbtest2").strip() == "42"


class TestKmipDeleteKeyProvider:
    """KMIP variants of ``TestPgTdeDeleteKeyProvider`` (t/064)."""

    def test_delete_unused_kmip_global_provider(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        keyfile = str(tmp_path / "del_kmip_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_del_unused")
        tde = TdeManager(cluster)
        tde.add_global_key_provider_file("file_ring", keyfile=keyfile)
        _add_global_kmip(tde, kmip_config, "kmip_keyring3")
        tde.set_global_principal_key("file_key", "file_ring")

        cluster.execute("SELECT pg_tde_delete_global_key_provider('kmip_keyring3')")
        names = _list_global_names(cluster)
        assert "kmip_keyring3" not in names
        assert "file_ring" in names

    def test_delete_kmip_global_provider_in_use_fails(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_del_block")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "kmip_in_use")
        tde.set_global_principal_key("kmip_active", "kmip_in_use")
        cluster.execute("CREATE TABLE kdel(id INT) USING tde_heap; INSERT INTO kdel VALUES (1)")

        with pytest.raises(RuntimeError):
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('kmip_in_use')"
            )


class TestKmipChangeKeyProviderCLI:
    """Offline ``pg_tde_change_key_provider`` with ``kmip`` type (bash utility)."""

    def test_change_key_provider_to_kmip_offline(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        kmip_config: KmipConfig,
    ):
        keyfile = str(tmp_path / "ckp_kmip_file.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "ckp_kmip")
        cluster.execute(
            f"SELECT pg_tde_add_database_key_provider_file("
            f"'ckp_file', '{keyfile}')"
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'ckp_key', 'ckp_file')"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'ckp_key', 'ckp_file')"
        )
        cluster.execute(
            "CREATE TABLE ckp_kmip_t(id INT) USING tde_heap; "
            "INSERT INTO ckp_kmip_t VALUES (7);"
        )
        db_oid = int(cluster.fetchone(
            "SELECT oid FROM pg_database WHERE datname = 'postgres'"
        ))
        cluster.stop(check=False)

        args = [
            "-D", str(cluster.data_dir),
            str(db_oid),
            "ckp_file",
            "kmip",
            kmip_config.connect_host(),
            str(kmip_config.port),
            kmip_config.client_cert,
            kmip_config.client_key,
        ]
        if kmip_config.server_ca:
            args.append(kmip_config.server_ca)
        result = _run_change_kp(install_dir, *args)
        assert result.returncode == 0, (
            f"change_key_provider kmip failed:\n{result.stdout}\n{result.stderr}"
        )

        cluster.start()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM ckp_kmip_t").strip() == "7"


class TestKmipLibkmipClientPr595:
    """
    Regression checks aimed at `PR #595
    <https://github.com/percona/pg_tde/pull/595>`_ (C++ kmipclient), which
    fixes `PG-2125 <https://perconadev.atlassian.net/browse/PG-2125>`_.

    Full KMIP regression lifecycle tests live in ``test_external_key_provider_regressions.py``.
    Negative cases here document the new error translation (``kmip_run`` /
    ``could not connect to KMIP server``) instead of silent BIO failures.
    """

    def test_kmip_invalid_server_host_rejected_on_add_provider(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_bad_host")
        tde = TdeManager(cluster)
        with pytest.raises(RuntimeError) as exc:
            tde.add_global_key_provider_kmip(
                "bad_ring",
                host="192.0.2.1",
                port=kmip_config.port,
                cert_path=kmip_config.client_cert,
                key_path=kmip_config.client_key,
                ca_path=kmip_config.server_ca,
            )
        msg = str(exc.value).lower()
        assert "kmip" in msg or "connect" in msg or "ssl" in msg

    def test_kmip_build_links_cpp_kmipclient(
        self, install_dir: Path,
    ):
        """
        When pg_tde is built with PR #595, ``pg_tde.so`` links C++ (kmipclient).

        Skip on older builds that still use the static C libkmip only.
        """
        so = install_dir / "lib" / "pg_tde.so"
        if not so.is_file():
            libdir = install_dir / "lib"
            candidates = list(libdir.glob("**/pg_tde.so"))
            if not candidates:
                pytest.skip(f"pg_tde.so not under {install_dir}")
            so = candidates[0]

        proc = subprocess.run(
            ["ldd", str(so)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            pytest.skip(f"ldd failed on {so}: {proc.stderr}")

        out = (proc.stdout + proc.stderr).lower()
        if "libstdc++" not in out and "libc++" not in out:
            pytest.skip(
                "pg_tde.so has no C++ runtime dependency — likely pre-PR-595 build"
            )
        assert "kmip" in out or "ssl" in out or "crypto" in out
