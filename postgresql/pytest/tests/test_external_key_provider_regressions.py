"""
Regression tests for external key providers (KMIP + Vault/OpenBao).

* `PG-2125 <https://perconadev.atlassian.net/browse/PG-2125>`_ — KMIP keyring
  failures with the legacy C libkmip BIO stack; fixed by the C++ **kmipclient**
  rewrite in `PR #595 <https://github.com/percona/pg_tde/pull/595>`_.

* `PG-1959 <https://perconadev.atlassian.net/browse/PG-1959>`_ — Vault/OpenBao
  **namespace** support ([PR #442](https://github.com/percona/pg_tde/pull/442))
  and namespaced mount-path parsing ([PR #492](https://github.com/percona/pg_tde/pull/492)).

* Empty / invalid provider options for **KMIP and Vault/OpenBao** must return
  a SQL error; the backend must not crash. Broader KMIP matrix:
  ``tests/test_kmip.py::TestKmipFailureAndCornerCases``.

Prerequisites: KMIP + OpenBao setup scripts (see ``docs/kmip/README.md``, ``docs/vault.md``).
"""
from __future__ import annotations

import os
import re
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


def _assert_add_rejects_without_crash(
    cluster: PgCluster,
    sql: str,
    *,
    expect_fail: bool = True,
) -> str:
    """
    Run provider-add SQL and assert the backend stays alive.

    When ``expect_fail`` is True, the call must return a SQL error (validation /
    connect failure) rather than succeed.
    """
    result = cluster.execute_allow_error(sql)
    err = f"{result.stderr or ''}{result.stdout or ''}"
    lower = err.lower()

    _assert_postgres_alive(cluster)
    assert "server closed the connection" not in lower, (
        f"backend crashed on provider add:\nSQL: {sql}\nERR: {err}"
    )
    assert "connection to the server was lost" not in lower, (
        f"backend crashed on provider add:\nSQL: {sql}\nERR: {err}"
    )
    if expect_fail:
        assert result.returncode != 0, (
            f"expected validation/connect error, got success:\nSQL: {sql}\n{err}"
        )
    assert cluster.fetchone("SELECT 1") == "1"
    return err


def _vault_add_fn(tde: TdeManager, *, scope: str) -> str:
    if scope == "global":
        fn = tde._first_func([
            "pg_tde_add_global_key_provider_vault_v2",
            "pg_tde_add_global_key_provider_vault",
            "pg_tde_add_key_provider_vault_v2",
            "pg_tde_add_key_provider_vault",
        ])
    else:
        fn = tde._first_func([
            "pg_tde_add_database_key_provider_vault_v2",
            "pg_tde_add_database_key_provider_vault",
        ])
    if fn is None:
        pytest.skip(f"pg_tde add_{scope}_key_provider_vault* not in this build")
    return fn


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


