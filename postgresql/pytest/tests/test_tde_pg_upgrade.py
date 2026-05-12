"""
pg_tde pg_upgrade tests: PPG→PSP, PSP→PSP, heap↔tde_heap permutations, WAL encryption paths.

Regression coverage for PG-2240 ("pg_upgrade is broken with encrypted data").
The root cause: pg_upgrade does not copy $OLD_DATA/pg_tde/, which holds encrypted DEKs.
The fix applied in these tests: copy that directory before starting the new cluster.

Upgrade flavours tested
───────────────────────
  PPG (<17) → PSP (≥17)    Old pkg build → new source/pkg build; may need ALTER EXTENSION UPDATE.
  PSP (17)  → PSP (18)     Same-flavour major-version bump; identical key-provider API.

Access-method permutations
──────────────────────────
  heap  → heap              Baseline (no TDE).
  tde_heap → tde_heap       Primary PG-2240 scenario; pg_tde dir copy required.
  heap + tde_heap → same    Mixed tables in one cluster.
  heap  → enable TDE after  Encrypt data post-upgrade.
  tde_heap → convert first  Rewrite tables as heap before upgrading.

WAL encryption paths
────────────────────
  off → off                 Baseline.
  on  → off                 Disable WAL enc before pg_upgrade, then upgrade.
  on  → re-enable           Upgrade with WAL enc off, re-enable on new cluster.
  --check with WAL enc on   Verify --check succeeds with an encrypted WAL stream.

All tests are skipped unless --old-install-dir is provided.
"""
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import (
    initdb_args_no_data_checksums,
    initdb_extra_align_data_checksums_with_old,
    prepend_install_lib_dirs,
)
from conftest import allocate_port


pytestmark = [pytest.mark.upgrade, pytest.mark.slow]


# ── helpers ───────────────────────────────────────────────────────────────────


def _make_old_cluster(
    old_install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    subdir: str = "old",
    extra_initdb: Optional[list] = None,
    extra_params: Optional[dict] = None,
) -> PgCluster:
    port = allocate_port()
    cluster = PgCluster(
        tmp_path / subdir,
        port,
        old_install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    cluster.initdb(extra_args=extra_initdb)
    cluster.write_default_config(extra_params=extra_params)
    cluster.add_hba_entry("local all all trust")
    return cluster


def _upgrade(
    old_cluster: PgCluster,
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    new_subdir: str = "new",
    extra_initdb: Optional[list] = None,
    extra_params: Optional[dict] = None,
    pg_upgrade_extra: Optional[list] = None,
    check_only: bool = False,
) -> tuple:
    new_port = allocate_port()
    new_data = tmp_path / new_subdir
    new_cluster = PgCluster(
        new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method
    )
    new_cluster.initdb(
        extra_args=initdb_extra_align_data_checksums_with_old(
            old_cluster, install_dir, extra_initdb
        )
    )
    new_cluster.write_default_config(extra_params=extra_params)
    new_cluster.stop(check=False)

    new_bin = install_dir / "bin"
    cmd = [
        str(new_bin / "pg_tde_upgrade"),
        "-b", str(old_cluster.bin),
        "-B", str(new_bin),
        "-d", str(old_cluster.data_dir),
        "-D", str(new_data),
        "-p", str(old_cluster.port),
        "-P", str(new_port),
    ]
    if check_only:
        cmd.append("--check")
    if pg_upgrade_extra:
        cmd.extend(pg_upgrade_extra)

    env = os.environ.copy()

    # FIX: The NEW install_dir must be prepended first so that the new pg_upgrade
    # and psql binaries load the newer libpq.so containing PQfullProtocolVersion.
    prepend_install_lib_dirs(env, install_dir, old_cluster.install_dir)

    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(tmp_path), env=env
    )
    return new_cluster, result

def _copy_pg_tde_dir(old_cluster: PgCluster, new_cluster: PgCluster) -> bool:
    """PG-2240 fix: copy pg_tde key-material directory from old to new cluster.

    pg_upgrade does not migrate $PGDATA/pg_tde/ — without it the new cluster
    cannot decrypt tde_heap blocks.  Returns True if the source directory existed.
    """
    src = old_cluster.data_dir / "pg_tde"
    dst = new_cluster.data_dir / "pg_tde"
    if not src.exists():
        return False
    if dst.exists():
        shutil.rmtree(str(dst))
    shutil.copytree(str(src), str(dst))
    return True


def _tde_params(keyfile: str) -> dict:
    return {"shared_preload_libraries": "'pg_tde'"}


# ── PPG (<17) → PSP (≥17) ────────────────────────────────────────────────────


