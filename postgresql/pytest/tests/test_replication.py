"""
Streaming and logical replication tests.

Covers scenarios from:
  - pg_tde_streaming_replication.sh
  - pg_tde_logical_replication.sh
  - pg_tde_rewind_test.sh (rewind cases: see test_tde_rewind_advanced.py)
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


# ── standby promotion (pg_rewind tests live in test_tde_rewind_advanced.py) ──


class TestStandbyPromotion:
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


class TestLogicalReplication:
    def test_basic_logical_replication(self, logical_pub_sub_pair: Tuple[PgCluster, PgCluster]):
        publisher, subscriber = logical_pub_sub_pair

        publisher.execute("CREATE TABLE logical_src (id INT PRIMARY KEY, val TEXT)")
        publisher.execute("INSERT INTO logical_src SELECT i, md5(i::text) FROM generate_series(1,100) i")

        subscriber.execute("CREATE TABLE logical_src (id INT PRIMARY KEY, val TEXT)")
        repl = ReplicationManager(publisher, subscriber)
        repl.setup_logical_publication(tables=["logical_src"])
        repl.setup_logical_subscription()

        time.sleep(5)  # allow initial sync
        repl.assert_row_counts_match("logical_src")

    def test_logical_replication_with_tde(self, tde_logical_pub_sub_pair: Tuple[PgCluster, PgCluster]):
        publisher, subscriber = tde_logical_pub_sub_pair

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

    def test_logical_replication_with_wal_encryption(
        self, tde_logical_pub_sub_pair: Tuple[PgCluster, PgCluster]
    ):
        """
        Logical replication must work end-to-end when *both* publisher and
        subscriber have ``pg_tde.wal_encrypt = on``. Closes the
        WAL-encryption × logical-replication coverage gap noted in the
        baseline coverage report (Phase 1 priority).

        What it proves:
          - Enabling WAL encryption on both nodes is harmless to logical
            replication (the decoder still reads WAL after re-keying).
          - Initial-table-sync (COPY phase) completes under WAL encryption.
          - Post-sync DML inserted on the publisher is decoded out of the
            encrypted WAL and applied on the subscriber.
          - Subscriber's WAL is also encrypted on disk (no plaintext leak).

        Uses polling on ``pg_subscription_rel.srsubstate`` rather than
        ``time.sleep`` — matches the "stop using sleep-and-hope" rule from
        the coverage report's quality recommendations.
        """
        publisher, subscriber = tde_logical_pub_sub_pair

        # Enable WAL encryption on both ends. pg_tde.wal_encrypt is
        # PGC_POSTMASTER so enable_wal_encryption() restarts the cluster.
        for node in (publisher, subscriber):
            TdeManager(node).enable_wal_encryption()
            assert node.fetchone("SHOW pg_tde.wal_encrypt") == "on", (
                f"WAL encryption did not engage on {node.data_dir.name}"
            )

        # Seed the publisher *before* setting up replication so the initial
        # COPY has rows to ship, then add post-sync rows below.
        marker = "wal-enc-logical-row-7d2a"
        publisher.execute(
            "CREATE TABLE wal_enc_logical (id INT PRIMARY KEY, val TEXT) "
            "USING tde_heap"
        )
        publisher.execute(
            "INSERT INTO wal_enc_logical "
            f"SELECT i, '{marker}' || i::text FROM generate_series(1, 500) i"
        )
        subscriber.execute(
            "CREATE TABLE wal_enc_logical (id INT PRIMARY KEY, val TEXT) "
            "USING tde_heap"
        )

        repl = ReplicationManager(publisher, subscriber)
        repl.setup_logical_publication(tables=["wal_enc_logical"])
        repl.setup_logical_subscription()

        # Poll until the initial COPY phase reports 'r' (ready). Replaces
        # the flaky time.sleep(5) in the older logical-replication tests.
        deadline = time.time() + 60
        while time.time() < deadline:
            states = subscriber.fetchall(
                "SELECT srsubstate FROM pg_subscription_rel"
            )
            # 'r' = ready / streaming, 's' = synced (also acceptable).
            if states and all(s in ("r", "s") for s in states):
                break
            time.sleep(0.5)
        else:
            raise AssertionError(
                "Logical replication initial sync did not complete in 60s.\n"
                f"pg_subscription_rel states: {states!r}\n"
                "Subscriber log tail:\n" + subscriber.read_log(last_n=40)
            )

        repl.assert_row_counts_match("wal_enc_logical")

        # Apply post-sync DML on the publisher. This exercises the
        # *streaming* logical-replication path (WAL decoded out of encrypted
        # segments), not just the initial COPY.
        publisher.execute(
            "INSERT INTO wal_enc_logical "
            f"SELECT i, '{marker}-post' || i::text "
            "FROM generate_series(501, 1000) i"
        )
        publisher.execute(
            "UPDATE wal_enc_logical SET val = val || '-upd' WHERE id <= 10"
        )
        publisher.execute("DELETE FROM wal_enc_logical WHERE id BETWEEN 11 AND 20")

        # Poll for replication catch-up via LSN comparison rather than sleep.
        target_lsn = publisher.fetchone("SELECT pg_current_wal_lsn()")
        deadline = time.time() + 60
        while time.time() < deadline:
            applied = subscriber.fetchone(
                "SELECT MAX(latest_end_lsn) FROM pg_stat_subscription"
            )
            if applied and applied >= target_lsn:
                break
            time.sleep(0.5)
        else:
            raise AssertionError(
                f"Subscriber did not replay up to publisher LSN {target_lsn} "
                "within 60s.\nSubscriber log tail:\n"
                + subscriber.read_log(last_n=40)
            )

        repl.assert_row_counts_match("wal_enc_logical")
        expected = 500 + 500 - 10   # initial + post-sync - deletes
        sub_count = int(subscriber.fetchone(
            "SELECT COUNT(*) FROM wal_enc_logical"
        ))
        assert sub_count == expected, (
            f"Subscriber row count {sub_count} != expected {expected}; "
            "post-sync DML not fully replicated under WAL encryption."
        )

        # Sanity: subscriber's own WAL is encrypted on disk too — no plain
        # marker bytes anywhere in pg_wal/.
        subscriber.execute("CHECKPOINT")
        subscriber.execute("SELECT pg_switch_wal()")
        pg_wal_dir = subscriber.data_dir / "pg_wal"
        marker_bytes = marker.encode()
        for seg in pg_wal_dir.iterdir():
            if not seg.is_file() or len(seg.name) != 24 or "." in seg.name:
                continue
            assert marker_bytes not in seg.read_bytes(), (
                f"Plaintext marker leaked into subscriber WAL segment "
                f"{seg.name}; WAL encryption is not engaging on the subscriber."
            )
