"""
pg_tde major-version upgrade tests: PPG→PSP, PSP→PSP, heap↔tde_heap permutations, WAL paths.

Regression coverage for PG-2240: vanilla ``pg_upgrade`` does not migrate ``$PGDATA/pg_tde/``,
so encrypted ``tde_heap`` data could not be decrypted on the new cluster unless that
directory is copied. ``_upgrade()`` picks ``pg_tde_upgrade`` when the source ships a
different pg_tde default version than the target (e.g. 2.1.x → 2.2.x) or WAL
encryption was enabled; otherwise plain ``pg_upgrade`` + ``copy_pg_tde_dir()``.
Explicit ``--link`` / ``--clone`` / ``-j`` also force the wrapper.

Upgrade flavours tested
───────────────────────
  PPG (<17) → PSP (≥17)    Old pkg build → new source/pkg build.
  PSP (17)  → PSP (18)     Same-flavour major-version bump; identical key-provider API.

After each successful upgrade, ``_start_cluster_after_pg_upgrade()`` runs
``ALTER EXTENSION pg_tde UPDATE`` when pg_tde is installed — required for
PG17+pg_tde 2.1.x → PG18+pg_tde 2.2.x; no-op when both sides are already 2.2.x.

Access-method permutations
──────────────────────────
  heap  → heap              Baseline (no TDE).
  tde_heap → tde_heap       Primary PG-2240 scenario (encrypted tables).
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
import subprocess
import time
from pathlib import Path
from typing import List, Optional

import pytest

from lib import (
    PgCluster,
    TdeManager,
    archive_restore_conf_values,
    restore_conf_line_raw,
)
from lib.cluster import (
    copy_pg_tde_dir,
    initdb_args_no_data_checksums,
    initdb_extra_align_data_checksums_with_old,
    pg_upgrade_target_params,
    prepend_install_lib_dirs,
    resolve_pg_upgrade_binary,
    postgres_major_version,
    read_pg_tde_default_version,
    should_use_pg_tde_upgrade_wrapper,
    write_pg_upgrade_target_config,
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


def _finalize_upgrade_target_cluster(
    cluster: PgCluster, extra_params: Optional[dict]
) -> None:
    """Apply full cluster settings after pg_upgrade (hba + PG18 io_method, etc.)."""
    cluster.write_default_config(extra_params=extra_params)
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")


def _start_cluster_after_pg_upgrade(
    cluster: PgCluster,
    *,
    ready_timeout: int = 90,
    alter_databases: Optional[List[str]] = None,
) -> None:
    """Start the upgraded cluster and run ``ALTER EXTENSION pg_tde UPDATE``.

    After a major upgrade (e.g. PG17+pg_tde 2.1.2 → PG18+pg_tde 2.2.0),
    ``pg_upgrade`` carries the extension catalog row at the old ``extversion``
    (e.g. ``2.1``). The bundled migration scripts (``pg_tde--2.1--2.2.sql``)
    run only via ``ALTER EXTENSION pg_tde UPDATE`` on the **new** cluster.
    Skipped when pg_tde is not installed (e.g. extension was dropped before
    upgrade). No-op when source and target already share the same pg_tde minor
    (e.g. 2.2.0 → 2.2.0).

    For multiple databases with distinct principal keys (PG-2379), pass every
    database that has ``CREATE EXTENSION pg_tde`` in *alter_databases*.
    """
    cluster.start()
    cluster.wait_ready(timeout=ready_timeout)
    for dbname in alter_databases or ["postgres"]:
        if cluster.fetchone(
            "SELECT 1 FROM pg_extension WHERE extname='pg_tde'",
            dbname=dbname,
        ):
            cluster.execute("ALTER EXTENSION pg_tde UPDATE", dbname=dbname)


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
    use_tde_wrapper: Optional[bool] = None,
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
    # Minimal target config during pg_upgrade (matches bash automation scripts).
    target_params = pg_upgrade_target_params(extra_params)
    write_pg_upgrade_target_config(new_cluster, target_params)
    new_cluster.stop(check=False)

    if use_tde_wrapper is None:
        use_tde_wrapper = bool(pg_upgrade_extra) or should_use_pg_tde_upgrade_wrapper(
            old_cluster, install_dir, extra_params=extra_params
        )

    upgrade_bin = resolve_pg_upgrade_binary(
        install_dir, use_tde_wrapper=use_tde_wrapper
    )
    new_bin = install_dir / "bin"
    cmd = [
        str(upgrade_bin),
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
    prepend_install_lib_dirs(env, install_dir, old_cluster.install_dir)

    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(tmp_path), env=env
    )
    if result.returncode == 0 and not check_only:
        if upgrade_bin.name == "pg_upgrade":
            copy_pg_tde_dir(old_cluster.data_dir, new_data)
        _finalize_upgrade_target_cluster(new_cluster, extra_params)
    return new_cluster, result


def _tde_params(keyfile: str) -> dict:
    return {"shared_preload_libraries": "'pg_tde'"}


def _bind_database_principal_key(
    cluster: PgCluster,
    dbname: str,
    key_name: str,
    *,
    provider: str = "file_provider",
    create_extension: bool = False,
    create_key: bool = True,
) -> None:
    """Create/set a per-database principal key (global provider must exist)."""
    if create_extension:
        cluster.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname=dbname)
    if create_key:
        cluster.execute(
            f"SELECT pg_tde_create_key_using_global_key_provider("
            f"'{key_name}', '{provider}')",
            dbname=dbname,
        )
    cluster.execute(
        f"SELECT pg_tde_set_key_using_global_key_provider("
        f"'{key_name}', '{provider}')",
        dbname=dbname,
    )


def _principal_key_name_in_db(
    cluster: PgCluster, dbname: str = "postgres"
) -> Optional[str]:
    """Return the active principal key name for *dbname* (first supported SRF)."""
    tde = TdeManager(cluster)
    for fn in (
        "pg_tde_key_info",
        "pg_tde_principal_key_info",
        "pg_tde_get_principal_key_info",
    ):
        if tde._nargs(fn) < 0:
            continue
        row = cluster.fetchone(f"SELECT key_name FROM {fn}()", dbname=dbname)
        if row:
            return row
    return None


def _setup_multidb_distinct_keys(
    cluster: PgCluster,
    keyfile: str,
    db_keys: List[tuple],
) -> None:
    """
    Configure one global file provider and distinct principal keys per database.

    *db_keys* is ``[(dbname, key_name, row_count), ...]``; ``postgres`` must be
    first. Creates ``tde_heap`` table ``enc_<dbname>`` with *row_count* rows.
    """
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=keyfile)
    first_db, first_key, first_rows = db_keys[0]
    assert first_db == "postgres"
    tde.set_global_principal_key(key_name=first_key)
    cluster.execute(
        f"CREATE TABLE enc_{first_db} (id INT) USING tde_heap; "
        f"INSERT INTO enc_{first_db} SELECT generate_series(1, {first_rows});",
        dbname=first_db,
    )
    for dbname, key_name, row_count in db_keys[1:]:
        cluster.execute(f"CREATE DATABASE {dbname}")
        _bind_database_principal_key(
            cluster, dbname, key_name, create_extension=True
        )
        cluster.execute(
            f"CREATE TABLE enc_{dbname} (id INT) USING tde_heap; "
            f"INSERT INTO enc_{dbname} SELECT generate_series(1, {row_count});",
            dbname=dbname,
        )


def _assert_multidb_rows(
    cluster: PgCluster, db_keys: List[tuple]
) -> None:
    for dbname, _key_name, row_count in db_keys:
        count = cluster.fetchone(
            f"SELECT COUNT(*) FROM enc_{dbname}", dbname=dbname
        )
        assert count == str(row_count)


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
        """Core PG-2240 scenario: tde_heap data survives PPG→PSP via pg_tde_upgrade."""
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
        # Idempotency: second ALTER EXTENSION must not error or change data.
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

        # Global provider already exists; bind a distinct *database* principal
        # key for db_alpha. Do NOT call set_server_key here — server/WAL key is
        # cluster-wide and was set on postgres via set_global_principal_key.
        old.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'key_alpha', 'file_provider')",
            dbname="db_alpha",
        )
        old.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'key_alpha', 'file_provider')",
            dbname="db_alpha",
        )

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

        _start_cluster_after_pg_upgrade(
            new_cluster, alter_databases=["postgres", "db_alpha"]
        )
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
    catalog version changes. Encrypted ``tde_heap`` data relies on
    ``pg_tde_upgrade`` to carry ``pg_tde`` state to the new cluster (PG-2240).
    """

    def test_tde_heap_data_survives(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Encrypted tde_heap data is intact after PSP→PSP (pg_tde_upgrade)."""
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        # Global provider already exists; bind a distinct *database* principal
        # key for db_b (server/WAL key stays key_v1 from postgres).
        old.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'key_v2', 'file_provider')",
            dbname="db_b",
        )
        old.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'key_v2', 'file_provider')",
            dbname="db_b",
        )

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

        _start_cluster_after_pg_upgrade(
            new_cluster, alter_databases=["postgres", "db_b"]
        )
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
        assert new_cluster.fetchone("SELECT COUNT(*) FROM wal_data") == "1"
        tde_new = TdeManager(new_cluster)
        tde_new.create_extension()
        assert not tde_new.is_wal_encrypted(), "WAL encryption should remain off after upgrade"
        new_cluster.stop()


# ── heap ↔ tde_heap access-method permutations ───────────────────────────────


class TestUpgradeAccessMethodPermutations:
    """Five permutations of heap/tde_heap across old and new clusters.

    These tests exercise encrypted-table upgrades (PG-2240 / ``pg_tde_upgrade``)
    plus edge cases: mixed tables, enabling TDE post-upgrade, and converting away
    from tde_heap before upgrading.
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

        _start_cluster_after_pg_upgrade(new_cluster)
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
        """Primary PG-2240 scenario: all tables use tde_heap; pg_tde_upgrade must preserve keys."""
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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
        """Rewrite tde_heap tables as heap before pg_upgrade; no pg_tde key dir needed on new cluster."""
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

        # Plain pg_upgrade (extension dropped; no pg_tde wrapper / no pg_tde preload).
        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, use_tde_wrapper=False
        )
        assert result.returncode == 0, (
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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


class TestPgTdeUpgradePitrWithEncryptedWal:
    """
    PITR-after-pg_tde_upgrade with encrypted WAL.

    Port of the bash automation script ``pg_tde_upgrade_pitr_test.sh``
    (PG-2358 family) — verifies that the documented PITR procedure
    survives a cross-major ``pg_tde_upgrade`` and that the
    ``pg_tde_archive_decrypt`` / ``pg_tde_restore_encrypt`` WAL
    wrappers correctly bridge the upgrade boundary.

    End-to-end flow
    ───────────────
      1. OLD cluster (e.g. PG17) with pg_tde extension + a
         ``pg_tde_archive_decrypt``-wrapped ``archive_command``. WAL
         encryption itself is **off** in the old cluster — the wrapper
         transparently passes plaintext WAL through, which is the
         documented behaviour we rely on for crossings like this.
      2. Create encrypted ``tde_heap`` table, INSERT 3 rows, stop.
      3. ``pg_tde_upgrade`` to NEW major (e.g. PG18). Encrypted
         ``tde_heap`` survives the upgrade (PG-2240 contract).
      4. On NEW: re-arm ``archive_command`` with the NEW binary's
         wrapper, start, **enable** ``pg_tde.wal_encrypt = on``,
         restart. From here on, archived WAL is encrypted.
      5. Take an online base backup with ``pg_tde_basebackup -E``.
         ``TdeManager.tde_basebackup`` handles ``-E`` + pre-seeding
         the target's ``pg_tde/`` directory (so the streamed WAL can
         be encrypted on the way in).
      6. INSERT 3 more rows (4,5,6) → capture ``T1 = now()``
         (recovery target) → INSERT 2 more rows (7,8) → force a WAL
         segment switch + CHECKPOINT + wait for the segment carrying
         the post-``T1`` INSERT to land in the archive.
      7. Stop the cluster.
      8. Re-attach the base backup directory as a fresh cluster
         configured for PITR:
             ``pg_tde.wal_encrypt = on``
             ``recovery_target_time = T1``
             ``recovery_target_action = promote``
             ``restore_command = pg_tde_restore_encrypt …``
         Start → recovery replays archived WAL up to ``T1`` and
         promotes the cluster.
      9. Validate: rows 1..6 are present, rows 7..8 are NOT (they
         were inserted AFTER ``T1``).

    Skips cleanly when ``--old-install-dir`` is not provided.
    """

    def test_pitr_after_pg_tde_upgrade_with_encrypted_wal(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """One-shot end-to-end test of the bash script's flow.

        Folded into a single test method because each phase depends
        strictly on the previous one (upgrade requires populated old
        cluster; base backup requires upgraded+WAL-encrypted new
        cluster; PITR requires both archive segments and a viable
        base backup). Splitting would either duplicate the heavy
        ``pg_tde_upgrade`` step in every test or couple tests via
        order, both worse than a single self-contained method.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "upgrade_pitr.per")
        archive_dir = tmp_path / "archive"
        archive_dir.mkdir(parents=True, exist_ok=True)

        # ── 1. OLD cluster with pg_tde + wrapped archive_command ──────
        old_arch_cmd, _ = archive_restore_conf_values(
            old_install_dir, archive_dir, use_tde_wrappers=True
        )
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params={
                **_tde_params(keyfile),
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": old_arch_cmd,
            },
        )
        old.start()
        tde_old = TdeManager(old)
        tde_old.create_extension()
        tde_old.add_global_key_provider_file(keyfile=keyfile)
        # set_global_principal_key sets BOTH the server (WAL) key and the
        # database (table) key — matches the bash script which calls both
        # pg_tde_set_key_using_global_key_provider and
        # pg_tde_set_server_key_using_global_key_provider.
        tde_old.set_global_principal_key(key_name="global-key")
        old.execute(
            "CREATE TABLE test_enc_pitr (id INT PRIMARY KEY) USING tde_heap; "
            "INSERT INTO test_enc_pitr VALUES (1),(2),(3);"
        )
        assert tde_old.is_table_encrypted("test_enc_pitr"), (
            "test_enc_pitr is not encrypted on the OLD cluster — setup wrong"
        )
        # Force a switch so the OLD cluster's WAL gets through the
        # wrapper at least once before we tear it down.
        old.execute("SELECT pg_switch_wal()")
        old.stop()

        # ── 2. UPGRADE: pg_tde_upgrade OLD → NEW major ────────────────
        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade failed:\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )

        # ── 3. NEW cluster: archive_command with NEW binary wrapper ───
        new_arch_cmd, _ = archive_restore_conf_values(
            install_dir, archive_dir, use_tde_wrappers=True
        )
        new_cluster.configure(
            {
                "wal_level": "replica",
                "archive_mode": "on",
                "archive_command": new_arch_cmd,
            }
        )
        _start_cluster_after_pg_upgrade(new_cluster, ready_timeout=60)
        tde_new = TdeManager(new_cluster)

        # The upgraded cluster still has all 3 rows — sanity check before
        # enabling WAL encryption (catches PG-2240 regressions here, not
        # in the post-PITR assertion at the end).
        assert new_cluster.fetchone(
            "SELECT COUNT(*) FROM test_enc_pitr"
        ) == "3", "Upgraded cluster lost pre-upgrade rows"

        # ── 4. Enable WAL encryption on the upgraded cluster ──────────
        tde_new.enable_wal_encryption()
        assert tde_new.is_wal_encrypted(), (
            "WAL encryption did not engage on the upgraded cluster — the "
            "PITR replay will not exercise the pg_tde_restore_encrypt "
            "wrapper."
        )

        # ── 5. Online base backup with pg_tde_basebackup -E ───────────
        backup_dir = tmp_path / "backup_pitr"
        # tde_basebackup handles -E + pre-seeds pg_tde/ in the target
        # (equivalent to the bash script's manual `cp -R pg_tde` + -E).
        tde_new.tde_basebackup(
            str(backup_dir),
            encrypt_wal=True,
            extra_args=["-X", "stream"],
        )
        # PG refuses to start with "data directory has invalid
        # permissions ... should be u=rwx (0700)" when the basebackup
        # target was created by pg_basebackup under the test runner's
        # default umask (often 0022 → 0755). The bash original does
        # `chmod 700 $RUN_DIR/backup_pitr` for the same reason.
        backup_dir.chmod(0o700)
        # tde_basebackup uses `-R` which writes standby.signal. For PITR
        # we want recovery.signal only — drop the standby trigger so the
        # restored cluster doesn't try to attach as a standby.
        (backup_dir / "standby.signal").unlink(missing_ok=True)

        # ── 6. Generate WAL spanning T1 ───────────────────────────────
        # Pre-T1 INSERTs (must survive PITR).
        new_cluster.execute("INSERT INTO test_enc_pitr VALUES (4),(5),(6);")
        # Sleep so T1 lies strictly between the commit of (4,5,6) and the
        # commit of (7,8). Without this gap the recovery target could
        # land either side of either commit non-deterministically.
        time.sleep(2)
        recovery_target_time = (
            new_cluster.fetchone("SELECT now()") or ""
        ).strip()
        assert recovery_target_time, "SELECT now() returned empty"
        time.sleep(2)
        # Post-T1 INSERTs (must NOT survive PITR).
        new_cluster.execute("INSERT INTO test_enc_pitr VALUES (7),(8);")

        # Force the segment carrying (7,8) into the archive — otherwise
        # recovery can finish before reaching any post-T1 record and PG
        # raises "recovery ended before configured recovery target was
        # reached".
        closed = (
            new_cluster.fetchone(
                "SELECT pg_walfile_name(pg_switch_wal())"
            ) or ""
        ).strip()
        assert closed, "pg_switch_wal() did not return a segment name"
        new_cluster.execute("CHECKPOINT")

        deadline = time.time() + 30
        while time.time() < deadline:
            if (archive_dir / closed).exists():
                break
            time.sleep(0.5)
        else:
            raise AssertionError(
                f"WAL segment {closed!r} was not archived within 30s; "
                f"archive dir contains: "
                f"{sorted(p.name for p in archive_dir.iterdir())}"
            )

        new_cluster.stop()

        # ── 7-8. PITR: re-attach base backup with recovery config ─────
        restore_port = allocate_port()
        restored = PgCluster(
            backup_dir, restore_port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        # write_default_config rewrites postgresql.conf and re-adds
        # include_if_exists=postgresql.auto.conf, so the recovery
        # parameters we write next will be picked up.
        restored.write_default_config(extra_params=_tde_params(keyfile))
        # Overwrite postgresql.auto.conf rather than append: the basebackup
        # carried over ALTER SYSTEM lines (port, archive_command pointing
        # at the now-stopped primary, etc.) which would otherwise clash.
        auto_conf = backup_dir / "postgresql.auto.conf"
        with auto_conf.open("w") as f:
            f.write("pg_tde.wal_encrypt = 'on'\n")
            f.write(f"recovery_target_time = '{recovery_target_time}'\n")
            f.write("recovery_target_action = 'promote'\n")
            f.write(
                restore_conf_line_raw(
                    archive_dir, install_dir, use_tde_wrappers=True
                )
            )
        restored.add_hba_entry("local all all trust")
        (backup_dir / "recovery.signal").touch()

        restored.start()
        restored.wait_ready(timeout=120)

        # ── 9. Validate: exactly rows 1..6, NOT 7..8 ──────────────────
        try:
            count = restored.fetchone("SELECT COUNT(*) FROM test_enc_pitr")
            assert count == "6", (
                f"PITR landed at the wrong target — got {count} rows; "
                f"expected 6 (rows 1..6 inserted before T1)."
            )
            ids = restored.fetchone(
                "SELECT string_agg(id::text, ',' ORDER BY id) "
                "FROM test_enc_pitr"
            )
            assert ids == "1,2,3,4,5,6", (
                f"Recovered row ids: {ids!r}; expected '1,2,3,4,5,6'. "
                f"This shape catches PITR landing too early (some 4/5/6 "
                f"missing) or too late (7 or 8 present)."
            )
        finally:
            try:
                restored.stop(check=False)
            except Exception:
                pass


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
        Validates that ``pg_tde.enforce_encryption = on`` does not break
        ``pg_upgrade`` by changing the access method of legacy heap tables
        during schema restore on the new cluster.

        Current pg_tde rejects ``CREATE TABLE ... USING heap`` (or no USING
        clause) when enforcement is on instead of silently coercing the AM,
        so the new ``tde_heap`` table is created explicitly. Schema restore
        during ``pg_upgrade`` runs as a superuser and must replay the
        ``USING heap`` from the dump even with enforcement active — this
        test confirms that round-trip and that enforcement still blocks
        plain heap creation on the upgraded cluster.
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

        # 2. Enable enforcement; plain CREATE TABLE is now rejected by pg_tde
        old.execute("ALTER SYSTEM SET pg_tde.enforce_encryption = 'on';")
        old.execute("SELECT pg_reload_conf();")

        # Sanity-check that enforcement blocks non-tde_heap tables on the old cluster.
        # The error message changed across pg_tde versions; just match the substring.
        try:
            old.execute("CREATE TABLE blocked_plain (id INT);")
        except RuntimeError as exc:
            assert "enforce_encryption" in str(exc), (
                f"unexpected error from old cluster:\n{exc}"
            )
        else:
            pytest.fail("enforce_encryption=on did not block plain CREATE TABLE on old cluster")

        # Explicit tde_heap creation must succeed.
        old.execute(
            "CREATE TABLE forced_enc (id INT) USING tde_heap; "
            "INSERT INTO forced_enc VALUES (99);"
        )
        old.stop()

        # 3. Perform the upgrade WITH enforce_encryption set to 'on' globally
        # in the new cluster's configuration.
        new_params = _tde_params(keyfile)
        new_params["pg_tde.enforce_encryption"] = "'on'"

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=new_params,
        )
        assert result.returncode == 0, f"pg_upgrade failed with enforce_encryption=on:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)

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

        # 6. Verify enforcement is actively working on the new cluster:
        #    plain CREATE TABLE must still be rejected.
        try:
            new_cluster.execute("CREATE TABLE post_upgrade_blocked (id INT);")
        except RuntimeError as exc:
            assert "enforce_encryption" in str(exc), (
                f"unexpected error from new cluster:\n{exc}"
            )
        else:
            pytest.fail(
                "enforce_encryption=on did not block plain CREATE TABLE "
                "on the upgraded cluster"
            )

        # Explicit tde_heap creation must still work after upgrade.
        new_cluster.execute("CREATE TABLE post_upgrade_forced (id INT) USING tde_heap;")
        am_post = new_cluster.fetchone(
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            "WHERE c.relname = 'post_upgrade_forced'"
        )
        assert am_post == "tde_heap"

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

        _start_cluster_after_pg_upgrade(new_cluster)
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
        support it — ``pg_upgrade`` reports failure on stdout (stderr is
        often empty).
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
        if result.returncode != 0:
            combined = f"{result.stdout or ''}\n{result.stderr or ''}".lower()
            if (
                "could not clone" in combined
                or ("clone" in combined and "not supported" in combined)
            ):
                pytest.skip(
                    "--clone is not supported on this filesystem; "
                    f"output: {(result.stdout or result.stderr or '')[:400]!r}"
                )
        assert result.returncode == 0, (
            f"pg_tde_upgrade --clone failed:\n{result.stdout}\n{result.stderr}"
        )

        _start_cluster_after_pg_upgrade(new_cluster)
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

        _start_cluster_after_pg_upgrade(new_cluster)
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
        _start_cluster_after_pg_upgrade(new_cluster)
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
        _start_cluster_after_pg_upgrade(new_cluster)

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
        _start_cluster_after_pg_upgrade(new_cluster)
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
        _start_cluster_after_pg_upgrade(new_cluster)
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

    def test_pg_tde_upgrade_views_sequences_checks_partial_indexes(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Mirror of ``pg_tde_upgrade_scenarios_test.sh`` scenario #3
        (Complex schema). Earlier tests cover btree/hash/brin indexes,
        partitioning, and FK cascades, but the bash scenario also
        exercises:

          * A user sequence whose ``last_value`` must be preserved
          * ``DEFAULT nextval(seq)`` on a column
          * ``CHECK`` constraints (including a list-based one)
          * A partial index (``WHERE status = 'pending'``)
          * A view that filters on the encrypted heap

        All of those live in the catalog rather than the heap, so they
        rely on ``pg_tde_upgrade`` handing the dump/restore step off to
        pg_upgrade correctly. Regression: if the catalog migration is
        broken, the view returns wrong rows or the partial index is
        rebuilt without its predicate.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "complex_schema.per")
        old = self._build_tde_old(old_install_dir, tmp_path, io_method, keyfile)
        old.execute(
            "CREATE SEQUENCE order_seq START 1000; "
            "CREATE TABLE orders ("
            "  id       INT DEFAULT nextval('order_seq') PRIMARY KEY,"
            "  customer TEXT          NOT NULL,"
            "  amount   NUMERIC(12,2) CHECK (amount > 0),"
            "  status   TEXT          NOT NULL DEFAULT 'pending'"
            "                         CHECK (status IN ('pending','shipped','done')),"
            "  created  TIMESTAMPTZ   NOT NULL DEFAULT now()"
            ") USING tde_heap; "
            "CREATE INDEX idx_orders_customer ON orders(customer); "
            "CREATE INDEX idx_orders_pending  ON orders(created) "
            "  WHERE status = 'pending'; "
            "INSERT INTO orders (customer, amount, status) "
            "  SELECT 'cust_' || (i % 20), "
            "         (i * 3.14)::numeric(12,2), "
            "         CASE i % 3 WHEN 0 THEN 'pending' "
            "                    WHEN 1 THEN 'shipped' "
            "                    ELSE 'done' END "
            "  FROM generate_series(1, 300) i; "
            "CREATE VIEW v_pending AS "
            "  SELECT id, customer, amount FROM orders WHERE status = 'pending';"
        )

        pre_rows = old.fetchone("SELECT COUNT(*) FROM orders")
        pre_seq = old.fetchone("SELECT last_value FROM order_seq")
        pre_pending = old.fetchone("SELECT COUNT(*) FROM v_pending")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (complex schema) failed:\n{result.stderr}"
        )
        _start_cluster_after_pg_upgrade(new_cluster)

        # Row, sequence and view counts must all survive.
        assert new_cluster.fetchone("SELECT COUNT(*) FROM orders") == pre_rows
        assert new_cluster.fetchone("SELECT last_value FROM order_seq") == pre_seq
        assert new_cluster.fetchone("SELECT COUNT(*) FROM v_pending") == pre_pending

        # Both indexes (including the partial one) must be present
        # with their original predicates.
        idx_count = new_cluster.fetchone(
            "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'orders'"
        )
        assert int(idx_count) >= 3, (
            f"Expected ≥3 indexes on orders (pk + customer + pending), "
            f"got {idx_count}"
        )
        partial_pred = new_cluster.fetchone(
            "SELECT indexdef FROM pg_indexes "
            "WHERE indexname = 'idx_orders_pending'"
        )
        assert "WHERE" in (partial_pred or "") and "pending" in (partial_pred or ""), (
            f"Partial-index predicate dropped during upgrade: {partial_pred!r}"
        )

        # CHECK constraint still rejects bad input.
        with pytest.raises(RuntimeError) as exc:
            new_cluster.execute(
                "INSERT INTO orders (customer, amount, status) "
                "VALUES ('bad', -1, 'pending')"
            )
        assert "amount" in str(exc.value).lower() or "check" in str(exc.value).lower()

        # The sequence default still works for new INSERTs.
        new_cluster.execute(
            "INSERT INTO orders (customer, amount) VALUES ('post-upgrade', 99)"
        )
        new_id = new_cluster.fetchone(
            "SELECT id FROM orders WHERE customer = 'post-upgrade'"
        )
        assert int(new_id) > int(pre_seq), (
            f"Post-upgrade INSERT got id={new_id}; sequence did not advance past {pre_seq}"
        )

        new_cluster.stop()

    def test_pg_tde_upgrade_explicit_global_key_provider_migration(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Mirror of ``pg_tde_upgrade_scenarios_test.sh`` scenario #6
        (Global cluster-level key provider). Most existing upgrade
        tests use the helper-driven setup which may pick the default
        scope; this test explicitly:

          * Adds a GLOBAL file provider via
            ``pg_tde_add_global_key_provider_file``
          * Creates and activates a key via
            ``pg_tde_create_key_using_global_key_provider`` +
            ``pg_tde_set_key_using_global_key_provider``
          * Verifies that AFTER pg_tde_upgrade the new cluster still
            reports the SAME provider in the GLOBAL scope (not silently
            migrated to database scope) and the encrypted data is
            readable.

        Regression: if pg_tde_upgrade flattens the global provider into
        a per-database one, queries succeed but ``inherit_global_providers``-
        style features (and CREATE DATABASE inheritance) would silently
        break.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "global_scope_upgrade.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()

        # Explicit global-scope provider + key (not via the auto-detect helper).
        old.execute("CREATE EXTENSION pg_tde")
        old.execute(
            f"SELECT pg_tde_add_global_key_provider_file("
            f"'global_vault'::text, '{keyfile}'::text)"
        )
        old.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'global_key'::text, 'global_vault'::text)"
        )
        old.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'global_key'::text, 'global_vault'::text)"
        )
        old.execute(
            "CREATE TABLE global_enc (id INT PRIMARY KEY, data TEXT) USING tde_heap; "
            "INSERT INTO global_enc SELECT i, 'global_' || i "
            "FROM generate_series(1, 120) i"
        )

        pre_count = old.fetchone("SELECT COUNT(*) FROM global_enc")
        pre_global_providers = old.fetchall(
            "SELECT name FROM pg_tde_list_all_global_key_providers()"
        )
        assert "global_vault" in pre_global_providers, (
            f"global_vault provider not visible in old cluster: {pre_global_providers!r}"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (global provider scope) failed:\n{result.stderr}"
        )
        _start_cluster_after_pg_upgrade(new_cluster)

        # Data intact.
        assert new_cluster.fetchone("SELECT COUNT(*) FROM global_enc") == pre_count
        assert new_cluster.fetchone(
            "SELECT data FROM global_enc WHERE id = 60"
        ) == "global_60"

        # Scope-preserved: provider must still be a GLOBAL provider
        # post-upgrade — not silently migrated to database scope.
        post_global = new_cluster.fetchall(
            "SELECT name FROM pg_tde_list_all_global_key_providers()"
        )
        assert "global_vault" in post_global, (
            f"global_vault provider lost from global scope after upgrade: {post_global!r}"
        )
        post_db = new_cluster.fetchall(
            "SELECT name FROM pg_tde_list_all_database_key_providers()"
        )
        assert "global_vault" not in post_db, (
            f"global_vault provider was silently migrated to database scope: {post_db!r}"
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

        _start_cluster_after_pg_upgrade(new_cluster)

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

        # pg_tde_upgrade handles encrypted WAL; do not set wal_encrypt on the empty
        # target during pg_upgrade (breaks the schema-dump postmaster).
        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade failed with WAL encryption active:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)

        assert new_cluster.fetchone("SELECT COUNT(*) FROM test_enc_global;") == "3"

        # WAL encrypt migrates with the source cluster; re-enable if the upgrade reset it.
        tde_new = TdeManager(new_cluster)
        if not tde_new.is_wal_encrypted():
            tde_new.enable_wal_encryption()
        assert tde_new.is_wal_encrypted(), "WAL encryption was lost during upgrade!"

        new_cluster.stop()

class TestTdeUpgradeExtremeCornerCases:
    """
    Advanced physical layout and catalog corner cases.
    Tests TOAST file mapping, key history migration, unlogged tables,
    custom schema deployments, and relfilenode churn during pg_tde_upgrade.
    """

    def test_upgrade_massive_toast_data(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        TOAST tables have their own underlying relfilenodes.
        pg_tde_upgrade must successfully map and migrate the encryption
        metadata for the hidden TOAST relation as well as the main heap.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "toast_upgrade.per")
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

        old.execute("CREATE TABLE toast_t (id INT, massive_payload TEXT) USING tde_heap;")
        # Insert a string large enough to force out-of-line TOAST storage (~260KB)
        old.execute("INSERT INTO toast_t SELECT 1, repeat('abcdefghijklmnopqrstuvwxyz', 10000);")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade (TOAST) failed:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)

        # Verify the TOAST data was successfully decrypted on the new cluster
        length = new_cluster.fetchone("SELECT length(massive_payload) FROM toast_t WHERE id = 1;")
        assert int(length) == 260000, "TOAST data was truncated or corrupted during upgrade!"
        new_cluster.stop()

    def test_upgrade_key_rotation_history(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        If a key is rotated multiple times, a single table will contain
        blocks encrypted by different historical keys. pg_tde_upgrade must
        migrate the entire key history, ensuring old data remains readable.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "rotation_upgrade.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)

        # FIX: Generation 1 key MUST be created before creating the tde_heap table
        tde.set_global_principal_key(key_name='key_gen_1')

        old.execute("CREATE TABLE rot_t (id INT, gen TEXT) USING tde_heap;")
        old.execute("INSERT INTO rot_t VALUES (1, 'gen1');")

        # Generation 2
        tde.rotate_principal_key('key_gen_2')
        old.execute("INSERT INTO rot_t VALUES (2, 'gen2');")

        # Generation 3
        tde.rotate_principal_key('key_gen_3')
        old.execute("INSERT INTO rot_t VALUES (3, 'gen3');")

        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade (Key Rotation) failed:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)

        # Verify ALL generations of data can be read
        count = new_cluster.fetchone("SELECT COUNT(*) FROM rot_t;")
        assert int(count) == 3, "Failed to decrypt older key generations after upgrade!"
        new_cluster.stop()

    def test_upgrade_unlogged_tde_heap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Unlogged tables bypass WAL entirely. pg_upgrade handles them specially
        (often just copying the init fork). pg_tde_upgrade must not crash
        when processing an encrypted table with no WAL history.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "unlogged_upgrade.per")
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

        # Create UNLOGGED table
        old.execute("CREATE UNLOGGED TABLE unlogged_t (id INT) USING tde_heap;")
        old.execute("INSERT INTO unlogged_t VALUES (1), (2), (3);")

        # Clean shutdown flushes unlogged tables to disk safely
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade (Unlogged) failed:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)

        count = new_cluster.fetchone("SELECT COUNT(*) FROM unlogged_t;")
        assert int(count) == 3, "Unlogged encrypted data did not survive upgrade!"
        new_cluster.stop()


    def test_upgrade_extension_in_custom_schema(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Tests if pg_tde_upgrade hardcodes the 'public' schema.
        Installs pg_tde into a dedicated schema and upgrades.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "schema_upgrade.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()

        old.execute("CREATE SCHEMA vault;")
        old.execute("CREATE EXTENSION pg_tde SCHEMA vault;")

        # Must explicitly qualify functions since they aren't in public
        old.execute(f"SELECT vault.pg_tde_add_global_key_provider_file('fp', '{keyfile}');")
        old.execute("SELECT vault.pg_tde_create_key_using_global_key_provider('k1', 'fp');")
        old.execute("SELECT vault.pg_tde_set_server_key_using_global_key_provider('k1', 'fp');")
        old.execute("SELECT vault.pg_tde_set_key_using_global_key_provider('k1', 'fp');")

        old.execute("CREATE TABLE custom_schema_t (id INT) USING tde_heap;")
        old.execute("INSERT INTO custom_schema_t VALUES (99);")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_params=_tde_params(keyfile)
        )
        assert result.returncode == 0, f"pg_tde_upgrade (Custom Schema) failed:\n{result.stderr}"

        _start_cluster_after_pg_upgrade(new_cluster)
        assert new_cluster.fetchone("SELECT COUNT(*) FROM custom_schema_t;") == "1"
        new_cluster.stop()


    def test_upgrade_dropped_and_recreated_tables(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Relfilenode ghosting: create ``ghost_t``, drop it, recreate same name.

        Uses ``pg_tde_upgrade`` when pg_tde crosses 2.1→2.2 (auto via
        ``_upgrade()``). Plain ``pg_upgrade`` + ``pg_tde/`` copy leaves 2.1 key
        material that the 2.2 binary cannot decrypt at startup.
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "ghost_upgrade.per")
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

        # Version 1 (Will be ghosted)
        old.execute("CREATE TABLE ghost_t (id INT) USING tde_heap;")
        old.execute("INSERT INTO ghost_t VALUES (1);")
        old.execute("DROP TABLE ghost_t;")

        # Version 2 (Active)
        old.execute("CREATE TABLE ghost_t (id INT) USING tde_heap;")
        old.execute("INSERT INTO ghost_t VALUES (2);")

        # Force catalog cleanup
        old.execute("VACUUM FULL;")
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, (
            f"pg_tde_upgrade (ghost relfilenode) failed:\n"
            f"{result.stdout}\n{result.stderr}"
        )

        _start_cluster_after_pg_upgrade(new_cluster)

        # Must return exactly 1 row (value=2). If it fails, the catalog map is broken.
        val = new_cluster.fetchone("SELECT id FROM ghost_t;")
        assert int(val) == 2, "pg_tde_upgrade mixed up the dropped table's relfilenode!"
        new_cluster.stop()


# ── PG-2379: per-database principal keys during 2.1→2.2 smgr key migration ───
# https://github.com/percona/pg_tde/pull/581


class TestPg2379MultiDbKeyMigration:
    """
    Regression tests for PG-2379 / PR #581: ``pg_tde_migrate_smgr_keys_file()``
    must use each database's own principal key when migrating relation key files
    during ``ALTER EXTENSION pg_tde UPDATE`` (2.1 → 2.2).
    """

    def test_three_databases_three_keys_major_upgrade(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Three DBs with distinct principal keys survive pg_upgrade + migration."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "pg2379_three_db.per")
        db_keys = [
            ("postgres", "key_pg", 5),
            ("db_a", "key_a", 11),
            ("db_b", "key_b", 17),
        ]
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            subdir="pg2379_old3",
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        _setup_multidb_distinct_keys(old, keyfile, db_keys)
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            new_subdir="pg2379_new3",
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _start_cluster_after_pg_upgrade(
            new_cluster,
            alter_databases=["postgres", "db_a", "db_b"],
        )
        _assert_multidb_rows(new_cluster, db_keys)
        assert _principal_key_name_in_db(new_cluster, "postgres") == "key_pg"
        assert _principal_key_name_in_db(new_cluster, "db_a") == "key_a"
        assert _principal_key_name_in_db(new_cluster, "db_b") == "key_b"
        new_cluster.stop()

    def test_alter_extension_order_postgres_first_then_secondary(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "pg2379_order1.per")
        db_keys = [("postgres", "key_v1", 2), ("db_b", "key_v2", 30)]
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            subdir="pg2379_ord1_old",
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        _setup_multidb_distinct_keys(old, keyfile, db_keys)
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            new_subdir="pg2379_ord1_new",
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        new_cluster.execute("ALTER EXTENSION pg_tde UPDATE", dbname="postgres")
        new_cluster.execute("ALTER EXTENSION pg_tde UPDATE", dbname="db_b")
        _assert_multidb_rows(new_cluster, db_keys)
        new_cluster.stop()

    def test_alter_extension_order_secondary_first_then_postgres(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "pg2379_order2.per")
        db_keys = [("postgres", "key_v1", 2), ("db_b", "key_v2", 30)]
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            subdir="pg2379_ord2_old",
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        _setup_multidb_distinct_keys(old, keyfile, db_keys)
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            new_subdir="pg2379_ord2_new",
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        new_cluster.execute("ALTER EXTENSION pg_tde UPDATE", dbname="db_b")
        new_cluster.execute("ALTER EXTENSION pg_tde UPDATE", dbname="postgres")
        _assert_multidb_rows(new_cluster, db_keys)
        new_cluster.stop()

    def test_same_principal_key_on_two_databases(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """Control: two databases sharing one principal key still migrate cleanly."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "pg2379_samekey.per")
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            subdir="pg2379_same_old",
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="shared_key")
        old.execute(
            "CREATE TABLE enc_postgres (id INT) USING tde_heap; "
            "INSERT INTO enc_postgres VALUES (1);"
        )
        old.execute("CREATE DATABASE db_shared")
        # shared_key already exists in the global provider from postgres.
        _bind_database_principal_key(
            old,
            "db_shared",
            "shared_key",
            create_extension=True,
            create_key=False,
        )
        old.execute(
            "CREATE TABLE enc_db_shared (id INT) USING tde_heap; "
            "INSERT INTO enc_db_shared SELECT generate_series(1, 8);",
            dbname="db_shared",
        )
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            new_subdir="pg2379_same_new",
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _start_cluster_after_pg_upgrade(
            new_cluster, alter_databases=["postgres", "db_shared"]
        )
        assert new_cluster.fetchone("SELECT COUNT(*) FROM enc_postgres") == "1"
        assert (
            new_cluster.fetchone(
                "SELECT COUNT(*) FROM enc_db_shared", dbname="db_shared"
            )
            == "8"
        )
        new_cluster.stop()

    def test_extension_only_database_without_tde_tables(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """DB with pg_tde but no tde_heap tables must not break other DB migration."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "pg2379_empty.per")
        db_keys = [("postgres", "key_pg", 3), ("db_b", "key_b", 12)]
        old = _make_old_cluster(
            old_install_dir,
            tmp_path,
            io_method,
            subdir="pg2379_empty_old",
            extra_initdb=initdb_args_no_data_checksums(old_install_dir),
            extra_params=_tde_params(keyfile),
        )
        old.start()
        _setup_multidb_distinct_keys(old, keyfile, db_keys)
        old.execute("CREATE DATABASE db_empty")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db_empty")
        _bind_database_principal_key(old, "db_empty", "key_empty")
        old.stop()

        new_cluster, result = _upgrade(
            old,
            install_dir,
            tmp_path,
            io_method,
            new_subdir="pg2379_empty_new",
            extra_params=_tde_params(keyfile),
        )
        assert result.returncode == 0, result.stderr

        _start_cluster_after_pg_upgrade(
            new_cluster,
            alter_databases=["postgres", "db_b", "db_empty"],
        )
        _assert_multidb_rows(new_cluster, db_keys)
        assert _principal_key_name_in_db(new_cluster, "db_empty") == "key_empty"
        new_cluster.stop()

    def test_in_place_package_upgrade_multidb_distinct_keys(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        """
        Same PG major, pg_tde 2.1.x → 2.2.x on one ``$PGDATA`` (no pg_upgrade).

        Mirrors production: stop → package upgrade → restart on new binary →
        ``ALTER EXTENSION`` per database. Requires different ``default_version``
        in ``pg_tde.control`` on old vs new install paths, and the **same**
        PostgreSQL major on both ``--old-install-dir`` and ``--install-dir``
        (not a PG17→PG18 ``pg_upgrade`` run).
        """
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        if postgres_major_version(old_install_dir) != postgres_major_version(
            install_dir
        ):
            pytest.skip(
                "in-place pg_tde minor upgrade requires the same PostgreSQL major "
                f"(old={postgres_major_version(old_install_dir)}, "
                f"new={postgres_major_version(install_dir)}); use "
                "test_tde_pg_upgrade major-upgrade tests for PG17→PG18"
            )

        old_ver = read_pg_tde_default_version(old_install_dir)
        new_ver = read_pg_tde_default_version(install_dir)
        if not old_ver or not new_ver or old_ver == new_ver:
            pytest.skip(
                f"needs different pg_tde control versions (old={old_ver!r} "
                f"new={new_ver!r})"
            )

        keyfile = str(tmp_path / "pg2379_inplace.per")
        db_keys = [("postgres", "key_pg", 4), ("db_b", "key_b", 9)]
        data_dir = tmp_path / "pg2379_inplace_data"
        port = allocate_port()
        cluster = PgCluster(
            data_dir,
            port,
            old_install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        cluster.initdb(
            extra_args=initdb_args_no_data_checksums(old_install_dir)
        )
        cluster.write_default_config(extra_params=_tde_params(keyfile))
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        _setup_multidb_distinct_keys(cluster, keyfile, db_keys)
        cluster.stop()

        upgraded = PgCluster(
            data_dir,
            port,
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        upgraded.start()
        upgraded.wait_ready()
        bin_ver = (upgraded.fetchone("SELECT pg_tde_version()") or "").strip()
        assert new_ver in bin_ver or "2.2" in bin_ver, (
            f"expected new pg_tde binary, got {bin_ver!r}"
        )
        _assert_multidb_rows(upgraded, db_keys)

        for dbname in ("postgres", "db_b"):
            upgraded.execute("ALTER EXTENSION pg_tde UPDATE", dbname=dbname)

        ext_pg = upgraded.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_pg == new_ver
        _assert_multidb_rows(upgraded, db_keys)
        assert _principal_key_name_in_db(upgraded, "db_b") == "key_b"
        upgraded.stop()
        upgraded.start()
        upgraded.wait_ready()
        _assert_multidb_rows(upgraded, db_keys)
        upgraded.stop()