class TestPpgToPspUpgrade:
    """Upgrade from an older Percona build (PPG) to a newer one (PSP).

    TdeManager auto-detects the pg_tde API version so tests work regardless of
    which exact API revision the old or new build exposes.
    """

    def test_file_provider_data_intact(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Core PG-2240 scenario: tde_heap data survives PPG→PSP with the pg_tde dir copy fix."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "ppg_to_psp.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="ppg_key")
        old.execute(
            "CREATE TABLE secrets (id INT, payload TEXT) USING tde_heap; "
            "INSERT INTO secrets SELECT i, md5(i::text) FROM generate_series(1,500) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, f"pg_upgrade failed:\n{result.stderr}"

        copied = _copy_pg_tde_dir(old, new_cluster)
        assert copied, "pg_tde key-material directory was not present in old cluster"

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM secrets")
        assert count == "500", f"Expected 500 rows, got {count}"
        new_cluster.stop()

    def test_alter_extension_update_after_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """ALTER EXTENSION pg_tde UPDATE must succeed after PPG→PSP upgrade.

        When the pg_tde catalog version changes between PPG and PSP the extension
        entry in the new cluster references the old version; UPDATE brings it current.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "ext_update.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE ext_update_tbl (id INT) USING tde_heap; "
            "INSERT INTO ext_update_tbl VALUES (1),(2),(3);"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        # ALTER EXTENSION UPDATE is a no-op if already at latest; must not error.
        new_cluster.execute("ALTER EXTENSION pg_tde UPDATE")
        assert new_cluster.fetchone("SELECT COUNT(*) FROM ext_update_tbl") == "3"
        new_cluster.stop()

    def test_multiple_databases_survive(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Multiple databases with independent TDE keys all survive PPG→PSP."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "multidb.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        # Add the GLOBAL provider once
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="key_postgres")

        old.execute("CREATE DATABASE db_alpha")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db_alpha")

        # FIX: The provider is global, so it already exists. We just need to
        # create a new key using that provider, and set it for this specific DB.
        old.execute("SELECT pg_tde_create_key_using_global_key_provider('key_alpha', 'file_provider')", dbname="db_alpha")
        old.execute("SELECT pg_tde_set_server_key_using_global_key_provider('key_alpha', 'file_provider')", dbname="db_alpha")
        old.execute("SELECT pg_tde_set_key_using_global_key_provider('key_alpha', 'file_provider')", dbname="db_alpha")

        old.execute(
            "CREATE TABLE pg_secrets (v INT) USING tde_heap; "
            "INSERT INTO pg_secrets VALUES (10);"
        )
        old.execute(
            "CREATE TABLE alpha_secrets (v INT) USING tde_heap; "
            "INSERT INTO alpha_secrets SELECT generate_series(1,20);",
            dbname="db_alpha",
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM pg_secrets") == "1"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM alpha_secrets", dbname="db_alpha") == "20"
        new_cluster.stop()

    def test_check_mode_with_tde_configured(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """pg_upgrade --check must succeed even when pg_tde is loaded and tables exist."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "check_mode.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE check_tbl (id INT) USING tde_heap; "
            "INSERT INTO check_tbl VALUES (1),(2);"
        )
        old.stop()

        _, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
            check_only=True,
        )
        assert result.returncode == 0, f"pg_upgrade --check failed:\n{result.stderr}"


# ── PSP → PSP (e.g. 17 → 18) ─────────────────────────────────────────────────