@pytest.mark.kmip
class TestKmipEmptyCertificateParamsRegression:
    """
    Empty certificate-path arguments to ``pg_tde_add_*_key_provider_kmip`` must
    produce a SQL error; the backend must stay alive.

    Same class of bug also affects Vault/OpenBao (see
    ``TestVaultEmptyProviderParamsRegression``).

    Full parametrized matrix:
    ``test_kmip.py::TestKmipFailureAndCornerCases::test_empty_kmip_certificate_params_rejected_without_crash``.
    """

    @pytest.mark.parametrize(
        "fn,sql_args",
        [
            (
                "pg_tde_add_database_key_provider_kmip",
                "'kmip_empty_all', '127.0.0.1', 5696, '', '', ''",
            ),
            (
                "pg_tde_add_global_key_provider_kmip",
                "'kmip_empty_all', '127.0.0.1', 5696, '', '', ''",
            ),
        ],
        ids=["database_all_empty", "global_all_empty"],
    )
    def test_empty_certificate_paths_do_not_crash_backend(
        self,
        pg_factory,
        tmp_path: Path,
        kmip_config: KmipConfig,
        fn: str,
        sql_args: str,
    ):
        # kmip_config ensures the KMIP section is configured; empty paths must
        # fail in local validation before (or without relying on) a live KMS.
        _ = kmip_config
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_empty_certs")
        err = _assert_add_rejects_without_crash(
            cluster, f"SELECT {fn}({sql_args});"
        )
        assert re.search(
            r"cert|certificate|key|ca|empty|missing|invalid|path|required|file|kmip",
            err.lower(),
        ), f"unexpected error from {fn}:\n{err}"

    def test_empty_ca_with_valid_client_paths_does_not_crash_backend(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_empty_ca")
        cert, key, _ca = kmip_config.sql_literal_paths()
        host = kmip_config.connect_host().replace("'", "''")
        sql = (
            "SELECT pg_tde_add_global_key_provider_kmip("
            f"'kmip_empty_ca', '{host}', {kmip_config.port}, "
            f"'{cert}', '{key}', '');"
        )
        _assert_add_rejects_without_crash(cluster, sql)

    def test_empty_key_and_ca_with_valid_cert_does_not_crash_backend(
        self, pg_factory, tmp_path: Path, kmip_config: KmipConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "kmip_empty_key")
        cert, _key, _ca = kmip_config.sql_literal_paths()
        host = kmip_config.connect_host().replace("'", "''")
        sql = (
            "SELECT pg_tde_add_global_key_provider_kmip("
            f"'kmip_empty_key', '{host}', {kmip_config.port}, "
            f"'{cert}', '', '');"
        )
        _assert_add_rejects_without_crash(cluster, sql)


@pytest.mark.vault
@pytest.mark.openbao
class TestVaultEmptyProviderParamsRegression:
    """
    Empty / invalid Vault provider options must not crash the backend.

    Applies to HashiCorp Vault and OpenBao ``vault_v2`` providers, same as KMIP.
    """

    @pytest.mark.parametrize(
        "scope",
        ["global", "database"],
        ids=["global_all_empty", "database_all_empty"],
    )
    def test_empty_vault_provider_paths_do_not_crash_backend(
        self,
        pg_factory,
        tmp_path: Path,
        vault_config: VaultConfig,
        scope: str,
    ):
        _ = vault_config
        cluster = _tde_cluster(pg_factory, tmp_path, f"vault_empty_{scope}")
        fn = _vault_add_fn(TdeManager(cluster), scope=scope)
        # name, url, mount, token_path, ca_path — all path-like fields empty
        sql = f"SELECT {fn}('vault_empty_all', '', '', '', '');"
        err = _assert_add_rejects_without_crash(cluster, sql)
        assert re.search(
            r"vault|url|token|empty|missing|invalid|path|required|file|ca|mount",
            err.lower(),
        ), f"unexpected error from {fn}:\n{err}"

    def test_empty_token_path_with_valid_url_does_not_crash_backend(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_empty_token")
        fn = _vault_add_fn(TdeManager(cluster), scope="global")
        url = vault_config.addr.replace("'", "''")
        mount = vault_config.secret_mount.replace("'", "''")
        sql = f"SELECT {fn}('vault_empty_token', '{url}', '{mount}', '', '');"
        err = _assert_add_rejects_without_crash(cluster, sql)
        assert re.search(
            r"vault|token|empty|missing|invalid|path|required|file|auth",
            err.lower(),
        ), f"unexpected error from {fn}:\n{err}"

    def test_nonexistent_token_file_does_not_crash_backend(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_bad_token_file")
        fn = _vault_add_fn(TdeManager(cluster), scope="global")
        url = vault_config.addr.replace("'", "''")
        mount = vault_config.secret_mount.replace("'", "''")
        missing = str(tmp_path / "does_not_exist_vault_token").replace("'", "''")
        sql = (
            f"SELECT {fn}('vault_bad_token', '{url}', '{mount}', "
            f"'{missing}', '');"
        )
        err = _assert_add_rejects_without_crash(cluster, sql)
        assert re.search(
            r"vault|token|missing|invalid|path|required|file|no such|cannot|open",
            err.lower(),
        ), f"unexpected error from {fn}:\n{err}"

    def test_empty_url_with_token_file_does_not_crash_backend(
        self, pg_factory, tmp_path: Path, vault_config: VaultConfig
    ):
        cluster = _tde_cluster(pg_factory, tmp_path, "vault_empty_url")
        fn = _vault_add_fn(TdeManager(cluster), scope="database")
        token = vault_config.token_sql_arg(tmp_path).replace("'", "''")
        mount = vault_config.secret_mount.replace("'", "''")
        sql = f"SELECT {fn}('vault_empty_url', '', '{mount}', '{token}', '');"
        err = _assert_add_rejects_without_crash(cluster, sql)
        assert re.search(
            r"vault|url|empty|missing|invalid|path|required|http|address",
            err.lower(),
        ), f"unexpected error from {fn}:\n{err}"


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
                    run_dir=tmp_path / "pg1959_kvonly_policy",
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
        vault_ring = "vault_keyring11_pg1959_del"
        file_ring = "keyring_file11_pg1959_del"
        server_key = "server_key_pg1959_del"

        _add_global_vault(tde, vault_config, vault_ring, tmp_path)
        tde._execute_create_global_key_allow_duplicate(
            "SELECT pg_tde_create_key_using_global_key_provider("
            f"'{server_key}'::text, '{vault_ring}'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            f"'{server_key}'::text, '{vault_ring}'::text)"
        )
        tde.enable_wal_encryption()
        cluster.restart()
        cluster.wait_ready(timeout=60)

        tde.add_global_key_provider_file(file_ring, keyfile=keyfile)
        tde._execute_create_global_key_allow_duplicate(
            "SELECT pg_tde_create_key_using_global_key_provider("
            f"'{server_key}'::text, '{file_ring}'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            f"'{server_key}'::text, '{file_ring}'::text)"
        )

        cluster.execute(
            f"SELECT pg_tde_delete_global_key_provider('{vault_ring}')"
        )
        names = [
            ln.strip()
            for ln in cluster.execute(
                "SELECT name FROM pg_tde_list_all_global_key_providers()"
            ).splitlines()
            if ln.strip()
        ]
        assert vault_ring not in names
        assert file_ring in names
