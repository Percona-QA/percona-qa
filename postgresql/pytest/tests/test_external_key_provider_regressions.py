"""
Regression tests for external key providers (KMIP + Vault/OpenBao).

* `PG-2125 <https://perconadev.atlassian.net/browse/PG-2125>`_ — KMIP keyring
  failures with the legacy C libkmip BIO stack; fixed by the C++ **kmipclient**
  rewrite in `PR #595 <https://github.com/percona/pg_tde/pull/595>`_.

* `PG-1959 <https://perconadev.atlassian.net/browse/PG-1959>`_ — Vault/OpenBao
  **namespace** support ([PR #442](https://github.com/percona/pg_tde/pull/442))
  and namespaced mount-path parsing ([PR #492](https://github.com/percona/pg_tde/pull/492)).

Prerequisites: KMIP + OpenBao setup scripts (see ``docs/kmip.md``, ``docs/vault.md``).
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
from lib.kmip import KmipConfig
from lib.vault import VaultConfig, create_openbao_kv_only_token

pytestmark = [pytest.mark.bug]


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


def _add_global_kmip(tde: TdeManager, kmip: KmipConfig, name: str) -> None:
    tde.add_global_key_provider_kmip(
        name,
        host=kmip.connect_host(),
        port=kmip.port,
        cert_path=kmip.client_cert,
        key_path=kmip.client_key,
        ca_path=kmip.server_ca,
    )


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


def _assert_postgres_alive(cluster: PgCluster) -> None:
    assert cluster.is_ready(), "PostgreSQL backend died (KMIP/Vault regression)"


@pytest.mark.kmip
class TestKmipCppClientRegression:
    """
    Regression for PG-2125 / PR #595 (replace buggy C libkmip with kmipclient).

    Pre-595 builds could error or destabilize the backend during REGISTER /
    LOCATE / GET; these tests assert a stable end-to-end path.
    """

    def test_kmip_full_lifecycle_multiple_restarts(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "pg2125_life")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "pg2125_ring")
        tde.set_global_principal_key("pg2125_key_a", "pg2125_ring")
        _assert_postgres_alive(cluster)

        cluster.execute(
            "CREATE TABLE pg2125_t(id INT, payload TEXT) USING tde_heap; "
            "INSERT INTO pg2125_t SELECT i, md5(i::text) FROM generate_series(1, 500) i;"
        )
        tde.rotate_principal_key("pg2125_key_b", "pg2125_ring")
        _assert_postgres_alive(cluster)
        cluster.execute("INSERT INTO pg2125_t(id, payload) VALUES (999, 'tail');")

        for _ in range(2):
            cluster.restart()
            cluster.wait_ready(timeout=90)
            _assert_postgres_alive(cluster)
            assert int(cluster.fetchone("SELECT COUNT(*) FROM pg2125_t")) >= 501
            assert cluster.fetchone(
                "SELECT payload FROM pg2125_t WHERE id = 999"
            ).strip() == "tail"

    def test_kmip_repeated_create_key_is_idempotent(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """Re-running create_key for the same name must not break the provider."""
        cluster = _tde_cluster(pg_factory, tmp_path, "pg2125_dup")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "pg2125_dup_ring")
        tde.set_global_principal_key("pg2125_dup_key", "pg2125_dup_ring")
        create_fn = tde._first_func(["pg_tde_create_key_using_global_key_provider"])
        assert create_fn is not None
        tde._execute_create_global_key_allow_duplicate(
            f"SELECT {create_fn}('pg2125_dup_key'::text, 'pg2125_dup_ring'::text)"
        )
        _assert_postgres_alive(cluster)
        cluster.execute(
            "CREATE TABLE pg2125_dup_t(id INT) USING tde_heap; "
            "INSERT INTO pg2125_dup_t VALUES (1);"
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT * FROM pg2125_dup_t").strip() == "1"

    def test_kmip_wal_encryption_with_server_key(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        """WAL encryption + KMIP server key path (stress REGISTER/GET on WAL)."""
        cluster = _tde_cluster(pg_factory, tmp_path, "pg2125_wal")
        tde = TdeManager(cluster)
        _add_global_kmip(tde, kmip_config, "pg2125_wal_ring")
        tde.set_global_principal_key("pg2125_wal_key", "pg2125_wal_ring")
        tde.enable_wal_encryption()
        _assert_postgres_alive(cluster)

        cluster.execute(
            "CREATE TABLE pg2125_wal_t(id INT) USING tde_heap; "
            "INSERT INTO pg2125_wal_t SELECT generate_series(1, 2000); "
            "CHECKPOINT;"
        )
        cluster.restart()
        cluster.wait_ready(timeout=90)
        _assert_postgres_alive(cluster)
        assert tde.is_wal_encrypted()
        assert cluster.fetchone("SELECT COUNT(*) FROM pg2125_wal_t") == "2000"

    def test_kmip_requires_cpp_kmipclient_build(
        self, install_dir: Path,
    ):
        """Document PR #595 linkage — skip when running a pre-595 pg_tde package."""
        so = install_dir / "lib" / "pg_tde.so"
        if not so.is_file():
            candidates = list((install_dir / "lib").glob("**/pg_tde.so"))
            if not candidates:
                pytest.skip(f"pg_tde.so not under {install_dir}")
            so = candidates[0]
        proc = subprocess.run(
            ["ldd", str(so)], capture_output=True, text=True, check=False
        )
        if proc.returncode != 0:
            pytest.skip(f"ldd failed: {proc.stderr}")
        out = (proc.stdout + proc.stderr).lower()
        if "libstdc++" not in out and "libc++" not in out:
            pytest.xfail(
                "PG-2125 fix (PR #595) not present: pg_tde.so lacks C++ kmipclient"
            )