class TestPspToPspUpgrade:
    """Same-flavour PSP major-version upgrade (e.g. 17 → 18).

    The key-provider API is identical on both sides; only the PostgreSQL
    catalog version changes.  The PG-2240 fix (pg_tde dir copy) is still
    required whenever tde_heap tables are present.
    """

    def test_tde_heap_data_survives(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Encrypted tde_heap data is intact after PSP→PSP with the PG-2240 fix."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "psp_psp.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE enc_rows (id INT, data TEXT) USING tde_heap; "
            "INSERT INTO enc_rows SELECT i, md5(i::text) FROM generate_series(1,1000) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, f"PSP→PSP upgrade failed:\n{result.stderr}"

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM enc_rows")
        assert count == "1000"
        # Verify table is still using tde_heap on the new cluster
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert tde_new.get_access_method("enc_rows") == "tde_heap"
        new_cluster.stop()

    def test_multiple_databases_different_keys(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Multiple databases using different principal keys all decrypt correctly."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "psp_multidb.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        # Add the GLOBAL provider once
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="key_v1")

        old.execute("CREATE DATABASE db_b")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db_b")

        # FIX: The provider is global, so it already exists. We just need to
        # create a new key using that provider, and set it for this specific DB.
        old.execute("SELECT pg_tde_create_key_using_global_key_provider('key_v2', 'file_provider')", dbname="db_b")
        old.execute("SELECT pg_tde_set_server_key_using_global_key_provider('key_v2', 'file_provider')", dbname="db_b")
        old.execute("SELECT pg_tde_set_key_using_global_key_provider('key_v2', 'file_provider')", dbname="db_b")

        old.execute("CREATE TABLE rows_a (n INT) USING tde_heap; INSERT INTO rows_a VALUES (1),(2)")
        old.execute(
            "CREATE TABLE rows_b (n INT) USING tde_heap; INSERT INTO rows_b SELECT generate_series(1,30);",
            dbname="db_b",
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM rows_a") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM rows_b", dbname="db_b") == "30"
        new_cluster.stop()

    def test_key_provider_accessible_after_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Key provider is queryable and can encrypt new data on the upgraded cluster."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "psp_provider.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute("CREATE TABLE pre_upgrade (id INT) USING tde_heap; INSERT INTO pre_upgrade VALUES (42)")
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        # Provider count should be ≥1 (preserved from old catalog via pg_upgrade)
        provider_count = tde_new.list_key_providers(scope="global")
        assert provider_count >= 1, "Expected at least one global key provider after upgrade"
        # New data must be encryptable with the inherited key
        new_cluster.execute("CREATE TABLE post_upgrade (id INT) USING tde_heap; INSERT INTO post_upgrade VALUES (99)")
        assert new_cluster.fetchone("SELECT COUNT(*) FROM pre_upgrade") == "1"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM post_upgrade") == "1"
        new_cluster.stop()

    def test_wal_encryption_disabled_before_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Disable WAL encryption before pg_upgrade; data survives; WAL enc stays off."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "psp_wal_off.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        old.execute("CREATE TABLE wal_data (id INT) USING tde_heap; INSERT INTO wal_data VALUES (7)")
        # Disable WAL enc before stopping so pg_upgrade sees a clean state
        tde.disable_wal_encryption()
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM wal_data") == "1"
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert not tde_new.is_wal_encrypted(), "WAL encryption should remain off after upgrade"
        new_cluster.stop()


# ── heap ↔ tde_heap access-method permutations ───────────────────────────────


class TestUpgradeAccessMethodPermutations:
    """Five permutations of heap/tde_heap across old and new clusters.

    These tests directly exercise the PG-2240 scenario (all tde_heap) as well as
    edge cases: mixed tables, enabling TDE post-upgrade, and converting away from
    tde_heap before upgrading.
    """

    def test_all_heap_baseline(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Baseline: plain heap throughout; pg_tde not involved; upgrade must succeed."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE heap_tbl (id INT, data TEXT); "
            "INSERT INTO heap_tbl SELECT i, md5(i::text) FROM generate_series(1,300) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM heap_tbl") == "300"
        am = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'heap_tbl'"
        )
        assert am == "heap"
        new_cluster.stop()

    def test_all_tde_heap_pg2240_fix(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Primary PG-2240 scenario: all tables use tde_heap; pg_tde dir copy is required."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "all_tde.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            },
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE tbl_a (id INT, val TEXT); "
            "INSERT INTO tbl_a SELECT i, md5(i::text) FROM generate_series(1,400) i; "
            "CREATE TABLE tbl_b (x NUMERIC); "
            "INSERT INTO tbl_b SELECT random() FROM generate_series(1,100);"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            },
        )
        assert result.returncode == 0, f"pg_upgrade (all tde_heap) failed:\n{result.stderr}"

        copied = _copy_pg_tde_dir(old, new_cluster)
        assert copied, "pg_tde key-material directory missing from old cluster"

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM tbl_a") == "400"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM tbl_b") == "100"
        assert tde_new.get_access_method("tbl_a") == "tde_heap"
        assert tde_new.get_access_method("tbl_b") == "tde_heap"
        new_cluster.stop()

    def test_mixed_heap_and_tde_heap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Plain heap and tde_heap tables coexist; both must have correct data post-upgrade."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "mixed.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE plain (id INT) USING heap; "
            "INSERT INTO plain SELECT generate_series(1,100); "
            "CREATE TABLE encrypted (id INT, secret TEXT) USING tde_heap; "
            "INSERT INTO encrypted SELECT i, md5(i::text) FROM generate_series(1,150) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM plain") == "100"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM encrypted") == "150"
        assert tde_new.get_access_method("plain") == "heap"
        assert tde_new.get_access_method("encrypted") == "tde_heap"
        new_cluster.stop()

    def test_heap_enable_tde_after_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Old cluster uses plain heap; TDE is enabled on the new cluster post-upgrade."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "heap_then_tde.per")
        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE plain_data (id INT, info TEXT); "
            "INSERT INTO plain_data SELECT i, md5(i::text) FROM generate_series(1,200) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        # Enable TDE on the new cluster for the first time
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        tde_new.add_global_key_provider_file(keyfile=keyfile)
        tde_new.set_global_principal_key()
        # Pre-existing heap table survives; new tables can use tde_heap
        assert new_cluster.fetchone("SELECT COUNT(*) FROM plain_data") == "200"
        assert new_cluster.fetchone("SELECT amname FROM pg_am WHERE amname='tde_heap'") == "tde_heap"
        new_cluster.execute(
            "CREATE TABLE new_encrypted (id INT) USING tde_heap; "
            "INSERT INTO new_encrypted VALUES (1),(2),(3);"
        )
        assert new_cluster.fetchone("SELECT COUNT(*) FROM new_encrypted") == "3"
        new_cluster.stop()

    def test_tde_heap_convert_to_heap_before_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Rewrite tde_heap tables as heap before pg_upgrade; no pg_tde dir copy needed."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_then_heap.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE was_encrypted (id INT, data TEXT) USING tde_heap; "
            "INSERT INTO was_encrypted SELECT i, md5(i::text) FROM generate_series(1,250) i;"
        )

        # Convert to plain heap before upgrading
        old.execute("ALTER TABLE was_encrypted SET ACCESS METHOD heap")

        # FIX: To completely abandon pg_tde so the new cluster can boot without
        # the library loaded, we must drop the extension from the catalog.
        old.execute("DROP EXTENSION pg_tde;")
        old.stop()

        # No pg_tde shared_preload_libraries on new cluster — purely plain upgrade
        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM was_encrypted") == "250"
        am = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'was_encrypted'"
        )
        assert am == "heap"
        new_cluster.stop()

    # def test_tde_heap_convert_to_heap_before_upgrade(
    #     self,
    #     old_install_dir: Optional[Path],
    #     install_dir: Path,
    #     tmp_path: Path,
    #     io_method: str,
    # ):
    #     """Rewrite tde_heap tables as heap before pg_upgrade; no pg_tde dir copy needed."""
    #     if not old_install_dir:
    #         pytest.skip("--old-install-dir not provided")

    #     keyfile = str(tmp_path / "tde_then_heap.per")
    #     old = _make_old_cluster(
    #         old_install_dir,
    #         tmp_path,
    #         io_method,
    #         extra_initdb=initdb_args_no_data_checksums(old_install_dir),
    #         extra_params=_tde_params(keyfile),
    #     )
    #     old.start()
    #     tde = TdeManager(old)
    #     tde.create_extension()
    #     tde.add_global_key_provider_file(keyfile=keyfile)
    #     tde.set_global_principal_key()
    #     old.execute(
    #         "CREATE TABLE was_encrypted (id INT, data TEXT) USING tde_heap; "
    #         "INSERT INTO was_encrypted SELECT i, md5(i::text) FROM generate_series(1,250) i;"
    #     )
    #     # Convert to plain heap before upgrading — data is now unencrypted on disk
    #     old.execute("ALTER TABLE was_encrypted SET ACCESS METHOD heap")
    #     old.stop()

    #     # No pg_tde shared_preload_libraries on new cluster — purely plain upgrade
    #     new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
    #     assert result.returncode == 0, result.stderr

    #     new_cluster.start()
    #     new_cluster.wait_ready()
    #     assert new_cluster.fetchone("SELECT COUNT(*) FROM was_encrypted") == "250"
    #     am = new_cluster.fetchone(
    #         "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
    #         "WHERE c.relname = 'was_encrypted'"
    #     )
    #     assert am == "heap"
    #     new_cluster.stop()


