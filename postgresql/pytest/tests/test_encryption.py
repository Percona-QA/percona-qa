"""
pg_tde encryption tests.

Covers scenarios from:
  - pg_tde_functions_test.sh
  - pg_tde_wal_encryption_guc.sh / pg_tde_wal_encryption_segsize.sh
  - wal_encrypt_guc_test.sh
  - pg_tde_checksums_test.sh
  - pg_tde_change_key_provider_utility.sh
  - pg_tde_dynamic_encryption_state_stress_test.sh
"""
import os
import re

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums


pytestmark = pytest.mark.encryption


# Pinned expected ``pg_tde_version()`` output for the current Percona build.
# Bump this constant when intentionally moving to a newer pg_tde release;
# the version-pinning test below treats any divergence as a regression so
# that CI catches an unexpected swap of the underlying package.
#
# Override at test time without editing this file:
#     PG_TDE_EXPECTED_VERSION=2.3.0 pytest tests/test_encryption.py -k Version
EXPECTED_PG_TDE_VERSION = os.environ.get(
    "PG_TDE_EXPECTED_VERSION", "2.2.0"
)


# ── basic setup ───────────────────────────────────────────────────────────────


class TestTdeSetup:
    def test_extension_creates_successfully(self, tde_primary: PgCluster):
        result = tde_primary.fetchone(
            "SELECT extname FROM pg_extension WHERE extname = 'pg_tde'"
        )
        assert result == "pg_tde"

    def test_default_table_access_method_is_tde_heap(self, tde_primary: PgCluster):
        result = tde_primary.fetchone(
            "SHOW default_table_access_method"
        )
        assert result == "tde_heap"

    def test_create_encrypted_table(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE enc_test (id INT, val TEXT)")
        tde_primary.execute("INSERT INTO enc_test VALUES (1, 'hello')")
        count = tde_primary.fetchone("SELECT COUNT(*) FROM enc_test")
        assert count == "1"

    def test_table_is_encrypted(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE t_enc_check (id INT)")
        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("t_enc_check")

    def test_heap_table_not_encrypted(self, tde_primary: PgCluster):
        tde_primary.execute(
            "CREATE TABLE t_heap (id INT) USING heap"
        )
        tde = TdeManager(tde_primary)
        assert not tde.is_table_encrypted("t_heap")


# ── pg_tde version pinning ────────────────────────────────────────────────────


# pg_tde_version() has historically returned either a bare ``X.Y.Z`` string
# or a prefixed form such as ``pg_tde 2.1.2``. Accept both shapes when
# extracting the semantic version number — assertions then pin on the
# X.Y.Z payload.
_PG_TDE_VERSION_RE = re.compile(r"\b(\d+)\.(\d+)\.(\d+)\b")


def _extract_pg_tde_version(raw: str) -> str:
    """Return the bare ``X.Y.Z`` payload from ``pg_tde_version()`` output."""
    assert raw, "pg_tde_version() returned an empty / NULL result"
    m = _PG_TDE_VERSION_RE.search(raw)
    assert m is not None, (
        f"pg_tde_version() returned {raw!r}; expected an X.Y.Z fragment "
        "(e.g. '2.2.0' or 'pg_tde 2.2.0')."
    )
    return f"{m.group(1)}.{m.group(2)}.{m.group(3)}"


class TestPgTdeVersion:
    """
    Pin the pg_tde version shipped by the build under test.

    A version mismatch is one of the few "the wrong package was installed"
    failure modes that can produce a fully-working cluster while still
    being wrong for the test plan. These tests catch that early, before a
    much harder-to-diagnose semantic-behaviour test fails downstream.

    Expected version is taken from ``EXPECTED_PG_TDE_VERSION`` (default
    pinned at the top of this module). Override with the
    ``PG_TDE_EXPECTED_VERSION`` env var when CI moves to a new build.
    """

    def test_pg_tde_version_function_callable(self, tde_primary: PgCluster):
        """``SELECT pg_tde_version()`` must be callable and non-empty."""
        raw = tde_primary.fetchone("SELECT pg_tde_version()")
        assert raw, (
            "pg_tde_version() returned NULL/empty; the SQL function is "
            "not present in this build."
        )

    def test_pg_tde_version_matches_expected(self, tde_primary: PgCluster):
        """
        ``SELECT pg_tde_version()`` must report exactly
        ``EXPECTED_PG_TDE_VERSION`` (default 2.2.0). A mismatch means the
        installed pg_tde package does not match the version the test plan
        was written against — bump the constant or fix the build.
        """
        raw = tde_primary.fetchone("SELECT pg_tde_version()")
        actual = _extract_pg_tde_version(raw or "")
        assert actual == EXPECTED_PG_TDE_VERSION, (
            f"pg_tde version mismatch: pg_tde_version()={raw!r} "
            f"(parsed {actual!r}) but the test plan expects "
            f"{EXPECTED_PG_TDE_VERSION!r}. Either install the correct "
            "package or override via PG_TDE_EXPECTED_VERSION."
        )

    def test_pg_tde_version_format_is_semver(self, tde_primary: PgCluster):
        """
        Pin the output format so a future build that changes the shape
        (e.g. adds a build suffix, drops the patch component, or returns
        a SETOF record) trips this test instead of a downstream regex
        elsewhere in the suite.
        """
        raw = (tde_primary.fetchone("SELECT pg_tde_version()") or "").strip()
        # The raw output must contain a clean X.Y.Z fragment and nothing
        # exotic like multiple version numbers.
        matches = _PG_TDE_VERSION_RE.findall(raw)
        assert len(matches) == 1, (
            f"pg_tde_version() returned {raw!r}; expected exactly one "
            f"X.Y.Z fragment, got {len(matches)}."
        )

    def test_extversion_aligned_with_pg_tde_version(
        self, tde_primary: PgCluster
    ):
        """
        ``pg_extension.extversion`` and the binary ``pg_tde_version()``
        must agree on the major.minor portion. The control file's
        ``default_version`` is typically ``X.Y`` (no patch component) so
        we compare ``X.Y`` from both.

        Catches the "binary upgraded but ALTER EXTENSION UPDATE wasn't
        run" state — a build that ships pg_tde 2.2 but still has a 2.1
        catalog entry, or vice versa.
        """
        ext_ver = tde_primary.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_ver, "pg_tde extension is not installed in the cluster"

        bin_ver_raw = tde_primary.fetchone("SELECT pg_tde_version()")
        bin_xyz = _extract_pg_tde_version(bin_ver_raw or "")

        ext_major_minor = ".".join(ext_ver.split(".")[:2])
        bin_major_minor = ".".join(bin_xyz.split(".")[:2])
        assert ext_major_minor == bin_major_minor, (
            "Catalog vs binary version mismatch: "
            f"pg_extension.extversion={ext_ver!r} (major.minor "
            f"{ext_major_minor!r}) vs pg_tde_version()={bin_ver_raw!r} "
            f"(major.minor {bin_major_minor!r}). Run "
            "`ALTER EXTENSION pg_tde UPDATE` or reinstall the package."
        )


# ── ALTER DATABASE ... SET TABLESPACE ────────────────────────────────────────


class TestAlterDatabaseSetTablespace:
    @staticmethod
    def _setup_tde_in_db(cluster: PgCluster, dbname: str) -> None:
        """Enable pg_tde objects in a newly created database."""
        tde = TdeManager(cluster)
        tde.create_extension(dbname=dbname)
        # Ensure the database-level key is set for this DB as well.
        tde.set_global_principal_key(dbname=dbname)

    def test_refuses_when_encrypted_objects_exist_in_default_tablespace(
        self, tde_primary: PgCluster, tmp_path
    ):
        dbname = "tde_block_db"
        target_dir = tmp_path / "tde_block_target_ts"
        target_dir.mkdir()

        tde_primary.execute(f"CREATE DATABASE {dbname}")
        self._setup_tde_in_db(tde_primary, dbname)
        tde_primary.execute("CREATE TABLE enc_in_default (id INT)", dbname)
        tde_primary.execute("INSERT INTO enc_in_default VALUES (1)", dbname)
        tde_primary.execute(
            f"CREATE TABLESPACE tde_block_target LOCATION '{target_dir}'"
        )

        old_oid = tde_primary.fetchone(
            f"SELECT dattablespace FROM pg_database WHERE datname = '{dbname}'",
            "template1",
        )

        with pytest.raises(RuntimeError):
            tde_primary.execute(
                f"ALTER DATABASE {dbname} SET TABLESPACE tde_block_target",
                "template1",
            )

        new_oid = tde_primary.fetchone(
            f"SELECT dattablespace FROM pg_database WHERE datname = '{dbname}'",
            "template1",
        )
        assert new_oid == old_oid
        assert tde_primary.fetchone("SELECT COUNT(*) FROM enc_in_default", dbname) == "1"

    def test_allows_when_default_tablespace_has_no_encrypted_objects(
        self, tde_primary: PgCluster, tmp_path
    ):
        dbname = "tde_allow_db"
        outside_dir = tmp_path / "tde_allow_outside_ts"
        target_dir = tmp_path / "tde_allow_target_ts"
        outside_dir.mkdir()
        target_dir.mkdir()

        tde_primary.execute(
            f"CREATE TABLESPACE tde_allow_outside LOCATION '{outside_dir}'"
        )
        tde_primary.execute(
            f"CREATE TABLESPACE tde_allow_target LOCATION '{target_dir}'"
        )
        tde_primary.execute(f"CREATE DATABASE {dbname}")
        self._setup_tde_in_db(tde_primary, dbname)

        # Keep encrypted data outside the database's default tablespace.
        tde_primary.execute(
            "CREATE TABLE enc_outside_default (id INT) TABLESPACE tde_allow_outside",
            dbname,
        )
        tde_primary.execute("INSERT INTO enc_outside_default VALUES (42)", dbname)

        tde_primary.execute(
            f"ALTER DATABASE {dbname} SET TABLESPACE tde_allow_target",
            "template1",
        )

        ts_name = tde_primary.fetchone(
            "SELECT t.spcname FROM pg_database d "
            "JOIN pg_tablespace t ON t.oid = d.dattablespace "
            f"WHERE d.datname = '{dbname}'",
            "template1",
        )
        assert ts_name == "tde_allow_target"
        assert tde_primary.fetchone("SELECT COUNT(*) FROM enc_outside_default", dbname) == "1"

    def test_allows_for_empty_database(self, tde_primary: PgCluster, tmp_path):
        dbname = "tde_empty_db"
        target_dir = tmp_path / "tde_empty_target_ts"
        target_dir.mkdir()

        tde_primary.execute(f"CREATE DATABASE {dbname}")
        tde_primary.execute(
            f"CREATE TABLESPACE tde_empty_target LOCATION '{target_dir}'"
        )
        tde_primary.execute(
            f"ALTER DATABASE {dbname} SET TABLESPACE tde_empty_target",
            "template1",
        )

        ts_name = tde_primary.fetchone(
            "SELECT t.spcname FROM pg_database d "
            "JOIN pg_tablespace t ON t.oid = d.dattablespace "
            f"WHERE d.datname = '{dbname}'",
            "template1",
        )
        assert ts_name == "tde_empty_target"

    def test_allows_when_default_has_only_heap_objects(
        self, tde_primary: PgCluster, tmp_path
    ):
        dbname = "tde_heap_only_db"
        target_dir = tmp_path / "tde_heap_only_target_ts"
        target_dir.mkdir()

        tde_primary.execute(f"CREATE DATABASE {dbname}")
        tde_primary.execute("CREATE TABLE heap_only (id INT) USING heap", dbname)
        tde_primary.execute("INSERT INTO heap_only VALUES (1)", dbname)
        tde_primary.execute(
            f"CREATE TABLESPACE tde_heap_only_target LOCATION '{target_dir}'"
        )
        tde_primary.execute(
            f"ALTER DATABASE {dbname} SET TABLESPACE tde_heap_only_target",
            "template1",
        )

        ts_name = tde_primary.fetchone(
            "SELECT t.spcname FROM pg_database d "
            "JOIN pg_tablespace t ON t.oid = d.dattablespace "
            f"WHERE d.datname = '{dbname}'",
            "template1",
        )
        assert ts_name == "tde_heap_only_target"
        assert tde_primary.fetchone("SELECT COUNT(*) FROM heap_only", dbname) == "1"

    def test_refuses_with_mixed_heap_and_encrypted_in_default(
        self, tde_primary: PgCluster, tmp_path
    ):
        dbname = "tde_mixed_block_db"
        target_dir = tmp_path / "tde_mixed_block_target_ts"
        target_dir.mkdir()

        tde_primary.execute(f"CREATE DATABASE {dbname}")
        self._setup_tde_in_db(tde_primary, dbname)
        tde_primary.execute("CREATE TABLE heap_tbl (id INT) USING heap", dbname)
        tde_primary.execute("CREATE TABLE enc_tbl (id INT)", dbname)
        tde_primary.execute(
            f"CREATE TABLESPACE tde_mixed_block_target LOCATION '{target_dir}'"
        )

        with pytest.raises(RuntimeError):
            tde_primary.execute(
                f"ALTER DATABASE {dbname} SET TABLESPACE tde_mixed_block_target",
                "template1",
            )


# ── key management ────────────────────────────────────────────────────────────


class TestKeyManagement:
    def test_file_key_provider_registered(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        assert tde.list_key_providers() >= 1

    def test_principal_key_is_active(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        assert tde.principal_key_name() is not None

    def test_key_rotation(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE before_rotation (id INT)")
        tde_primary.execute("INSERT INTO before_rotation SELECT generate_series(1,100)")
        tde = TdeManager(tde_primary)
        tde.rotate_principal_key(new_key_name="rotated_key")
        count = tde_primary.fetchone("SELECT COUNT(*) FROM before_rotation")
        assert count == "100", "Data must be readable after key rotation"

    def test_multiple_key_providers(self, pg_factory):
        cluster = pg_factory("multi_kp")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(provider_name="provider_a", keyfile="/tmp/pg_tde_a.per")
        tde.add_global_key_provider_file(provider_name="provider_b", keyfile="/tmp/pg_tde_b.per")
        tde.set_global_principal_key("key_a", "provider_a")
        # Rotate to second provider
        tde.rotate_principal_key("key_b", "provider_b")
        assert tde.list_key_providers() == 2

    @pytest.mark.vault
    def test_vault_key_provider(self, tde_primary: PgCluster, vault_addr: str, vault_token: str):
        tde = TdeManager(tde_primary)
        tde.add_global_key_provider_vault(
            provider_name="vault_kp",
            vault_url=vault_addr,
            vault_token=vault_token,
        )
        tde.rotate_principal_key("vault_key", "vault_kp")
        assert tde.principal_key_name() == "vault_key"


# ── WAL encryption ────────────────────────────────────────────────────────────


class TestWalEncryption:
    def test_enable_wal_encryption(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        assert tde.is_wal_encrypted()

    def test_disable_wal_encryption(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        assert tde.is_wal_encrypted()
        tde.disable_wal_encryption()
        assert not tde.is_wal_encrypted()

    def test_wal_encryption_guc_persists_after_restart(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        # Extra restart to confirm the GUC survives beyond the one done by enable_wal_encryption().
        tde_primary.restart()
        assert tde.is_wal_encrypted()

    @pytest.mark.slow
    def test_wal_encryption_with_heavy_dml(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        tde_primary.execute("CREATE TABLE wal_load (id BIGINT, data TEXT)")
        tde_primary.execute(
            "INSERT INTO wal_load SELECT i, md5(i::text) FROM generate_series(1, 100000) i"
        )
        count = tde_primary.fetchone("SELECT COUNT(*) FROM wal_load")
        assert count == "100000"

    def test_wal_encryption_guc_off_by_default(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        assert not tde.is_wal_encrypted()


# ── checksums + encryption ────────────────────────────────────────────────────


class TestChecksums:
    def test_tde_requires_checksums_disabled(self, pg_factory):
        """TDE is not compatible with data checksums — on PG18+ initdb must disable them (``--no-data-checksums``); on PG17- they are already off by default."""
        cluster = pg_factory("checksum_tde")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_cs.per")
        tde.set_global_principal_key()
        cluster.execute("CREATE TABLE cs_test (id INT)")
        cluster.execute("INSERT INTO cs_test SELECT generate_series(1,1000)")
        count = cluster.fetchone("SELECT COUNT(*) FROM cs_test")
        assert count == "1000"
        result = cluster.fetchone("SHOW data_checksums")
        assert result == "off", (
            f"TDE cluster must have data checksums disabled, got: {result!r}"
        )

    def test_no_checksums_with_tde(self, pg_factory):
        cluster = pg_factory("nochecksum_tde")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_ncs.per")
        tde.set_global_principal_key()
        cluster.execute("CREATE TABLE ncs_test (id INT)")
        cluster.execute("INSERT INTO ncs_test SELECT generate_series(1,1000)")
        count = cluster.fetchone("SELECT COUNT(*) FROM ncs_test")
        assert count == "1000"


# ── dynamic encryption state ──────────────────────────────────────────────────


@pytest.mark.slow
class TestDynamicEncryptionState:
    def test_convert_heap_table_to_tde_heap(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE initially_heap (id INT) USING heap")
        tde_primary.execute("INSERT INTO initially_heap SELECT generate_series(1,1000)")
        tde_primary.execute("ALTER TABLE initially_heap SET ACCESS METHOD tde_heap")
        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("initially_heap")
        count = tde_primary.fetchone("SELECT COUNT(*) FROM initially_heap")
        assert count == "1000"

    def test_convert_tde_heap_table_to_heap(self, tde_primary: PgCluster):
        tde_primary.execute("CREATE TABLE initially_enc (id INT)")  # uses tde_heap default
        tde_primary.execute("INSERT INTO initially_enc SELECT generate_series(1,500)")
        tde_primary.execute("ALTER TABLE initially_enc SET ACCESS METHOD heap")
        tde = TdeManager(tde_primary)
        assert not tde.is_table_encrypted("initially_enc")
        count = tde_primary.fetchone("SELECT COUNT(*) FROM initially_enc")
        assert count == "500"

    def test_concurrent_key_rotation_during_dml(self, tde_primary: PgCluster):
        """Key rotation must not corrupt in-flight data."""
        tde_primary.execute("CREATE TABLE rotation_stress (id BIGINT)")
        tde_primary.execute(
            "INSERT INTO rotation_stress SELECT generate_series(1,10000)"
        )
        tde = TdeManager(tde_primary)
        tde.rotate_principal_key("stress_key")
        tde_primary.execute(
            "INSERT INTO rotation_stress SELECT generate_series(10001,20000)"
        )
        count = tde_primary.fetchone("SELECT COUNT(*) FROM rotation_stress")
        assert count == "20000"


# ── pg_tde.cipher GUC ─────────────────────────────────────────────────────────


def _make_tde_cluster_with_cipher(
    pg_factory,
    name: str,
    cipher: str,
    keyfile: str,
) -> PgCluster:
    """
    Build a fresh TDE cluster with ``pg_tde.cipher`` set to *cipher* before
    any key or table is created. Returns the started cluster with pg_tde
    set up (extension + file key provider + principal key).
    """
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(
        extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
            "pg_tde.cipher": f"'{cipher}'",
        }
    )
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=keyfile)
    tde.set_global_principal_key()
    return cluster


class TestTdeCipher:
    """
    ``pg_tde.cipher`` GUC coverage.

    pg_tde supports two AES variants for heap/WAL encryption:
      - ``aes_128`` (default, 128-bit key)
      - ``aes_256`` (256-bit key — stronger, slightly slower)

    These tests verify the GUC is honoured, persists across restarts,
    actually changes the produced ciphertext, and rejects bogus values.
    """

    def test_default_cipher_is_aes_128(self, tde_primary: PgCluster):
        """Default cipher must be aes_128 (matches Percona docs)."""
        assert tde_primary.fetchone("SHOW pg_tde.cipher") == "aes_128"

    def test_aes_256_activation_and_table_usable(self, pg_factory, tmp_path):
        """``pg_tde.cipher = aes_256`` is accepted; encrypted tables work normally."""
        cluster = _make_tde_cluster_with_cipher(
            pg_factory, "cipher_aes256",
            cipher="aes_256",
            keyfile=str(tmp_path / "key_aes256.per"),
        )
        assert cluster.fetchone("SHOW pg_tde.cipher") == "aes_256"

        cluster.execute("CREATE TABLE t_aes256 (id INT, val TEXT)")
        cluster.execute(
            "INSERT INTO t_aes256 "
            "SELECT i, md5(i::text) FROM generate_series(1, 1000) i"
        )
        assert cluster.fetchone("SELECT COUNT(*) FROM t_aes256") == "1000"
        assert TdeManager(cluster).is_table_encrypted("t_aes256")

    def test_aes_256_ciphertext_is_not_plaintext(self, pg_factory, tmp_path):
        """
        On-disk heap pages encrypted with aes_256 must not contain the
        plaintext marker we inserted — catches a regression where the GUC
        is honoured at SHOW time but encryption is silently bypassed.
        """
        cluster = _make_tde_cluster_with_cipher(
            pg_factory, "cipher_plaintext_check",
            cipher="aes_256",
            keyfile=str(tmp_path / "key_pt_check.per"),
        )
        marker = "MARKER-aes256-must-not-appear-on-disk-7f4c"
        cluster.execute("CREATE TABLE pt_check (id INT, payload TEXT)")
        cluster.execute(f"INSERT INTO pt_check VALUES (1, '{marker}')")
        cluster.execute("CHECKPOINT")

        relpath = cluster.fetchone("SELECT pg_relation_filepath('pt_check')")
        heap_bytes = (cluster.data_dir / relpath).read_bytes()
        assert marker.encode() not in heap_bytes, (
            "Plaintext marker leaked into the encrypted heap file — "
            "encryption may be off despite SHOW pg_tde.cipher = aes_256."
        )

    def test_ciphertext_differs_between_aes_128_and_aes_256(
        self, pg_factory, tmp_path
    ):
        """
        Same plaintext + same workflow but different ``pg_tde.cipher``
        values must produce *different* on-disk bytes. Both clusters are
        sanity-checked via SHOW so we know the GUC isn't being silently
        ignored.
        """
        marker = "compare-cipher-payload-12345-x9"

        cluster128 = _make_tde_cluster_with_cipher(
            pg_factory, "cipher_compare_128",
            cipher="aes_128",
            keyfile=str(tmp_path / "key_compare_128.per"),
        )
        cluster256 = _make_tde_cluster_with_cipher(
            pg_factory, "cipher_compare_256",
            cipher="aes_256",
            keyfile=str(tmp_path / "key_compare_256.per"),
        )
        assert cluster128.fetchone("SHOW pg_tde.cipher") == "aes_128"
        assert cluster256.fetchone("SHOW pg_tde.cipher") == "aes_256"

        for c in (cluster128, cluster256):
            c.execute("CREATE TABLE cmp (id INT PRIMARY KEY, payload TEXT)")
            c.execute(f"INSERT INTO cmp VALUES (1, '{marker}')")
            c.execute("CHECKPOINT")

        path128 = cluster128.fetchone("SELECT pg_relation_filepath('cmp')")
        path256 = cluster256.fetchone("SELECT pg_relation_filepath('cmp')")
        bytes128 = (cluster128.data_dir / path128).read_bytes()
        bytes256 = (cluster256.data_dir / path256).read_bytes()

        assert bytes128 != bytes256, (
            "aes_128 and aes_256 produced byte-identical on-disk content — "
            "the cipher GUC may not be taking effect on heap pages."
        )
        assert marker.encode() not in bytes128, "plaintext leaked under aes_128"
        assert marker.encode() not in bytes256, "plaintext leaked under aes_256"

    def test_cipher_setting_persists_after_restart(self, pg_factory, tmp_path):
        """``pg_tde.cipher`` is written to postgresql.conf; it must survive a restart."""
        cluster = _make_tde_cluster_with_cipher(
            pg_factory, "cipher_restart",
            cipher="aes_256",
            keyfile=str(tmp_path / "key_restart.per"),
        )
        assert cluster.fetchone("SHOW pg_tde.cipher") == "aes_256"
        cluster.restart()
        cluster.wait_ready()
        assert cluster.fetchone("SHOW pg_tde.cipher") == "aes_256"
        # Data inserted before the restart must still be readable.
        cluster.execute("CREATE TABLE persist_t (id INT)")
        cluster.execute("INSERT INTO persist_t SELECT generate_series(1, 100)")
        cluster.restart()
        cluster.wait_ready()
        assert cluster.fetchone("SHOW pg_tde.cipher") == "aes_256"
        assert cluster.fetchone("SELECT COUNT(*) FROM persist_t") == "100"

    def test_invalid_cipher_rejected_at_runtime(self, tde_primary: PgCluster):
        """An invalid enum value must be rejected by postgres at SET time."""
        with pytest.raises(RuntimeError):
            tde_primary.execute("SET pg_tde.cipher = 'aes_999'")
        # The cluster must still be healthy after the rejected SET.
        assert tde_primary.fetchone("SHOW pg_tde.cipher") in ("aes_128", "aes_256")


# ── WAL segment size × WAL encryption ─────────────────────────────────────────


@pytest.mark.slow
class TestWalSegmentSizeWithEncryption:
    """
    ``pg_tde.wal_encrypt`` must work across all supported WAL segment sizes,
    not just the 16 MB default that every other test uses.

    Catches segment-boundary encryption bugs — anywhere pg_tde's WAL
    handling implicitly assumes 16 MB segments (e.g. key rotation tied to
    segment count, buffers sized to the default, IV/nonce derivations that
    cap at 16 MB worth of records). Both extremes are tested:

      - **1 MB** segments — boundaries hit frequently; smallest supported size.
      - **64 MB** segments — fewest boundary transitions; largest common size.

    Closes the gap from the baseline coverage report:
    ``pg_tde_wal_encryption_segsize.sh`` had no pytest equivalent.
    """

    # Each row's payload size in WAL drives how many rows we need to cross
    # a segment boundary. With the default 60-byte payload, 50k rows yield
    # only ~14 MB of WAL — fine for 1MB segments, far from filling one 64MB
    # segment. Use ``payload_repeat`` to scale row size per segment-size.
    @pytest.mark.parametrize("wal_segsize_mb,target_rows,payload_repeat", [
        pytest.param(1, 2000, 1, id="1MB-segments"),
        # 100k rows × ~1KB payload ≈ 120MB WAL → spans ≥2 segments at 64MB.
        pytest.param(64, 100_000, 30, id="64MB-segments"),
    ])
    def test_wal_segment_size_with_encryption(
        self, pg_factory, tmp_path, wal_segsize_mb, target_rows, payload_repeat
    ):
        cluster = pg_factory(f"wal_segsize_{wal_segsize_mb}MB")
        cluster.initdb(extra_args=[
            f"--wal-segsize={wal_segsize_mb}",
            *initdb_args_no_data_checksums(cluster.install_dir),
        ])
        # Postgres requires min_wal_size >= 2 × wal_segment_size and
        # max_wal_size >= 2 × wal_segment_size. Defaults (80MB / 1GB) are
        # fine for 1MB segments but make a 64MB-segment cluster refuse to
        # start ("min_wal_size must be at least twice wal_segment_size").
        # Use 4× the segment size so checkpoints have headroom too.
        min_wal_mb = max(80, wal_segsize_mb * 4)
        max_wal_mb = max(1024, wal_segsize_mb * 8)
        cluster.write_default_config(extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
            "min_wal_size": f"'{min_wal_mb}MB'",
            "max_wal_size": f"'{max_wal_mb}MB'",
        })
        cluster.add_hba_entry("local all all trust")
        cluster.start()

        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(
            keyfile=str(tmp_path / f"segsize_{wal_segsize_mb}.file")
        )
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        assert tde.is_wal_encrypted(), (
            "WAL encryption did not engage — test would otherwise pass "
            "trivially without exercising segment-boundary encryption."
        )

        # Verify the segment size we asked for is actually in effect.
        # SHOW returns a human size like "1MB" / "64MB".
        wal_seg_show = cluster.fetchone("SHOW wal_segment_size")
        assert wal_seg_show == f"{wal_segsize_mb}MB", (
            f"wal_segment_size is {wal_seg_show!r}; expected "
            f"'{wal_segsize_mb}MB' (initdb --wal-segsize not honoured)."
        )

        # Write data with a unique marker so we can verify no plaintext
        # leaks into any segment regardless of where boundaries fall.
        marker = f"SEGSIZE-{wal_segsize_mb}MB-marker-x4f-leak-check"
        cluster.execute(
            "CREATE TABLE seg_test "
            "(id INT PRIMARY KEY, payload TEXT) USING tde_heap"
        )
        # ``payload_repeat`` controls per-row WAL volume so we span ≥2
        # segments regardless of the parametrized segment size:
        #   - 1MB  segments: repeat=1   → ~60-byte payload  × 2000 rows ≈ 3MB WAL
        #   - 64MB segments: repeat=30  → ~1KB  payload × 100k rows ≈ 120MB WAL
        cluster.execute(
            "INSERT INTO seg_test "
            f"SELECT i, '{marker}-' || repeat(md5(i::text), {payload_repeat}) "
            f"FROM generate_series(1, {target_rows}) i"
        )
        cluster.execute("CHECKPOINT")
        cluster.execute("SELECT pg_switch_wal()")

        # We must have at least 2 segments on disk — otherwise we are not
        # actually testing the boundary case.
        pg_wal = cluster.data_dir / "pg_wal"
        segs = sorted(
            p for p in pg_wal.iterdir()
            if p.is_file() and len(p.name) == 24 and "." not in p.name
        )
        assert len(segs) >= 2, (
            f"Only {len(segs)} WAL segment(s) generated with "
            f"--wal-segsize={wal_segsize_mb}MB and {target_rows} rows; "
            "increase target_rows so the workload crosses a boundary."
        )

        # Each segment file must match the configured size exactly.
        expected_bytes = wal_segsize_mb * 1024 * 1024
        for seg in segs:
            actual = seg.stat().st_size
            assert actual == expected_bytes, (
                f"WAL segment {seg.name} is {actual} bytes; "
                f"expected {expected_bytes} for --wal-segsize={wal_segsize_mb}."
            )

        # Plaintext marker must not appear in any segment on disk.
        marker_bytes = marker.encode()
        for seg in segs:
            assert marker_bytes not in seg.read_bytes(), (
                f"Plaintext marker leaked into encrypted segment "
                f"{seg.name} ({wal_segsize_mb}MB). WAL encryption may not "
                "engage correctly at this segment size."
            )

        # Crash-recover loop forces the encrypted-WAL replay path through
        # multiple {wal_segsize_mb}MB segments — catches decryption bugs
        # specific to segment transitions.
        cluster.crash()
        cluster.start()
        cluster.wait_ready(timeout=60)

        recovered = cluster.fetchone("SELECT COUNT(*) FROM seg_test")
        assert int(recovered) == target_rows, (
            f"After crash recovery with --wal-segsize={wal_segsize_mb}MB: "
            f"expected {target_rows} rows, got {recovered}. "
            "Likely a decryption bug at a WAL segment boundary."
        )

        # No decryption errors in the recovery log.
        server_log = cluster.read_log(last_n=300)
        for needle in ("could not decrypt", "decryption failed",
                       "invalid encrypted"):
            assert needle.lower() not in server_log.lower(), (
                f"Server log contains {needle!r} after crash recovery "
                f"with --wal-segsize={wal_segsize_mb}MB.\n"
                "Log tail:\n" + server_log[-2000:]
            )


# ── pg_tde.enforce_encryption GUC ─────────────────────────────────────────────


def _set_enforce_encryption(cluster: PgCluster, value: str) -> None:
    """
    Flip ``pg_tde.enforce_encryption`` cluster-wide via ALTER SYSTEM + reload.

    ``pg_tde.enforce_encryption`` is PGC_SUSET — a per-session ``SET`` would
    only affect the connection that ran it, and ``cluster.execute`` opens a
    new psql connection per call. Using ALTER SYSTEM SET + pg_reload_conf
    makes the change visible to every subsequent ``cluster.execute`` call.
    """
    cluster.execute(f"ALTER SYSTEM SET pg_tde.enforce_encryption = {value}")
    cluster.execute("SELECT pg_reload_conf()")


class TestTdeEnforceEncryption:
    """
    ``pg_tde.enforce_encryption`` coverage.

    Acts as a security-policy switch: when ``on``, *no* unencrypted user
    table can be created (every CREATE TABLE / CREATE TABLE AS / SELECT
    INTO / ALTER TABLE … SET ACCESS METHOD must produce a ``tde_heap``
    relation). The GUC is PGC_SUSET so it applies cluster-wide once
    ALTER SYSTEM-set + pg_reload_conf'd.

    These tests close the "zero pytest coverage" gap from
    ``pytest/coverage_reports/baseline_*.md``.
    """

    def test_enforce_encryption_off_by_default(self, tde_primary: PgCluster):
        """Default value must be ``off`` (matches Percona docs)."""
        assert tde_primary.fetchone("SHOW pg_tde.enforce_encryption") == "off"

    def test_enforce_encryption_can_be_enabled(self, tde_primary: PgCluster):
        """Setting to ``on`` must be accepted and visible to new sessions."""
        _set_enforce_encryption(tde_primary, "on")
        assert tde_primary.fetchone("SHOW pg_tde.enforce_encryption") == "on"

    def test_enforce_encryption_blocks_heap_create_table(
        self, tde_primary: PgCluster
    ):
        """``CREATE TABLE … USING heap`` must be refused when enforcement is on."""
        _set_enforce_encryption(tde_primary, "on")
        with pytest.raises(RuntimeError):
            tde_primary.execute(
                "CREATE TABLE blocked_heap (id INT) USING heap"
            )
        # The cluster must still be queryable after the refused DDL.
        assert tde_primary.fetchone("SELECT 1") == "1"
        # And no relation got created.
        exists = tde_primary.fetchone(
            "SELECT to_regclass('blocked_heap')"
        )
        assert exists in ("", None), (
            f"blocked_heap should not exist; to_regclass returned {exists!r}"
        )

    def test_enforce_encryption_allows_tde_heap_create_table(
        self, tde_primary: PgCluster
    ):
        """``CREATE TABLE … USING tde_heap`` must succeed when enforcement is on."""
        _set_enforce_encryption(tde_primary, "on")
        tde_primary.execute(
            "CREATE TABLE allowed_tde (id INT) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO allowed_tde SELECT generate_series(1, 100)"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM allowed_tde"
        ) == "100"
        assert TdeManager(tde_primary).is_table_encrypted("allowed_tde")

    def test_enforce_encryption_default_access_method_satisfies(
        self, tde_primary: PgCluster
    ):
        """
        With enforcement on AND ``default_table_access_method = tde_heap``
        (the tde_primary default), a plain ``CREATE TABLE`` with no USING
        clause must succeed and produce a tde_heap relation.
        """
        _set_enforce_encryption(tde_primary, "on")
        # tde_primary already sets default_table_access_method=tde_heap.
        assert tde_primary.fetchone(
            "SHOW default_table_access_method"
        ) == "tde_heap"
        tde_primary.execute("CREATE TABLE default_tab (id INT)")
        assert TdeManager(tde_primary).is_table_encrypted("default_tab")

    def test_enforce_encryption_blocks_create_table_as_heap(
        self, tde_primary: PgCluster
    ):
        """
        CREATE TABLE AS … USING heap must also be refused. CTAS goes through
        a different code path than plain CREATE TABLE — easy place to miss.
        """
        _set_enforce_encryption(tde_primary, "on")
        with pytest.raises(RuntimeError):
            tde_primary.execute(
                "CREATE TABLE ctas_blocked USING heap "
                "AS SELECT generate_series(1, 10) AS id"
            )
        assert tde_primary.fetchone(
            "SELECT to_regclass('ctas_blocked')"
        ) in ("", None)

    def test_enforce_encryption_allows_create_table_as_tde_heap(
        self, tde_primary: PgCluster
    ):
        """CREATE TABLE AS … USING tde_heap must work when enforcement is on."""
        _set_enforce_encryption(tde_primary, "on")
        tde_primary.execute(
            "CREATE TABLE ctas_tde USING tde_heap "
            "AS SELECT generate_series(1, 50) AS id"
        )
        assert tde_primary.fetchone("SELECT COUNT(*) FROM ctas_tde") == "50"
        assert TdeManager(tde_primary).is_table_encrypted("ctas_tde")

    def test_enforce_encryption_blocks_alter_table_to_heap(
        self, tde_primary: PgCluster
    ):
        """
        ``ALTER TABLE … SET ACCESS METHOD heap`` must be refused on an
        encrypted relation when enforcement is on — preventing an operator
        from silently downgrading a sensitive table.
        """
        tde_primary.execute(
            "CREATE TABLE downgrade_target (id INT) USING tde_heap"
        )
        tde_primary.execute(
            "INSERT INTO downgrade_target SELECT generate_series(1, 100)"
        )
        _set_enforce_encryption(tde_primary, "on")
        with pytest.raises(RuntimeError):
            tde_primary.execute(
                "ALTER TABLE downgrade_target SET ACCESS METHOD heap"
            )
        # The table must remain encrypted and its data intact.
        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("downgrade_target")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM downgrade_target"
        ) == "100"

    def test_enforce_encryption_existing_heap_tables_remain_accessible(
        self, tde_primary: PgCluster
    ):
        """
        Enabling enforcement after heap tables already exist must not break
        access to those tables — enforcement controls CREATION, not access.
        """
        tde_primary.execute(
            "CREATE TABLE legacy_heap (id INT) USING heap"
        )
        tde_primary.execute(
            "INSERT INTO legacy_heap SELECT generate_series(1, 200)"
        )
        _set_enforce_encryption(tde_primary, "on")
        # Read still works.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM legacy_heap"
        ) == "200"
        # And inserts into the existing heap table also still work
        # (enforcement is about CREATE, not DML).
        tde_primary.execute("INSERT INTO legacy_heap VALUES (99999)")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM legacy_heap"
        ) == "201"

    def test_enforce_encryption_persists_after_restart(
        self, tde_primary: PgCluster
    ):
        """
        ALTER SYSTEM SET writes to postgresql.auto.conf, so the value must
        survive a restart.
        """
        _set_enforce_encryption(tde_primary, "on")
        assert tde_primary.fetchone(
            "SHOW pg_tde.enforce_encryption"
        ) == "on"
        tde_primary.restart()
        tde_primary.wait_ready()
        assert tde_primary.fetchone(
            "SHOW pg_tde.enforce_encryption"
        ) == "on", (
            "pg_tde.enforce_encryption did not survive restart — "
            "ALTER SYSTEM SET may not have written to postgresql.auto.conf."
        )
        # And the policy is still being applied after the restart.
        with pytest.raises(RuntimeError):
            tde_primary.execute(
                "CREATE TABLE post_restart (id INT) USING heap"
            )


# ── pg_tde_verify_* / pg_tde_delete_* SQL APIs ────────────────────────────────


def _pg_tde_function_exists(cluster: PgCluster, fn_name: str) -> bool:
    """Return True if a pg_proc function named ``fn_name`` is visible."""
    n = cluster.fetchone(
        f"SELECT COUNT(*) FROM pg_proc WHERE proname = '{fn_name}'"
    )
    return int(n) > 0


def _setup_default_key_cluster(
    pg_factory, tmp_path, name: str
) -> tuple:
    """
    Build a TDE cluster where the *default* principal key path is used
    (``pg_tde_set_default_key_using_global_key_provider``) — instead of
    the per-server/per-database variants the ``tde_primary`` fixture uses.

    Returns ``(cluster, TdeManager)``. The default key info is queryable
    via ``pg_tde_default_key_info()`` once this returns.
    """
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()

    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=str(tmp_path / f"{name}.file"))
    # Create the key, then set as DEFAULT (not server, not DB-scoped).
    if not _pg_tde_function_exists(
        cluster, "pg_tde_set_default_key_using_global_key_provider"
    ):
        pytest.skip(
            "pg_tde_set_default_key_using_global_key_provider not present "
            "in this build"
        )
    cluster.execute(
        "SELECT pg_tde_create_key_using_global_key_provider("
        "'def_key'::text, 'file_provider'::text)"
    )
    cluster.execute(
        "SELECT pg_tde_set_default_key_using_global_key_provider("
        "'def_key'::text, 'file_provider'::text)"
    )
    return cluster, tde


class TestTdeVerifyDeleteKeyApis:
    """
    Coverage for diagnostic and destructive pg_tde key APIs:

      Verify:  pg_tde_verify_key(),
               pg_tde_verify_server_key(),
               pg_tde_verify_default_key()
      Delete:  pg_tde_delete_key(),
               pg_tde_delete_default_key()

    Until now these had zero pytest coverage — they're the functions ops
    teams call to diagnose a broken setup or to wipe key state during
    rotation/cleanup. Tests skip cleanly when a function isn't present
    in the build, so older pg_tde versions don't fail the suite.
    """

    # ── verify ────────────────────────────────────────────────────────────

    def test_pg_tde_verify_key_on_configured_db_succeeds(
        self, tde_primary: PgCluster
    ):
        """
        With a database principal key set (the tde_primary fixture default),
        ``pg_tde_verify_key()`` must complete without raising. Any non-zero
        exit from psql means the key is not verifiable.
        """
        if not _pg_tde_function_exists(tde_primary, "pg_tde_verify_key"):
            pytest.skip("pg_tde_verify_key not present in this build")
        # No exception → key is valid. Calling it twice asserts the
        # function is also re-callable (no one-shot state).
        tde_primary.execute("SELECT pg_tde_verify_key()")
        tde_primary.execute("SELECT pg_tde_verify_key()")

    def test_pg_tde_verify_server_key_on_configured_cluster_succeeds(
        self, tde_primary: PgCluster
    ):
        """
        ``pg_tde_verify_server_key()`` must succeed on a cluster whose
        server-level principal key has been set
        (tde_primary calls pg_tde_set_server_key_using_global_key_provider).
        """
        if not _pg_tde_function_exists(tde_primary, "pg_tde_verify_server_key"):
            pytest.skip("pg_tde_verify_server_key not present in this build")
        tde_primary.execute("SELECT pg_tde_verify_server_key()")

    def test_pg_tde_verify_default_key_when_set_succeeds(
        self, pg_factory, tmp_path
    ):
        """
        ``pg_tde_verify_default_key()`` succeeds on a cluster with a
        default key set via ``pg_tde_set_default_key_using_global_key_provider``.
        """
        cluster, _ = _setup_default_key_cluster(
            pg_factory, tmp_path, "verify_default"
        )
        if not _pg_tde_function_exists(cluster, "pg_tde_verify_default_key"):
            pytest.skip("pg_tde_verify_default_key not present in this build")
        cluster.execute("SELECT pg_tde_verify_default_key()")

    def test_pg_tde_verify_key_after_rotation_succeeds(
        self, tde_primary: PgCluster
    ):
        """
        Key rotation must not break ``pg_tde_verify_key()`` — verify should
        always reflect the *current* key, not the original one.
        """
        if not _pg_tde_function_exists(tde_primary, "pg_tde_verify_key"):
            pytest.skip("pg_tde_verify_key not present in this build")
        tde = TdeManager(tde_primary)
        tde.rotate_principal_key("verify_after_rotate_key")
        tde_primary.execute("SELECT pg_tde_verify_key()")
        # And the now-active key is the rotated one, not the original.
        active = tde.principal_key_name()
        assert active == "verify_after_rotate_key", (
            f"Active principal key is {active!r}; expected the rotated key."
        )

    # ── delete ────────────────────────────────────────────────────────────

    def test_pg_tde_delete_default_key_clears_default(
        self, pg_factory, tmp_path
    ):
        """
        After ``pg_tde_delete_default_key()``, the default-key view
        (pg_tde_default_key_info) must report no key. The cluster itself
        must remain healthy and accept new key configuration.
        """
        cluster, tde = _setup_default_key_cluster(
            pg_factory, tmp_path, "delete_default"
        )
        if not _pg_tde_function_exists(cluster, "pg_tde_delete_default_key"):
            pytest.skip("pg_tde_delete_default_key not present in this build")

        # Sanity: the default key info IS populated before the delete.
        before = cluster.fetchone(
            "SELECT key_name FROM pg_tde_default_key_info()"
        )
        assert before == "def_key", (
            f"Pre-delete default key name = {before!r}; expected 'def_key'."
        )

        cluster.execute("SELECT pg_tde_delete_default_key()")

        # After delete: the info call must either return no row or raise.
        after_runtime_error = False
        after_value = None
        try:
            after_value = cluster.fetchone(
                "SELECT key_name FROM pg_tde_default_key_info()"
            )
        except RuntimeError:
            after_runtime_error = True
        assert after_runtime_error or after_value in (None, ""), (
            "After pg_tde_delete_default_key(), pg_tde_default_key_info() "
            f"still reports a key: {after_value!r}"
        )

        # Re-creating the default key after delete must succeed —
        # proves delete cleaned state properly, not just hid it.
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'def_key_again'::text, 'file_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_default_key_using_global_key_provider("
            "'def_key_again'::text, 'file_provider'::text)"
        )
        assert cluster.fetchone(
            "SELECT key_name FROM pg_tde_default_key_info()"
        ) == "def_key_again"

    def test_pg_tde_delete_key_clears_db_key(
        self, pg_factory, tmp_path
    ):
        """
        After ``pg_tde_delete_key()`` on a database, ``pg_tde_key_info()``
        must report no key (or raise). Run against a fresh database that
        has *no* encrypted tables — deleting while tde_heap tables exist
        is a separate (and potentially destructive) scenario.
        """
        cluster = pg_factory("delete_db_key")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(
            cluster.install_dir
        ))
        cluster.write_default_config(extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
        })
        cluster.add_hba_entry("local all all trust")
        cluster.start()

        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(
            keyfile=str(tmp_path / "delete_db_key.file")
        )
        tde.set_global_principal_key(key_name="db_key_to_delete")

        if not _pg_tde_function_exists(cluster, "pg_tde_delete_key"):
            pytest.skip("pg_tde_delete_key not present in this build")

        # Sanity: the DB key info is populated.
        before = cluster.fetchone("SELECT key_name FROM pg_tde_key_info()")
        assert before == "db_key_to_delete"

        cluster.execute("SELECT pg_tde_delete_key()")

        # After delete: info reports nothing (or raises).
        after_runtime_error = False
        after_value = None
        try:
            after_value = cluster.fetchone(
                "SELECT key_name FROM pg_tde_key_info()"
            )
        except RuntimeError:
            after_runtime_error = True
        assert after_runtime_error or after_value in (None, ""), (
            "After pg_tde_delete_key(), pg_tde_key_info() still reports "
            f"a key: {after_value!r}"
        )

        # And we can configure a new key on the same database.
        tde.set_global_principal_key(key_name="db_key_replacement")
        assert cluster.fetchone(
            "SELECT key_name FROM pg_tde_key_info()"
        ) == "db_key_replacement"


# ── pg_tde_delete_*_key_provider ──────────────────────────────────────────────


def _add_global_file_provider(
    cluster: PgCluster, name: str, keyfile: str
) -> None:
    """Register a global file key provider with the given name."""
    cluster.execute(
        "SELECT pg_tde_add_global_key_provider_file("
        f"'{name}'::text, '{keyfile}'::text)"
    )


def _add_database_file_provider(
    cluster: PgCluster, name: str, keyfile: str, dbname: str = "postgres"
) -> None:
    """Register a database-scope file key provider with the given name."""
    cluster.execute(
        "SELECT pg_tde_add_database_key_provider_file("
        f"'{name}'::text, '{keyfile}'::text)",
        dbname,
    )


def _split_lines(out: str) -> list:
    return [line.strip() for line in out.splitlines() if line.strip()]


def _list_global_provider_names(cluster: PgCluster) -> list:
    # Per pg_tde catalog (utility_scripts/bash_scripts/tde_functions.log):
    #   pg_tde_list_all_global_key_providers()
    #       OUT id integer, OUT name text, OUT type text, OUT options json
    # The TAP suite predates the column rename and still uses
    # ``provider_name``; that column no longer exists on current builds.
    out = cluster.execute(
        "SELECT name FROM pg_tde_list_all_global_key_providers()"
    )
    return _split_lines(out)


def _list_database_provider_names(
    cluster: PgCluster, dbname: str = "postgres"
) -> list:
    out = cluster.execute(
        "SELECT name FROM pg_tde_list_all_database_key_providers()",
        dbname,
    )
    return _split_lines(out)


def _build_provider_test_cluster(
    pg_factory, tmp_path, name: str, *, with_tde_heap: bool = False
) -> PgCluster:
    """
    Build a TDE-enabled cluster for provider-deletion tests without using
    the ``tde_primary`` fixture (which pre-configures keys we don't want
    to inherit). Caller adds providers / keys as the scenario requires.
    """
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    extra = {"shared_preload_libraries": "'pg_tde'"}
    if with_tde_heap:
        extra["default_table_access_method"] = "'tde_heap'"
    cluster.write_default_config(extra_params=extra)
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    TdeManager(cluster).create_extension()
    return cluster


class TestPgTdeDeleteKeyProvider:
    """
    Coverage for the destructive provider-management SQL APIs:

      Global scope:    pg_tde_delete_global_key_provider(name)
      Database scope:  pg_tde_delete_database_key_provider(name)

    These ports the four TAP scenarios that previously had zero pytest
    coverage:

      - t/064_delete_key_providers.pl
        (basic delete success / fails when in use / fails when missing)
      - t/074_verify_global_key_deletion_with_active_database_provider.pl
        (global provider in use by database key → delete fails)
      - t/075_delete_global_key_with_active_server_key_provider.pl
        (global provider in use as server key → delete fails;
         still fails after enabling WAL encryption)
      - t/076_delete_non_active_global_key_provider.pl
        (provider no longer in use after switch → delete succeeds)

    File providers only — vault / kmip variants live in the TAP suite and
    need external services. The contract under test is the deletion
    logic itself, which is provider-type-agnostic.
    """

    # ── delete-succeeds cases ─────────────────────────────────────────────

    def test_delete_unused_global_provider_succeeds(
        self, pg_factory, tmp_path
    ):
        """
        After switching the default key to a *new* global provider, the
        *old* provider is no longer in use and must be deletable. Verify
        it disappears from ``pg_tde_list_all_global_key_providers()``.
        Port of t/076_delete_non_active_global_key_provider.pl.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "delete_global_unused"
        )
        old_kf = tmp_path / "old.kf"
        new_kf = tmp_path / "new.kf"
        _add_global_file_provider(cluster, "old_provider", str(old_kf))
        _add_global_file_provider(cluster, "new_provider", str(new_kf))

        # Set default key with the old provider, then move to the new one.
        if not _pg_tde_function_exists(
            cluster, "pg_tde_set_default_key_using_global_key_provider"
        ):
            pytest.skip(
                "pg_tde_set_default_key_using_global_key_provider not present"
            )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'old_key'::text, 'old_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_default_key_using_global_key_provider("
            "'old_key'::text, 'old_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'new_key'::text, 'new_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_default_key_using_global_key_provider("
            "'new_key'::text, 'new_provider'::text)"
        )

        assert "old_provider" in _list_global_provider_names(cluster)
        cluster.execute(
            "SELECT pg_tde_delete_global_key_provider('old_provider')"
        )
        assert "old_provider" not in _list_global_provider_names(cluster), (
            "old_provider still listed after pg_tde_delete_global_key_provider"
        )
        # The new provider must still be there — the delete must not be
        # collateral.
        assert "new_provider" in _list_global_provider_names(cluster)

    def test_delete_unused_database_provider_succeeds(
        self, pg_factory, tmp_path
    ):
        """
        Database-scope equivalent of the global-scope success case. Add
        two database providers, switch the DB key to the second one,
        delete the first. The first must disappear from
        ``pg_tde_list_all_database_key_providers()``.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "delete_db_unused"
        )
        _add_database_file_provider(
            cluster, "old_db_provider", str(tmp_path / "old_db.kf")
        )
        _add_database_file_provider(
            cluster, "new_db_provider", str(tmp_path / "new_db.kf")
        )

        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'old_db_key'::text, 'old_db_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'old_db_key'::text, 'old_db_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'new_db_key'::text, 'new_db_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'new_db_key'::text, 'new_db_provider'::text)"
        )

        assert "old_db_provider" in _list_database_provider_names(cluster)
        cluster.execute(
            "SELECT pg_tde_delete_database_key_provider('old_db_provider')"
        )
        assert (
            "old_db_provider" not in _list_database_provider_names(cluster)
        ), (
            "old_db_provider still listed after "
            "pg_tde_delete_database_key_provider"
        )
        assert "new_db_provider" in _list_database_provider_names(cluster)

    # ── delete-fails-while-in-use cases ───────────────────────────────────

    def test_delete_global_provider_in_use_by_db_key_fails(
        self, pg_factory, tmp_path
    ):
        """
        A global provider currently set as the database principal key must
        NOT be deletable — silently losing the key bricks the database on
        next start. pg_tde must error out with "currently in use".
        Port of t/074_verify_global_key_deletion_with_active_database_provider.pl.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "in_use_db", with_tde_heap=True
        )
        _add_global_file_provider(
            cluster, "in_use_provider", str(tmp_path / "in_use.kf")
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'in_use_key'::text, 'in_use_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'in_use_key'::text, 'in_use_provider'::text)"
        )

        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('in_use_provider')"
            )
        msg = str(exc.value).lower()
        assert "currently in use" in msg or "in use" in msg, (
            "Expected pg_tde to reject deletion of an in-use provider; "
            f"got: {exc.value!r}"
        )
        # And the provider must NOT have been partially removed.
        assert "in_use_provider" in _list_global_provider_names(cluster), (
            "in_use_provider missing after a failed delete — partial state"
        )

    def test_delete_global_provider_in_use_by_server_key_fails(
        self, pg_factory, tmp_path
    ):
        """
        A global provider holding the *server* (WAL) principal key cannot
        be deleted: losing the WAL key would prevent decoding any
        post-deletion WAL record. Port of
        t/075_delete_global_key_with_active_server_key_provider.pl
        (without WAL encryption enabled — see the follow-up test for
        the wal_encrypt=on case).
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "in_use_server"
        )
        _add_global_file_provider(
            cluster, "srv_provider", str(tmp_path / "srv.kf")
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'srv_key'::text, 'srv_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            "'srv_key'::text, 'srv_provider'::text)"
        )

        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('srv_provider')"
            )
        msg = str(exc.value).lower()
        assert "currently in use" in msg or "in use" in msg, (
            "Expected pg_tde to reject deletion of an in-use server-key "
            f"provider; got: {exc.value!r}"
        )
        assert "srv_provider" in _list_global_provider_names(cluster)

    def test_delete_global_provider_with_wal_encrypt_on_fails(
        self, pg_factory, tmp_path
    ):
        """
        Same contract as the previous test but with ``pg_tde.wal_encrypt=on``
        and a server restart in between — the WAL stream is now actively
        being encrypted with the key from this provider. Deletion must
        STILL be rejected. Port of step 5-6 of
        t/075_delete_global_key_with_active_server_key_provider.pl.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "in_use_wal_enc"
        )
        _add_global_file_provider(
            cluster, "wal_provider", str(tmp_path / "wal.kf")
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'wal_key'::text, 'wal_provider'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_server_key_using_global_key_provider("
            "'wal_key'::text, 'wal_provider'::text)"
        )
        TdeManager(cluster).enable_wal_encryption()  # restarts the cluster
        assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"

        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('wal_provider')"
            )
        msg = str(exc.value).lower()
        assert "currently in use" in msg or "in use" in msg, (
            "Expected pg_tde to reject deletion of an in-use WAL-key "
            f"provider; got: {exc.value!r}"
        )
        assert "wal_provider" in _list_global_provider_names(cluster)

    def test_delete_database_provider_in_use_by_db_key_fails(
        self, pg_factory, tmp_path
    ):
        """
        Database-scope counterpart: a database provider currently set as
        the DB principal key cannot be deleted.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "in_use_db_scope"
        )
        _add_database_file_provider(
            cluster, "db_in_use", str(tmp_path / "db_in_use.kf")
        )
        cluster.execute(
            "SELECT pg_tde_create_key_using_database_key_provider("
            "'db_in_use_key'::text, 'db_in_use'::text)"
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_database_key_provider("
            "'db_in_use_key'::text, 'db_in_use'::text)"
        )

        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_database_key_provider('db_in_use')"
            )
        msg = str(exc.value).lower()
        assert "currently in use" in msg or "in use" in msg, (
            "Expected pg_tde to reject deletion of an in-use database "
            f"provider; got: {exc.value!r}"
        )
        assert "db_in_use" in _list_database_provider_names(cluster)

    # ── delete-fails-for-missing-provider cases ───────────────────────────

    def test_delete_nonexistent_global_provider_fails(
        self, pg_factory, tmp_path
    ):
        """
        Asking pg_tde to delete a global provider that was never
        registered must fail — silently succeeding would mask typos and
        let scripts assume cleanup ran when it didn't.
        Port of t/064_delete_key_providers.pl step 8.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "nonexistent_global"
        )
        before = _list_global_provider_names(cluster)
        assert "ghost_provider" not in before
        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_global_key_provider('ghost_provider')"
            )
        msg = str(exc.value).lower()
        # pg_tde historically uses "does not exists" — be lenient about
        # tense in case a future build fixes the grammar.
        assert "does not exist" in msg or "not found" in msg, (
            "Expected an error mentioning that the provider does not "
            f"exist; got: {exc.value!r}"
        )
        # Catalog must not have changed.
        assert _list_global_provider_names(cluster) == before

    def test_delete_nonexistent_database_provider_fails(
        self, pg_factory, tmp_path
    ):
        """Database-scope counterpart of the missing-provider error path."""
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "nonexistent_db"
        )
        before = _list_database_provider_names(cluster)
        assert "ghost_db_provider" not in before
        with pytest.raises(RuntimeError) as exc:
            cluster.execute(
                "SELECT pg_tde_delete_database_key_provider"
                "('ghost_db_provider')"
            )
        msg = str(exc.value).lower()
        assert "does not exist" in msg or "not found" in msg, (
            "Expected an error mentioning that the provider does not "
            f"exist; got: {exc.value!r}"
        )
        assert _list_database_provider_names(cluster) == before

    # ── persistence ───────────────────────────────────────────────────────

    def test_deleted_provider_stays_deleted_across_restart(
        self, pg_factory, tmp_path
    ):
        """
        Once a provider is deleted, it must not reappear after a restart.
        Catches regressions where the in-memory catalog is updated but
        the on-disk pg_tde state file is not flushed.
        """
        cluster = _build_provider_test_cluster(
            pg_factory, tmp_path, "delete_persist"
        )
        _add_global_file_provider(
            cluster, "keep_me", str(tmp_path / "keep.kf")
        )
        _add_global_file_provider(
            cluster, "remove_me", str(tmp_path / "remove.kf")
        )
        cluster.execute(
            "SELECT pg_tde_delete_global_key_provider('remove_me')"
        )
        assert "remove_me" not in _list_global_provider_names(cluster)

        cluster.restart()
        names = _list_global_provider_names(cluster)
        assert "remove_me" not in names, (
            "Deleted provider 'remove_me' reappeared after restart — "
            "pg_tde may not have persisted the deletion."
        )
        assert "keep_me" in names, (
            "Unaffected provider 'keep_me' disappeared across restart"
        )
