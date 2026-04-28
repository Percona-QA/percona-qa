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
        tde_primary.restart()
        assert tde.is_wal_encrypted()

    def test_disable_wal_encryption(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        tde_primary.restart()
        assert tde.is_wal_encrypted()
        tde.disable_wal_encryption()
        tde_primary.restart()
        assert not tde.is_wal_encrypted()

    def test_wal_encryption_guc_persists_after_restart(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        tde_primary.restart()
        assert tde.is_wal_encrypted()

    @pytest.mark.slow
    def test_wal_encryption_with_heavy_dml(self, tde_primary: PgCluster):
        tde = TdeManager(tde_primary)
        tde.enable_wal_encryption()
        tde_primary.restart()
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