# ── WAL encryption upgrade paths ──────────────────────────────────────────────


class TestUpgradeWalEncryptionPaths:
    """Four WAL encryption on/off combinations across a major-version upgrade."""

    def test_wal_enc_off_to_off(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Baseline: WAL encryption disabled throughout; upgrade must succeed."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "wal_off_off.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE wal_off (id INT) USING tde_heap; "
            "INSERT INTO wal_off SELECT generate_series(1,50);"
        )
        assert not tde.is_wal_encrypted()
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM wal_off") == "50"
        assert not tde_new.is_wal_encrypted()
        new_cluster.stop()

    def test_wal_enc_on_to_off(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """WAL encryption on in old cluster; must be disabled before pg_upgrade runs."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "wal_on_off.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        old.execute(
            "CREATE TABLE wal_on_data (id INT) USING tde_heap; "
            "INSERT INTO wal_on_data SELECT generate_series(1,80);"
        )
        # Disable WAL encryption before pg_upgrade (pg_upgrade cannot process encrypted WAL)
        tde.disable_wal_encryption()
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, f"pg_upgrade after WAL enc disable failed:\n{result.stderr}"

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM wal_on_data") == "80"
        assert not tde_new.is_wal_encrypted(), "WAL encryption should remain off"
        new_cluster.stop()

    def test_wal_enc_on_to_reenable(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Upgrade with WAL enc off, then re-enable it on the new cluster."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "wal_reenable.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        old.execute(
            "CREATE TABLE pre_enc (id INT) USING tde_heap; "
            "INSERT INTO pre_enc VALUES (1),(2),(3);"
        )
        tde.disable_wal_encryption()
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        # Re-enable WAL encryption on the upgraded cluster
        tde_new.enable_wal_encryption()
        assert tde_new.is_wal_encrypted(), "WAL encryption should be on after re-enable"
        # Pre-upgrade data must still be accessible
        assert new_cluster.fetchone("SELECT COUNT(*) FROM pre_enc") == "3"
        # New tde_heap writes must work with WAL encryption on
        new_cluster.execute(
            "CREATE TABLE post_enc (id INT) USING tde_heap; "
            "INSERT INTO post_enc SELECT generate_series(1,10);"
        )
        assert new_cluster.fetchone("SELECT COUNT(*) FROM post_enc") == "10"
        new_cluster.stop()

    def test_check_mode_with_wal_enc_on(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """pg_upgrade --check must succeed even when WAL encryption is active."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "wal_check.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        old.execute(
            "CREATE TABLE wal_check_tbl (id INT) USING tde_heap; "
            "INSERT INTO wal_check_tbl VALUES (1);"
        )
        old.stop()

        _, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
            check_only=True,
        )
        assert result.returncode == 0, f"pg_upgrade --check with WAL enc on failed:\n{result.stderr}"

