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
        str(new_bin / "pg_upgrade"),
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
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="key_postgres")

        old.execute("CREATE DATABASE db_alpha")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db_alpha")
        tde_alpha = TdeManager(old)
        tde_alpha.add_global_key_provider_file(keyfile=keyfile)
        tde_alpha.set_global_principal_key(key_name="key_alpha", dbname="db_alpha")

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
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="key_v1")

        old.execute("CREATE DATABASE db_b")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db_b")
        tde_b = TdeManager(old)
        tde_b.add_global_key_provider_file(keyfile=keyfile)
        tde_b.set_global_principal_key(key_name="key_v2", dbname="db_b")

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
        # Convert to plain heap before upgrading — data is now unencrypted on disk
        old.execute("ALTER TABLE was_encrypted SET ACCESS METHOD heap")
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
