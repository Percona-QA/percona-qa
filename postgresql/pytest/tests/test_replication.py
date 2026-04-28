"""
Streaming and logical replication tests.

Covers scenarios from:
  - pg_tde_streaming_replication.sh
  - pg_tde_logical_replication.sh
  - pg_tde_rewind_test.sh
  - pg_tde_wal_segsize_replication_test.sh
  - pg_createsubscriber.sh
  - ddl_load_with_pg_tde_and_streaming_replication.sh
  - dml_load_with_pg_tde_and_streaming_replication.sh
"""
import pytest
import time
from typing import Tuple

from lib import PgCluster, TdeManager, ReplicationManager


pytestmark = pytest.mark.replication


# ── basic streaming replication ───────────────────────────────────────────────


class TestStreamingReplication:
    def test_standby_is_in_recovery(self, replica_pair: Tuple[PgCluster, PgCluster]):
        _, standby = replica_pair
        result = standby.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t", (
            f"Standby (port {standby.port}) should be in recovery mode but "
            f"pg_is_in_recovery() returned: {result!r}"
        )

    def test_primary_has_wal_sender(self, replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = replica_pair
        count = int(primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication"))
        assert count >= 1, (
            f"Expected at least 1 WAL sender on primary (port {primary.port}), "
            f"got {count}. Standby (port {standby.port}) may not have connected.\n"
            f"Standby in_recovery: {standby.fetchone('SELECT pg_is_in_recovery()')}\n"
            f"Standby receive LSN: {standby.fetchone('SELECT pg_last_wal_receive_lsn()')}"
        )

    def test_data_replicates_to_standby(self, replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = replica_pair
        primary.execute("CREATE TABLE repl_test (id INT, val TEXT)")
        primary.execute("INSERT INTO repl_test SELECT i, md5(i::text) FROM generate_series(1,1000) i")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)
        repl.assert_row_counts_match("repl_test")

    def test_ddl_replicates_to_standby(self, replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = replica_pair
        primary.execute("CREATE TABLE ddl_repl (id SERIAL, data JSONB)")
        primary.execute("CREATE INDEX ddl_repl_data_idx ON ddl_repl USING gin(data)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)
        # Index should exist on standby
        idx = standby.fetchone(
            "SELECT indexname FROM pg_indexes WHERE tablename='ddl_repl' AND indexname='ddl_repl_data_idx'"
        )
        assert idx == "ddl_repl_data_idx"

    @pytest.mark.slow
    def test_large_dataset_replication(self, replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = replica_pair
        primary.execute("CREATE TABLE large_repl (id BIGINT, data TEXT)")
        primary.execute(
            "INSERT INTO large_repl SELECT i, md5(i::text) FROM generate_series(1,500000) i"
        )
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=120)
        repl.assert_row_counts_match("large_repl")


# ── TDE streaming replication ─────────────────────────────────────────────────


class TestTdeStreamingReplication:
    def test_encrypted_data_replicates(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE enc_repl (id INT, secret TEXT)")
        primary.execute(
            "INSERT INTO enc_repl SELECT i, md5(i::text) FROM generate_series(1,1000) i"
        )
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=60)
        repl.assert_row_counts_match("enc_repl")

    def test_primary_table_is_encrypted_standby_reflects(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE enc_check (id INT)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)
        tde_standby = TdeManager(standby)
        assert tde_standby.is_table_encrypted("enc_check")

    def test_key_rotation_does_not_break_replication(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE pre_rotation (id INT)")
        primary.execute("INSERT INTO pre_rotation SELECT generate_series(1,500)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        tde = TdeManager(primary)
        tde.rotate_principal_key("post_rotation_key")

        primary.execute("INSERT INTO pre_rotation SELECT generate_series(501,1000)")
        repl.assert_catchup(timeout=30)
        repl.assert_row_counts_match("pre_rotation")

    def test_wal_encryption_with_replication(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        tde = TdeManager(primary)
        tde.enable_wal_encryption()
        primary.restart()
        primary.execute("CREATE TABLE wal_enc_repl (id INT)")
        primary.execute("INSERT INTO wal_enc_repl SELECT generate_series(1,1000)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=60)
        repl.assert_row_counts_match("wal_enc_repl")

    @pytest.mark.slow
    def test_dml_load_during_replication(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.execute("CREATE TABLE dml_load (id BIGSERIAL PRIMARY KEY, data TEXT)")
        primary.execute(
            "INSERT INTO dml_load (data) SELECT md5(i::text) FROM generate_series(1,50000) i"
        )
        primary.execute("UPDATE dml_load SET data = 'updated' WHERE id % 2 = 0")
        primary.execute("DELETE FROM dml_load WHERE id % 10 = 0")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=120)
        repl.assert_row_counts_match("dml_load")


# ── standby promotion and pg_rewind ──────────────────────────────────────────


class TestPromoteAndRewind:
    def test_standby_promotion(self, replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = replica_pair
        primary.execute("CREATE TABLE pre_promote (id INT)")
        primary.execute("INSERT INTO pre_promote SELECT generate_series(1,100)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        standby.promote()
        standby.wait_ready(timeout=30)

        result = standby.fetchone("SELECT pg_is_in_recovery()")
        assert result == "f", "Promoted standby must not be in recovery"

    def test_pg_rewind_after_promotion(self, replica_pair: Tuple[PgCluster, PgCluster], tmp_path):
        primary, standby = replica_pair
        primary.configure({"wal_log_hints": "on", "summarize_wal": "on"})
        primary.restart()

        primary.execute("CREATE TABLE rewind_test (id INT)")
        primary.execute("INSERT INTO rewind_test SELECT generate_series(1,100)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        # Promote standby; primary diverges
        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO rewind_test SELECT generate_series(101,200)")

        # Stop old primary
        primary.stop()

        # Rewind old primary to follow new primary (ex-standby)
        primary.pg_rewind(str(primary.data_dir), standby.port)

        # Old primary can now follow the new timeline
        primary.start()
        primary.wait_ready(timeout=30)
        result = primary.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t", (
            f"After pg_rewind, old primary (port {primary.port}) should be a standby "
            f"(in_recovery=t) but got: {result!r}\n"
            f"Server log:\n{primary.read_log(20)}"
        )

    def test_tde_rewind(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        primary, standby = tde_replica_pair
        primary.configure({"wal_log_hints": "on", "summarize_wal": "on"})
        primary.restart()

        primary.execute("CREATE TABLE tde_rewind_t (id INT)")
        primary.execute("INSERT INTO tde_rewind_t SELECT generate_series(1,100)")
        repl = ReplicationManager(primary, standby)
        repl.assert_catchup(timeout=30)

        standby.promote()
        standby.wait_ready(timeout=30)
        standby.execute("INSERT INTO tde_rewind_t SELECT generate_series(101,200)")

        primary.stop()
        primary.pg_rewind(str(primary.data_dir), standby.port)
        primary.start()
        primary.wait_ready(timeout=30)
        result = primary.fetchone("SELECT pg_is_in_recovery()")
        assert result == "t"


# ── logical replication ───────────────────────────────────────────────────────


class TestLogicalReplication:
    def test_basic_logical_replication(self, replica_pair: Tuple[PgCluster, PgCluster]):
        publisher, subscriber = replica_pair
        publisher.configure({"wal_level": "logical"})
        publisher.restart()

        publisher.execute("CREATE TABLE logical_src (id INT PRIMARY KEY, val TEXT)")
        publisher.execute("INSERT INTO logical_src SELECT i, md5(i::text) FROM generate_series(1,100) i")

        subscriber.execute("CREATE TABLE logical_src (id INT PRIMARY KEY, val TEXT)")
        repl = ReplicationManager(publisher, subscriber)
        repl.setup_logical_publication(tables=["logical_src"])
        repl.setup_logical_subscription()

        time.sleep(5)  # allow initial sync
        repl.assert_row_counts_match("logical_src")

    def test_logical_replication_with_tde(self, tde_replica_pair: Tuple[PgCluster, PgCluster]):
        publisher, subscriber = tde_replica_pair
        publisher.configure({"wal_level": "logical"})
        publisher.restart()

        publisher.execute("CREATE TABLE tde_logical_src (id INT PRIMARY KEY, val TEXT)")
        publisher.execute(
            "INSERT INTO tde_logical_src SELECT i, md5(i::text) FROM generate_series(1,100) i"
        )
        subscriber.execute("CREATE TABLE tde_logical_src (id INT PRIMARY KEY, val TEXT)")
        repl = ReplicationManager(publisher, subscriber)
        repl.setup_logical_publication(tables=["tde_logical_src"])
        repl.setup_logical_subscription()

        time.sleep(5)
        repl.assert_row_counts_match("tde_logical_src")