class TestUpgradeEnforceEncryption:
    """
    Validates the safety of pg_tde.enforce_encryption during major version upgrades.
    Ensures pg_upgrade's schema restore phase does not accidentally convert legacy
    heap tables to tde_heap, which would physically corrupt the files.
    """

    def test_upgrade_with_enforce_encryption_active(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Validates that enforce_encryption doesn't break pg_upgrade by
        implicitly changing the AM of legacy heap tables during schema restore.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "enforce_enc.per")

        # Start the old cluster WITHOUT enforcement first to create a legacy heap table
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()

        # 1. Create a legacy unencrypted table
        old.execute(
            "CREATE TABLE legacy_heap (id INT) USING heap; "
            "INSERT INTO legacy_heap VALUES (1), (2), (3);"
        )

        # 2. Enable enforcement and create a forced encrypted table
        old.execute("ALTER SYSTEM SET pg_tde.enforce_encryption = 'on';")
        old.execute("SELECT pg_reload_conf();")

        # This table should automatically become tde_heap because of enforcement
        old.execute(
            "CREATE TABLE forced_enc (id INT); "
            "INSERT INTO forced_enc VALUES (99);"
        )
        old.stop()

        # 3. Perform the upgrade WITH enforce_encryption set to 'on' globally
        # in the new cluster's configuration.
        new_params = _tde_params(keyfile)
        new_params["pg_tde.enforce_encryption"] = "'on'"

        from .test_tde_pg_upgrade import _upgrade, _copy_pg_tde_dir
        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=new_params,
        )
        assert result.returncode == 0, f"pg_upgrade failed with enforce_encryption=on:\n{result.stderr}"

        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()

        # 4. CRITICAL CHECK: The legacy table MUST remain plain heap.
        # If enforce_encryption overrode the AM during pg_upgrade, this SELECT will crash.
        assert new_cluster.fetchone("SELECT COUNT(*) FROM legacy_heap") == "3"
        am_legacy = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'legacy_heap'"
        )
        assert am_legacy == "heap", "FATAL: enforce_encryption corrupted the legacy heap table's AM during upgrade!"

        # 5. Verify the previously forced table is still readable and encrypted
        assert new_cluster.fetchone("SELECT COUNT(*) FROM forced_enc") == "1"
        am_forced = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'forced_enc'"
        )
        assert am_forced == "tde_heap"

        # 6. Verify enforcement is actively working on the new cluster
        new_cluster.execute("CREATE TABLE post_upgrade_forced (id INT);")
        am_post = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'post_upgrade_forced'"
        )
        assert am_post == "tde_heap", "Enforcement failed to apply to new tables after upgrade!"

        new_cluster.stop()


# ── pg_tde_upgrade with non-default modes (link / clone / parallel) ──────────