@pytest.mark.vault
@pytest.mark.openbao
class TestVaultOpenBaoNamespaceRegression:
    """
    Regression for PG-1959 — namespaces + namespaced Vault JSON ([PR #442], [PR #492]).
    """

    def test_vault_namespace_provider_roundtrip_after_restart(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        assert vault_config.namespace.strip(), "PG-1959 requires --vault-namespace"
        cluster = _tde_cluster(pg_factory, tmp_path, "pg1959_ns")
        tde = TdeManager(cluster)
        _add_global_vault(tde, vault_config, "pg1959_ns_ring", tmp_path)
        tde.set_global_principal_key("pg1959_ns_key", "pg1959_ns_ring")
        cluster.execute(
            "CREATE TABLE pg1959_t(a INT) USING tde_heap; "
            "INSERT INTO pg1959_t VALUES (2125),(1959);"
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        rows = cluster.fetchone("SELECT COUNT(*) FROM pg1959_t")
        assert rows == "2"

    def test_vault_kv_only_token_without_mount_metadata(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        vault_kv_only_token_file: str,
        openbao_bin: str,
    ):
        """
        Port of ``pg_tde_openbao_vault_mount_permission_warning_test.sh``.

        Provider add + encrypted IO must succeed when the token cannot read
        ``sys/mounts`` (PG-1959 / PR #492 parser reads fields under ``data``).
        """
        assert vault_config.namespace.strip()

        token_file = vault_kv_only_token_file
        if not token_file:
            root = vault_config.token_path or vault_config.token_sql_arg(tmp_path)
            root_tok = (
                Path(root).read_text(encoding="utf-8").strip()
                if Path(root).is_file()
                else vault_config.token
            )
            bao = openbao_bin or os.environ.get("OPENBAO_BIN", "")
            if not bao or not Path(bao).is_file():
                pytest.skip(
                    "Set VAULT_KV_ONLY_TOKEN_FILE or OPENBAO_BIN / "
                    "run scripts/setup_openbao_for_pytest.sh (PG-1959 kv-only token)"
                )
            token_file = str(
                create_openbao_kv_only_token(
                    run_dir=tmp_path / "pg1959_kvonly",
                    bao_bin=Path(bao),
                    root_token=root_tok,
                    namespace=vault_config.namespace,
                    secret_mount=vault_config.secret_mount,
                    vault_addr=vault_config.addr,
                )
            )

        restricted = vault_config.with_token_path(token_file)
        cluster = _tde_cluster(pg_factory, tmp_path, "pg1959_kvonly")
        tde = TdeManager(cluster)

        tde.add_database_key_provider_vault(
            "vault_keyring1",
            vault_url=restricted.addr,
            secret_mount_point=restricted.secret_mount,
            token_path=restricted.token_sql_arg(tmp_path),
            ca_path=restricted.ca_path,
            namespace=restricted.namespace,
            dbname="postgres",
        )
        _add_global_vault(tde, restricted, "vault_keyring2", tmp_path)

        # Shared OpenBao dev server — keys may exist from earlier tests in the suite.
        tde._execute_create_global_key_allow_duplicate(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'vault_key1', 'vault_keyring1')"
        )
        tde._execute_create_global_key_allow_duplicate(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'server_key1', 'vault_keyring2')"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'vault_key1', 'vault_keyring1')"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            "'server_key1', 'vault_keyring2')"
        )
        cluster.execute(
            "CREATE TABLE pg1959_kv_t(a INT) USING tde_heap; "
            "INSERT INTO pg1959_kv_t VALUES (100),(200);"
        )
        cluster.restart()
        cluster.wait_ready(timeout=60)
        assert cluster.fetchone("SELECT COUNT(*) FROM pg1959_kv_t") == "2"

    def test_vault_delete_provider_after_server_key_on_file(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        """
        open_bao_tests scenario 11 — delete namespaced global Vault provider
        after server/WAL key moved to a file provider.
        """
        assert vault_config.namespace.strip()
        keyfile = str(tmp_path / "pg1959_file11.per")
        cluster = _tde_cluster(pg_factory, tmp_path, "pg1959_del")
        tde = TdeManager(cluster)

        _add_global_vault(tde, vault_config, "vault_keyring11", tmp_path)
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'server_key', 'vault_keyring11')"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            "'server_key', 'vault_keyring11')"
        )
        tde.enable_wal_encryption()
        cluster.restart()
        cluster.wait_ready(timeout=60)

        tde.add_global_key_provider_file("keyring_file11", keyfile=keyfile)
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'server_key', 'keyring_file11')"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            "'server_key', 'keyring_file11')"
        )

        cluster.execute(
            "SELECT pg_tde_delete_global_key_provider('vault_keyring11')"
        )
        names = [
            ln.strip()
            for ln in cluster.execute(
                "SELECT name FROM pg_tde_list_all_global_key_providers()"
            ).splitlines()
            if ln.strip()
        ]
        assert "vault_keyring11" not in names
        assert "keyring_file11" in names
