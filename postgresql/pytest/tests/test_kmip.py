"""
KMIP key provider tests (pytest).

Smoke, bash parity, CLI negatives, and advanced corner-case scenarios:

  - ``postgresql/automation/tests/pg_tde_functions_test.sh``
  - ``postgresql/t/066_multiple_db_diff_key_prov.pl`` (KMIP database)
  - ``postgresql/t/064_delete_key_providers.pl`` (global KMIP delete)
  - Multi-key churn, mixed topologies, partitions/TOAST, WAL, dump/restore

Builds that include `percona/pg_tde PR #595
<https://github.com/percona/pg_tde/pull/595>`_ use the C++ **libkmip**
(``subprojects/libkmip``, ``kmipclient::Kmip``) instead of the legacy C
API. These tests exercise that stack at runtime via:

  - **validate** — ``add_global_key_provider_kmip`` (TLS connect)
  - **register** — ``pg_tde_create_key_using_*`` (``op_register_key``)
  - **locate + get** — read encrypted data after restart (``op_locate_by_name``,
    ``op_get_key``)

Vault / OpenBao: ``tests/test_vault_providers.py`` (``@pytest.mark.vault``).

Prerequisites: see ``docs/kmip.md``, ``docs/key_provider_matrix.md``, and
``scripts/setup_cosmian_for_pytest.sh``.

Shared cross-server scenarios: ``tests/test_kmip_common_matrix.py`` (all profiles).
Advanced scenario matrix: ``docs/kmip_advanced.md``.
"""
from __future__ import annotations

import multiprocessing
import os
import re
import socket
import subprocess
import uuid
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.cosmian_kms import CosmianKmsServer, find_cosmian_binary
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


def _unique(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:10]}"