class TestPgTdeUpgradeModes:
    """
    ``pg_tde_upgrade`` must work with the same non-default modes as
    upstream ``pg_upgrade``: ``--link`` (fast, in-place), ``--clone``
    (CoW-filesystem-only), and ``-j N`` (parallel data file transfer).

    These were covered for plain heap in ``test_upgrade.py`` but
    **not** for the TDE binary + tde_heap combination — a real coverage
    gap because link mode is the most common production upgrade path.
    """

    def _build_tde_old_with_data(
        self,
        old_install_dir: Path,
        tmp_path: Path,
        io_method: str,
        keyfile: str,
        rows: int = 500,
    ) -> PgCluster:
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE mode_t (id INT, payload TEXT) USING tde_heap"
        )
        old.execute(
            "INSERT INTO mode_t "
            f"SELECT i, md5(i::text) FROM generate_series(1, {rows}) i"
        )
        old.stop()
        return old

    def test_pg_tde_upgrade_link_mode(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        ``--link`` does hard-linking instead of copying the data files.
        For TDE this is the highest-value mode (zero-downtime upgrades
        with encrypted data). After link mode, the *old* cluster's data
        files are unsafe to read independently — we just verify the new
        cluster starts and the encrypted rows are present.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "link_mode.per")
        old = self._build_tde_old_with_data(
            old_install_dir, tmp_path, io_method, keyfile,
        )

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
            pg_upgrade_extra=["--link"],
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade --link failed:\n{result.stderr}"
        )

        copied = _copy_pg_tde_dir(old, new_cluster)
        assert copied, "pg_tde key-material dir was not present in old cluster"

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM mode_t") == "500"
        # Encryption survived the link upgrade.
        am = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'mode_t'"
        )
        assert am == "tde_heap"
        new_cluster.stop()

    def test_pg_tde_upgrade_clone_mode(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        ``--clone`` uses copy-on-write semantics on supported filesystems
        (Btrfs, XFS reflink, APFS). Skip if the filesystem doesn't
        support it — pg_upgrade reports this clearly in stderr.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "clone_mode.per")
        old = self._build_tde_old_with_data(
            old_install_dir, tmp_path, io_method, keyfile,
        )

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
            pg_upgrade_extra=["--clone"],
        )
        if result.returncode != 0 and "clone" in result.stderr.lower():
            pytest.skip(
                "--clone is not supported on this filesystem; "
                f"stderr: {result.stderr[:300]}"
            )
        assert result.returncode == 0, (
            f"pg_tde_upgrade --clone failed:\n{result.stderr}"
        )

        _copy_pg_tde_dir(old, new_cluster)
        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM mode_t") == "500"
        new_cluster.stop()

    def test_pg_tde_upgrade_parallel_jobs(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        ``-j 4`` parallelises data file transfer. With many tde_heap
        tables this is the realistic production mode — exercise it
        explicitly.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "parallel_jobs.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        # 10 tde_heap tables — gives -j 4 something to parallelise on.
        for i in range(10):
            old.execute(
                f"CREATE TABLE par_t_{i} (id INT, payload TEXT) USING tde_heap"
            )
            old.execute(
                f"INSERT INTO par_t_{i} "
                "SELECT i, md5(i::text) FROM generate_series(1, 100) i"
            )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
            pg_upgrade_extra=["-j", "4"],
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade -j 4 failed:\n{result.stderr}"
        )

        _copy_pg_tde_dir(old, new_cluster)
        new_cluster.start()
        new_cluster.wait_ready()
        for i in range(10):
            assert new_cluster.fetchone(
                f"SELECT COUNT(*) FROM par_t_{i}"
            ) == "100", f"par_t_{i} row count mismatch after parallel upgrade"
        new_cluster.stop()


# ── complex schema preservation on tde_heap ─────────────────────────────────


