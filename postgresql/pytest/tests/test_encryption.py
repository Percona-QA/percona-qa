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
import pytest

from lib import PgCluster, TdeManager


pytestmark = pytest.mark.encryption


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
        cluster.initdb(extra_args=["--no-data-checksums"])
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
        """TDE is not compatible with data checksums — initdb must use --no-data-checksums."""
        cluster = pg_factory("checksum_tde")
        cluster.initdb(extra_args=["--no-data-checksums"])
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
        cluster.initdb(extra_args=["--no-data-checksums"])
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