@pytest.fixture(scope="module")
def cosmian_kms_server(tmp_path_factory):
    if find_cosmian_binary() is None:
        yield None
        return
    work = tmp_path_factory.mktemp("cosmian_kms_adv")
    server = CosmianKmsServer.start(work)
    yield server
    if server is not None:
        server.stop()


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
        # Shared Docker KMIP keeps key material across runs (bash functions_test
        # also registers kmip_key2). Idempotent create matches PR #595 regression.
        create_fn = tde._first_func(["pg_tde_create_key_using_global_key_provider"])
        assert create_fn is not None
        tde._execute_create_global_key_allow_duplicate(
            f"SELECT {create_fn}('kmip_key2'::text, 'kmip_keyring2'::text)",
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
    """
    Offline ``pg_tde_change_key_provider`` with ``kmip`` type.

    Per pg_tde docs, change_* updates provider **connection** only; it does not
    migrate key material between provider types (file → kmip). Keys must already
    exist on the KMIP server under the same name.
    """

    def test_change_kmip_provider_connection_offline(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        kmip_config: KmipConfig,
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "ckp_kmip")
        tde = TdeManager(cluster)
        tde.add_database_key_provider_kmip(
            "ckp_kmip",
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="postgres",
        )
        tde.set_database_principal_key("ckp_key", "ckp_kmip", dbname="postgres")
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
            "ckp_kmip",
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

    @pytest.mark.kmip_build
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


class TestKmipKeyRotationChurn:
    """Repeated principal-key rotation with interleaved restarts and DML."""

    def test_four_rotations_all_generations_readable(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_ring_rot4")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_rot4")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_principal_key(f"{ring}_k0", ring)

        cluster.execute(
            "CREATE TABLE rot4(id INT PRIMARY KEY, tag TEXT) USING tde_heap; "
            f"INSERT INTO rot4 VALUES (0, 'gen0');"
        )

        for gen in range(1, 5):
            tde.rotate_principal_key(f"{ring}_k{gen}", ring)
            cluster.execute(
                f"INSERT INTO rot4 VALUES ({gen}, 'gen{gen}');"
            )
            if gen % 2 == 0:
                cluster.restart()
                cluster.wait_ready(timeout=90)

        assert cluster.fetchone("SELECT COUNT(*) FROM rot4") == "5"
        for gen in range(5):
            assert (
                cluster.fetchone(f"SELECT tag FROM rot4 WHERE id = {gen}").strip()
                == f"gen{gen}"
            )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT COUNT(*) FROM rot4") == "5"

    def test_default_key_rotation_file_then_kmip_chain(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """Rotate global *default* key across file → KMIP → second KMIP provider."""
        keyfile = str(tmp_path / "adv_default_file.per")
        ring_a = _unique("kmip_def_a")
        ring_b = _unique("kmip_def_b")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_def_rot")
        tde = TdeManager(cluster)

        tde.add_global_key_provider_file("file_ring", keyfile=keyfile)
        tde.set_global_default_principal_key("def_k_file", "file_ring")
        cluster.execute(
            "CREATE TABLE def_rot(a INT PRIMARY KEY, b TEXT) USING tde_heap; "
            "INSERT INTO def_rot VALUES (1, 'alpha');"
        )

        _add_global_kmip(tde, kmip_config, ring_a)
        tde.set_global_default_principal_key("def_k_kmip_a", ring_a)
        assert cluster.fetchone("SELECT b FROM def_rot WHERE a=1").strip() == "alpha"

        _add_global_kmip(tde, kmip_config, ring_b)
        tde.set_global_default_principal_key("def_k_kmip_b", ring_b)
        cluster.execute("INSERT INTO def_rot VALUES (2, 'beta');")

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT b FROM def_rot WHERE a=1").strip() == "alpha"
        assert cluster.fetchone("SELECT b FROM def_rot WHERE a=2").strip() == "beta"


class TestKmipMultiDatabaseIsolation:
    """Per-database KMIP keys must not leak or collide."""

    def test_three_databases_distinct_kmip_principal_keys(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_multi_ring")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_3db")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)

        for db, val in (("app_a", 10), ("app_b", 20), ("app_c", 30)):
            cluster.execute(f"CREATE DATABASE {db}")
            cluster.execute("CREATE EXTENSION pg_tde", db)
            tde.set_global_principal_key(f"key_{db}", ring, dbname=db)
            cluster.execute(
                f"CREATE TABLE t(v INT) USING tde_heap; INSERT INTO t VALUES ({val});",
                db,
            )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT v FROM t", "app_a").strip() == "10"
        assert cluster.fetchone("SELECT v FROM t", "app_b").strip() == "20"
        assert cluster.fetchone("SELECT v FROM t", "app_c").strip() == "30"

    def test_new_database_inherits_kmip_global_default_key(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_inherit")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_inherit")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_default_principal_key(f"{ring}_default", ring)

        cluster.execute("CREATE DATABASE childdb")
        cluster.execute("CREATE EXTENSION pg_tde", "childdb")
        cluster.execute(
            "CREATE TABLE inherited(id INT) USING tde_heap; "
            "INSERT INTO inherited VALUES (42);",
            "childdb",
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM inherited", "childdb").strip() == "42"


class TestKmipMixedProviderTopology:
    """Global KMIP + per-DB file/KMIP providers on one cluster."""

    def test_global_kmip_table_and_database_file_table(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        keyfile = str(tmp_path / "mixed_file.per")
        ring = _unique("kmip_mix_g")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_mixed_gf")
        tde = TdeManager(cluster)

        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_principal_key(f"{ring}_gkey", ring)
        cluster.execute(
            "CREATE TABLE global_t(a INT) USING tde_heap; INSERT INTO global_t VALUES (1);"
        )

        tde.add_database_key_provider_file("db_file_ring", keyfile=keyfile, dbname="postgres")
        tde.set_database_principal_key("db_file_key", "db_file_ring", dbname="postgres")
        cluster.execute(
            "CREATE TABLE local_t(a INT) USING tde_heap; INSERT INTO local_t VALUES (2);"
        )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM global_t").strip() == "1"
        assert cluster.fetchone("SELECT * FROM local_t").strip() == "2"

    def test_global_kmip_plus_database_scoped_kmip_on_second_db(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        g_ring = _unique("kmip_g_ring")
        d_ring = _unique("kmip_d_ring")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_gd")
        tde = TdeManager(cluster)

        _add_global_kmip(tde, kmip_config, g_ring)
        tde.set_global_principal_key(f"{g_ring}_key", g_ring)
        cluster.execute(
            "CREATE TABLE on_postgres(a INT) USING tde_heap; "
            "INSERT INTO on_postgres VALUES (100);"
        )

        cluster.execute("CREATE DATABASE isolated")
        cluster.execute("CREATE EXTENSION pg_tde", "isolated")
        tde.add_database_key_provider_kmip(
            d_ring,
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="isolated",
        )
        tde.set_database_principal_key(f"{d_ring}_key", d_ring, dbname="isolated")
        cluster.execute(
            "CREATE TABLE on_isolated(a INT) USING tde_heap; "
            "INSERT INTO on_isolated VALUES (200);",
            "isolated",
        )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT * FROM on_postgres").strip() == "100"
        assert cluster.fetchone("SELECT * FROM on_isolated", "isolated").strip() == "200"


class TestKmipStorageCornerCases:
    """Encrypted storage shapes that stress locate/get after rotation."""

    def test_partitioned_table_readable_after_kmip_rotation(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_part")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_part")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_principal_key(f"{ring}_k1", ring)

        cluster.execute(
            "CREATE TABLE parts(id INT, p INT) PARTITION BY RANGE (p); "
            "CREATE TABLE parts_p1 PARTITION OF parts FOR VALUES FROM (0) TO (50) "
            "USING tde_heap; "
            "CREATE TABLE parts_p2 PARTITION OF parts FOR VALUES FROM (50) TO (100) "
            "USING tde_heap; "
            "INSERT INTO parts SELECT i, i % 100 FROM generate_series(1, 80) i;"
        )
        tde.rotate_principal_key(f"{ring}_k2", ring)
        cluster.execute(
            "INSERT INTO parts SELECT i, i % 100 FROM generate_series(81, 120) i;"
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert cluster.fetchone("SELECT COUNT(*) FROM parts") == "120"
        assert cluster.fetchone("SELECT COUNT(*) FROM parts_p1") == "70"
        assert cluster.fetchone("SELECT COUNT(*) FROM parts_p2") == "50"

    def test_toast_wide_row_survives_triple_kmip_rotation(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_toast")
        payload = "Z" * 9000
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_toast")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_principal_key(f"{ring}_k0", ring)

        cluster.execute(
            "CREATE TABLE wide(id INT PRIMARY KEY, blob TEXT) USING tde_heap;"
        )
        cluster.execute(
            f"INSERT INTO wide VALUES (1, '{payload}');"
        )
        for i in range(1, 4):
            tde.rotate_principal_key(f"{ring}_k{i}", ring)
            cluster.execute(
                f"INSERT INTO wide VALUES ({i + 1}, '{payload}');"
            )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        for row_id in range(1, 5):
            got = cluster.fetchone(f"SELECT length(blob) FROM wide WHERE id={row_id}")
            assert got == "9000"


class TestKmipWalAndServerKey:
    """WAL encryption path with KMIP server key under churn."""

    def test_wal_encryption_triple_restart_with_bulk_dml(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_wal")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_wal3")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        tde.set_global_principal_key(f"{ring}_wal", ring)
        tde.enable_wal_encryption()

        cluster.execute(
            "CREATE TABLE wal_bulk(id INT) USING tde_heap;"
        )
        for batch in range(3):
            cluster.execute(
                f"INSERT INTO wal_bulk SELECT generate_series({batch * 1000}, "
                f"{batch * 1000 + 999});"
            )
            cluster.execute("CHECKPOINT;")
            cluster.restart()
            cluster.wait_ready(timeout=90)
            assert tde.is_wal_encrypted()

        assert cluster.fetchone("SELECT COUNT(*) FROM wal_bulk") == "3000"


class TestKmipFailureAndCornerCases:
    """Negative paths and catalog guardrails."""

    def test_cannot_add_duplicate_global_kmip_provider_name(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_dup_ring")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_dup_name")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, ring)
        with pytest.raises(RuntimeError):
            _add_global_kmip(tde, kmip_config, ring)

    def test_delete_database_kmip_provider_in_use_fails(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        ring = _unique("kmip_del_db")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_del_db")
        tde = TdeManager(cluster)
        tde.add_database_key_provider_kmip(
            ring,
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="postgres",
        )
        tde.set_database_principal_key(f"{ring}_key", ring, dbname="postgres")
        cluster.execute(
            "CREATE TABLE del_probe(id INT) USING tde_heap; INSERT INTO del_probe VALUES (1);"
        )
        with pytest.raises(RuntimeError):
            cluster.execute(
                f"SELECT pg_tde_delete_database_key_provider('{ring}')"
            )

    @pytest.mark.cosmian
    def test_read_fails_after_kmip_server_loses_all_keys(
        self,
        pg_factory,
        tmp_path: Path,
        cosmian_kms_server: CosmianKmsServer,
    ):
        if cosmian_kms_server is None:
            pytest.skip("cosmian_kms required for empty-server restart scenario")
        kmip = cosmian_kms_server.to_kmip_config()
        ring = _unique("kmip_evict")
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_evict")
        tde = TdeManager(cluster)
        tde.add_database_key_provider_kmip(
            ring,
            host=kmip.connect_host(),
            port=kmip.port,
            cert_path=kmip.client_cert,
            key_path=kmip.client_key,
            ca_path=kmip.server_ca,
            dbname="postgres",
        )
        tde.set_database_principal_key(f"{ring}_key", ring, dbname="postgres")
        cluster.execute(
            "CREATE TABLE evict_t(id INT) USING tde_heap; INSERT INTO evict_t VALUES (1);"
        )

        cluster.stop(check=False)
        cosmian_kms_server.restart_fresh()
        cluster.start()
        cluster.wait_ready(timeout=60)

        result = cluster.execute_allow_error("SELECT * FROM evict_t;")
        assert result.returncode != 0
        err = (result.stderr or "").lower()
        assert "not found" in err or "key provider" in err

    def test_non_tls_tcp_endpoint_rejected_on_add_provider(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_tcp_reject")
        cert, key, ca = kmip_config.sql_literal_paths()

        ctx = multiprocessing.get_context("fork")
        port_queue = ctx.Queue()
        proc = ctx.Process(
            target=_tcp_accept_close_worker,
            args=(port_queue,),
            daemon=True,
        )
        proc.start()
        try:
            port = port_queue.get(timeout=10)
            sql = (
                "SELECT pg_tde_add_global_key_provider_kmip("
                f"'bad-tcp', '127.0.0.1', {port}, '{cert}', '{key}', '{ca}');"
            )
            result = cluster.execute_allow_error(sql)
            assert result.returncode != 0
            assert re.search(
                r"ssl|handshake|connect|kmip|eof|bio",
                result.stderr or "",
                re.I,
            )
        finally:
            if proc.is_alive():
                proc.terminate()
                proc.join(timeout=5)


def _tcp_accept_close_worker(port_queue: multiprocessing.Queue) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    port_queue.put(srv.getsockname()[1])
    srv.settimeout(20.0)
    try:
        while True:
            try:
                conn, _ = srv.accept()
                conn.close()
            except (socket.timeout, OSError):
                break
    finally:
        srv.close()


@pytest.mark.slow
class TestKmipDumpRestore:
    """Logical dump/restore across databases with different KMIP key material."""

    def test_pg_dump_table_into_second_db_with_new_kmip_key(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        kmip_config: KmipConfig,
    ):
        ring_src = _unique("kmip_dump_src")
        ring_dst = _unique("kmip_dump_dst")
        dump_file = tmp_path / "kmip_dump.sql"
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_dump")
        tde = TdeManager(cluster)

        cluster.execute("CREATE DATABASE srcdb")
        cluster.execute("CREATE DATABASE dstdb")
        for db in ("srcdb", "dstdb"):
            cluster.execute("CREATE EXTENSION pg_tde", db)

        tde.add_database_key_provider_kmip(
            ring_src,
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="srcdb",
        )
        tde.set_database_principal_key(f"{ring_src}_key", ring_src, dbname="srcdb")
        cluster.execute(
            "CREATE TABLE cargo(id INT PRIMARY KEY, note TEXT) USING tde_heap; "
            "INSERT INTO cargo VALUES (7, 'shipped');",
            "srcdb",
        )

        tde.add_database_key_provider_kmip(
            ring_dst,
            host=kmip_config.connect_host(),
            port=kmip_config.port,
            cert_path=kmip_config.client_cert,
            key_path=kmip_config.client_key,
            ca_path=kmip_config.server_ca,
            dbname="dstdb",
        )
        tde.set_database_principal_key(f"{ring_dst}_key", ring_dst, dbname="dstdb")

        subprocess.run(
            [
                str(install_dir / "bin" / "pg_dump"),
                "-h", "127.0.0.1",
                "-p", str(cluster.port),
                "-d", "srcdb",
                "-t", "cargo",
                "-f", str(dump_file),
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
                "-d", "dstdb",
                "-f", str(dump_file),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        cluster.restart()
        cluster.wait_ready(timeout=90)
        assert (
            cluster.fetchone("SELECT note FROM cargo WHERE id=7", "dstdb").strip()
            == "shipped"
        )