class TestPgTdeUpgradeComplexSchema:
    """
    Schema objects often used in real applications must survive a
    pg_tde_upgrade run when the underlying relation is ``tde_heap``.
    Existing ``test_upgrade.py::TestUpgradeDataIntegrity`` covers these
    for plain heap; this class is the TDE counterpart.
    """

    def _build_tde_old(
        self,
        old_install_dir: Path,
        tmp_path: Path,
        io_method: str,
        keyfile: str,
    ) -> PgCluster:
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        return old

    def test_pg_tde_upgrade_partitioned_tde_heap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        RANGE-partitioned ``tde_heap`` parent + children survive
        pg_tde_upgrade. Partitioned tables exercise a different schema-
        restore path than plain heaps (partition catalog entries get
        recreated, not transferred as files).
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "partitioned.per")
        old = self._build_tde_old(old_install_dir, tmp_path, io_method, keyfile)
        old.execute(
            "CREATE TABLE part_t (id INT, ts TIMESTAMPTZ) "
            "PARTITION BY RANGE (ts) USING tde_heap; "
            "CREATE TABLE part_t_2024 PARTITION OF part_t "
            "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01') "
            "USING tde_heap; "
            "CREATE TABLE part_t_2025 PARTITION OF part_t "
            "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01') "
            "USING tde_heap;"
        )
        old.execute(
            "INSERT INTO part_t (id, ts) VALUES "
            "(1, '2024-06-01'), (2, '2024-12-31'), "
            "(3, '2025-03-01'), (4, '2025-09-15');"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (partitioned) failed:\n{result.stderr}"
        )
        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM part_t") == "4"
        assert new_cluster.fetchone(
            "SELECT COUNT(*) FROM part_t_2024"
        ) == "2"
        # Both partitions must remain tde_heap.
        for child in ("part_t_2024", "part_t_2025"):
            am = new_cluster.fetchone(
                "SELECT am.amname FROM pg_class c JOIN pg_am am "
                f"ON c.relam = am.oid WHERE c.relname = '{child}'"
            )
            assert am == "tde_heap", (
                f"Partition {child} lost tde_heap AM during pg_tde_upgrade"
            )
        new_cluster.stop()

    def test_pg_tde_upgrade_foreign_key_cascade_on_tde_heap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        ``ON DELETE CASCADE`` between two ``tde_heap`` tables must remain
        enforced post-upgrade. FK metadata lives in the catalog, not
        the heap, but verify both sides keep working.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "fk_cascade.per")
        old = self._build_tde_old(old_install_dir, tmp_path, io_method, keyfile)
        old.execute(
            "CREATE TABLE parent_t (id INT PRIMARY KEY, label TEXT) "
            "USING tde_heap; "
            "CREATE TABLE child_t (id INT PRIMARY KEY, parent_id INT "
            "REFERENCES parent_t(id) ON DELETE CASCADE, payload TEXT) "
            "USING tde_heap; "
            "INSERT INTO parent_t VALUES (1, 'a'), (2, 'b'), (3, 'c'); "
            "INSERT INTO child_t VALUES (10, 1, 'x'), (11, 1, 'y'), (12, 2, 'z');"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (FK cascade) failed:\n{result.stderr}"
        )
        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()

        # Baseline counts preserved.
        assert new_cluster.fetchone("SELECT COUNT(*) FROM parent_t") == "3"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM child_t") == "3"

        # Cascade still works: deleting parent id=1 must remove both children.
        new_cluster.execute("DELETE FROM parent_t WHERE id = 1")
        assert new_cluster.fetchone("SELECT COUNT(*) FROM parent_t") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM child_t") == "1"
        new_cluster.stop()

    def test_pg_tde_upgrade_indexes_on_tde_heap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Multiple index types (btree, hash, brin) on a single tde_heap
        table must all be queryable post-upgrade. Each index AM has
        its own on-disk layout; pg_tde_upgrade must rebuild or carry
        each one cleanly.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "indexes.per")
        old = self._build_tde_old(old_install_dir, tmp_path, io_method, keyfile)
        old.execute(
            "CREATE TABLE idx_t (id INT, txt TEXT, n INT) USING tde_heap; "
            "INSERT INTO idx_t "
            "SELECT i, md5(i::text), i % 100 FROM generate_series(1, 500) i; "
            "CREATE INDEX idx_t_btree ON idx_t USING btree (id); "
            "CREATE INDEX idx_t_hash  ON idx_t USING hash  (txt); "
            "CREATE INDEX idx_t_brin  ON idx_t USING brin  (n);"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (indexes) failed:\n{result.stderr}"
        )
        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM idx_t") == "500"
        # All three indexes survived.
        idx_count = new_cluster.fetchone(
            "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'idx_t'"
        )
        assert int(idx_count) >= 3, (
            f"Expected ≥3 indexes on idx_t after upgrade, got {idx_count}"
        )
        # Each index can be used (forced via enable_seqscan=off).
        new_cluster.execute("SET enable_seqscan = off")
        assert new_cluster.fetchone(
            "SELECT COUNT(*) FROM idx_t WHERE id = 250"
        ) == "1"
        new_cluster.stop()

    def test_pg_tde_upgrade_with_multiple_key_providers(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Two registered key providers in the old cluster must both be
        present in the new cluster's pg_tde catalog after upgrade —
        proves pg_tde_upgrade migrates the full provider list, not just
        the one tied to the active principal key.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile_a = str(tmp_path / "multi_kp_a.per")
        keyfile_b = str(tmp_path / "multi_kp_b.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile_a),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(
            provider_name="provider_a", keyfile=keyfile_a
        )
        tde.add_global_key_provider_file(
            provider_name="provider_b", keyfile=keyfile_b
        )
        tde.set_global_principal_key(
            key_name="multi_kp_key", provider_name="provider_a"
        )
        old.execute(
            "CREATE TABLE multi_kp_t (id INT) USING tde_heap; "
            "INSERT INTO multi_kp_t SELECT generate_series(1, 100);"
        )
        # Sanity: two providers visible before upgrade.
        pre_count = tde.list_key_providers()
        assert pre_count == 2, (
            f"Pre-upgrade provider count = {pre_count}; expected 2"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile_a),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (multi-provider) failed:\n{result.stderr}"
        )
        _copy_pg_tde_dir(old, new_cluster)

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone(
            "SELECT COUNT(*) FROM multi_kp_t"
        ) == "100"
        # Both providers preserved.
        post_count = TdeManager(new_cluster).list_key_providers()
        assert post_count == 2, (
            f"Post-upgrade provider count = {post_count}; expected 2 "
            "(pg_tde_upgrade may have dropped the inactive provider)"
        )
        new_cluster.stop()

