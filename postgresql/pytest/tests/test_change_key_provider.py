"""
pg_tde_change_key_provider CLI tool tests.

The CLI is used **offline** (server stopped) to fix a cluster that can't
start because its key provider configuration is wrong — for example after
a vault token changed or a file-provider keyfile was moved/restored to a
new path.

Syntax (from `documentation/docs/command-line-tools/pg-tde-change-key-provider.md`):

    pg_tde_change_key_provider [-D <datadir>] <dbOid> <provider_name>
                               <new_provider_type> <provider_parameters...>

These tests cover the file-provider path (no external services needed)
and a couple of input-validation negatives. Vault/KMIP variants are
preserved in the bash automation and can be added later as
`@pytest.mark.vault` / `@pytest.mark.kmip` cases.

Ported from automation/tests/pg_tde_change_key_provider_utility.sh.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import allocate_port
from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums


pytestmark = [pytest.mark.encryption]


# ── small SQL helpers (TdeManager only has global-scope wrappers) ─────────────


def _add_db_file_provider(cluster: PgCluster, name: str, keyfile: str) -> None:
    cluster.execute(
        "SELECT pg_tde_add_database_key_provider_file("
        f"'{name}'::text, '{keyfile}'::text)"
    )


def _set_db_principal_key(
    cluster: PgCluster, key_name: str, provider_name: str
) -> None:
    cluster.execute(
        "SELECT pg_tde_create_key_using_database_key_provider("
        f"'{key_name}'::text, '{provider_name}'::text)"
    )
    cluster.execute(
        "SELECT pg_tde_set_key_using_database_key_provider("
        f"'{key_name}'::text, '{provider_name}'::text)"
    )


def _postgres_db_oid(cluster: PgCluster) -> int:
    return int(cluster.fetchone(
        "SELECT oid FROM pg_database WHERE datname = 'postgres'"
    ))


def _bin(install_dir: Path) -> Path:
    return install_dir / "bin" / "pg_tde_change_key_provider"


def _run_change_kp(
    install_dir: Path,
    *args: str,
    env_extra: dict | None = None,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = (
        f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    if env_extra is not None:
        env.update(env_extra)
    return subprocess.run(
        [str(_bin(install_dir)), *args],
        capture_output=True, text=True, env=env,
    )


def _build_db_tde_cluster(pg_factory, tmp_path: Path, keyfile: Path) -> PgCluster:
    """
    Build a TDE cluster with a *database-scope* file key provider on the
    ``postgres`` database (so the dbOid maps to a real entry in pg_database).
    Matches the scope used by the bash automation script.
    """
    cluster = pg_factory("change_kp")
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.execute("CREATE EXTENSION pg_tde")
    _add_db_file_provider(cluster, "ckp_provider", str(keyfile))
    _set_db_principal_key(cluster, "ckp_key", "ckp_provider")
    return cluster


# ── tests ─────────────────────────────────────────────────────────────────────


class TestPgTdeChangeKeyProviderCLI:
    """
    Offline reconfiguration of an existing key provider via the
    ``pg_tde_change_key_provider`` CLI tool.

    File-provider scenarios only — the vault/kmip variants need running
    external services and live in the bash automation suite for now.
    """

    def test_binary_exists(self, install_dir: Path):
        """The CLI tool must ship in the install. All other tests assume this."""
        assert _bin(install_dir).is_file(), (
            f"pg_tde_change_key_provider not found at {_bin(install_dir)}; "
            "this build does not ship the CLI tool."
        )

    def test_change_file_provider_path_offline(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        Move a file provider's keyfile to a new location while the server
        is stopped, then update the cluster's provider config via
        ``pg_tde_change_key_provider``. After restart the cluster must
        load the principal key from the new path and serve the encrypted
        data that was inserted before the move.

        Verifies the tool actually *applies* a configuration change —
        we delete the old keyfile before restart, so the cluster can only
        decrypt if it really is reading from the new path.
        """
        old_keyfile = tmp_path / "ckp_key_old.per"
        new_keyfile = tmp_path / "ckp_key_new.per"

        cluster = _build_db_tde_cluster(pg_factory, tmp_path, old_keyfile)
        try:
            assert old_keyfile.exists(), (
                "The file provider did not create a keyfile at the requested path."
            )

            cluster.execute(
                "CREATE TABLE ckp_t (id INT, payload TEXT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO ckp_t "
                "SELECT i, md5(i::text) FROM generate_series(1, 200) i"
            )
            cluster.execute("CHECKPOINT")
            db_oid = _postgres_db_oid(cluster)

            cluster.stop()

            # Move (not copy — proving the tool routes to the new path).
            shutil.copy(str(old_keyfile), str(new_keyfile))
            old_keyfile.unlink()
            assert new_keyfile.exists() and not old_keyfile.exists()

            result = _run_change_kp(
                install_dir,
                "-D", str(cluster.data_dir),
                str(db_oid),
                "ckp_provider",
                "file",
                str(new_keyfile),
            )
            assert result.returncode == 0, (
                "pg_tde_change_key_provider failed:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )

            cluster.start()
            cluster.wait_ready(timeout=60)

            # Encrypted data must be readable — proves the cluster loaded
            # the principal key from the NEW keyfile path.
            count = cluster.fetchone("SELECT COUNT(*) FROM ckp_t")
            assert count == "200", (
                f"Encrypted data not readable after path change: count={count}. "
                "pg_tde_change_key_provider may not have updated the config."
            )

            # And the provider listing must report the new path.
            listed_options = cluster.fetchone(
                "SELECT options FROM pg_tde_list_all_database_key_providers() "
                "WHERE name = 'ckp_provider'"
            )
            assert str(new_keyfile) in (listed_options or ""), (
                "pg_tde_list_all_database_key_providers() does not report the "
                f"new path; options column = {listed_options!r}"
            )
        finally:
            try:
                cluster.stop(check=False)
            except Exception:
                pass

    def test_change_kp_uses_pgdata_env_when_d_flag_absent(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        When ``-D`` is not supplied, the tool must read the data directory
        from the ``PGDATA`` environment variable
        (PG-1452 regression: the tool used to require -D unconditionally).
        """
        old_keyfile = tmp_path / "env_pgdata_old.per"
        new_keyfile = tmp_path / "env_pgdata_new.per"

        cluster = _build_db_tde_cluster(pg_factory, tmp_path, old_keyfile)
        try:
            cluster.execute(
                "CREATE TABLE env_pgdata_t (id INT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO env_pgdata_t SELECT generate_series(1, 50)"
            )
            db_oid = _postgres_db_oid(cluster)
            cluster.stop()

            shutil.copy(str(old_keyfile), str(new_keyfile))

            result = _run_change_kp(
                install_dir,
                # No -D — must pick up from env
                str(db_oid),
                "ckp_provider",
                "file",
                str(new_keyfile),
                env_extra={"PGDATA": str(cluster.data_dir)},
            )
            assert result.returncode == 0, (
                "pg_tde_change_key_provider with PGDATA env failed:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )

            cluster.start()
            cluster.wait_ready(timeout=60)
            assert cluster.fetchone(
                "SELECT COUNT(*) FROM env_pgdata_t"
            ) == "50"
        finally:
            try:
                cluster.stop(check=False)
            except Exception:
                pass

    def test_change_kp_fails_without_any_data_dir(self, install_dir: Path):
        """
        With neither ``-D`` nor ``PGDATA`` set, the tool must refuse to run
        and exit non-zero (no silent corruption of an unintended directory).
        """
        result = _run_change_kp(
            install_dir,
            "1", "any_provider", "file", "/tmp/dummy",
            env_extra={"PGDATA": ""},
        )
        assert result.returncode != 0, (
            "pg_tde_change_key_provider should fail when no data directory "
            f"is supplied; got returncode={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )

    def test_change_kp_fails_with_unknown_provider_name(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        Supplying a provider name that does not exist in the cluster's
        catalog must produce a non-zero exit. Catches silent no-ops.
        """
        keyfile = tmp_path / "unknown_provider.per"
        cluster = _build_db_tde_cluster(pg_factory, tmp_path, keyfile)
        try:
            db_oid = _postgres_db_oid(cluster)
            cluster.stop()

            result = _run_change_kp(
                install_dir,
                "-D", str(cluster.data_dir),
                str(db_oid),
                "name_that_does_not_exist",
                "file",
                str(keyfile),
            )
            assert result.returncode != 0, (
                "pg_tde_change_key_provider should fail when the provider "
                f"name doesn't exist; got returncode={result.returncode}, "
                f"stderr={result.stderr!r}"
            )
        finally:
            try:
                cluster.stop(check=False)
            except Exception:
                pass

    def test_change_kp_fails_with_invalid_provider_type(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        A provider type that is not ``file`` / ``vault-v2`` / ``kmip`` must
        be rejected.
        """
        keyfile = tmp_path / "invalid_type.per"
        cluster = _build_db_tde_cluster(pg_factory, tmp_path, keyfile)
        try:
            db_oid = _postgres_db_oid(cluster)
            cluster.stop()

            result = _run_change_kp(
                install_dir,
                "-D", str(cluster.data_dir),
                str(db_oid),
                "ckp_provider",
                "not_a_real_type",
                "/tmp/whatever",
            )
            assert result.returncode != 0, (
                "pg_tde_change_key_provider should fail with an unknown "
                f"provider type; got returncode={result.returncode}, "
                f"stderr={result.stderr!r}"
            )
        finally:
            try:
                cluster.stop(check=False)
            except Exception:
                pass