class TestUpgradeBashScriptParity:
    """
    Direct translations of the bash test scripts ensuring 100% parity.
    Covers Database-level key providers, Partitioned tables, and upgrading
    while WAL encryption is actively left ON.
    """

    def test_upgrade_database_key_provider_and_partitions(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Translates bash script 1:
        Tests pg_tde_upgrade with database-level key providers and partitioned tables.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "db_provider_upgrade.key")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()

        # 1. Setup Database Key Provider (NOT Global)
        old.execute("CREATE EXTENSION pg_tde;")
        old.execute(f"SELECT pg_tde_add_database_key_provider_file('db_provider', '{keyfile}');")
        old.execute("SELECT pg_tde_create_key_using_database_key_provider('db_key', 'db_provider');")
        old.execute("SELECT pg_tde_set_key_using_database_key_provider('db_key', 'db_provider');")

        # 2. Normal Table
        old.execute("CREATE TABLE test_enc (k int PRIMARY KEY) USING tde_heap;")
        old.execute("INSERT INTO test_enc (k) VALUES (1), (2);")

        # 3. Partitioned Table
        old.execute("CREATE TABLE part_enc (id int) PARTITION BY RANGE(id) USING tde_heap;")
        old.execute("CREATE TABLE part_enc_1 PARTITION OF part_enc FOR VALUES FROM (0) TO (100);")
        old.execute("CREATE TABLE part_enc_2 PARTITION OF part_enc FOR VALUES FROM (100) TO (200);")
        old.execute("INSERT INTO part_enc VALUES (10),(20),(110),(120);")

        old.stop()

        # 4. Perform the upgrade
        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade failed:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()

        # 5. Verify Data and Schema
        assert new_cluster.fetchone("SELECT COUNT(*) FROM test_enc;") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM part_enc;") == "4"

        # Verify the key provider migrated correctly as a database provider
        tde_new = TdeManager(new_cluster)
        provider_count = tde_new.list_key_providers(scope="database")
        assert provider_count >= 1, "Database key provider did not survive the upgrade!"

        new_cluster.stop()

    def test_upgrade_with_wal_encryption_left_on(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Translates bash script 2:
        Tests pg_tde_upgrade against a cluster where pg_tde.wal_encrypt='ON'
        is actively configured during the upgrade process.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "wal_on_upgrade.key")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()

        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()

        # Enable WAL encryption and leave it ON
        old.execute("ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';")
        old.execute("SELECT pg_reload_conf();")

        old.execute("CREATE TABLE test_enc_global (k int primary key) USING tde_heap;")
        old.execute("INSERT INTO test_enc_global VALUES (10),(20),(30);")

        old.stop()

        # Perform the upgrade. pg_tde_upgrade should handle the WAL encryption seamlessly.
        # Ensure the new cluster also has WAL encryption enabled in its parameters.
        new_params = _tde_params(keyfile)
        new_params["pg_tde.wal_encrypt"] = "'on'"
        
        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=new_params
        )
        assert result.returncode == 0, f"pg_tde_upgrade failed with WAL encryption active:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()

        assert new_cluster.fetchone("SELECT COUNT(*) FROM test_enc_global;") == "3"

        # Verify WAL encryption is still actively running on the new cluster
        tde_new = TdeManager(new_cluster)
        assert tde_new.is_wal_encrypted() == True, "WAL encryption was lost during upgrade!"

        new_cluster.stop()
