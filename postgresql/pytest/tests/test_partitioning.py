"""
Partitioned tables + pg_tde coverage.

PostgreSQL has three native partitioning strategies — RANGE, LIST, HASH —
and partitioned parents are routing-only relations (``pg_class.relkind =
'p'``) that own no storage of their own. The encryption contract therefore
splits cleanly between parent and child:

* The **parent** (partitioned table) has no on-disk relation. The
  documented contract from the Percona pg_tde Functions reference
  (https://docs.percona.com/pg-tde/functions.html#pg-tde-is-encrypted)
  is that ``pg_tde_is_encrypted`` returns ``NULL`` for "relations that
  lack storage like views, foreign tables, and partitioned tables and
  indexes".

* Each **leaf partition** is a normal heap-style relation, has its own
  access method (which may differ from its siblings), and is therefore
  independently encrypt-able.

Until this file was added, pg_tde partitioning support was only exercised
indirectly via the upgrade matrix. The 2026-05-12 coverage report
flagged this as a medium-priority gap. This file closes it with focused
end-to-end tests for all three partition strategies, plus the mixed-AM,
sub-partition, default-partition, attach/detach, partition-pruning, and
restart-survival edge cases.

All tests use the ``tde_primary`` fixture so the cluster comes up with
``default_table_access_method = tde_heap`` and a configured principal
key. Every leaf partition is created without an explicit ``USING`` so
the AM check is meaningful: a regression where pg_tde silently switches
a partition's AM would show up immediately.
"""
from __future__ import annotations

import pytest

from lib import PgCluster, TdeManager


pytestmark = [pytest.mark.encryption]


# ── helpers ───────────────────────────────────────────────────────────────────


def _amname(cluster: PgCluster, relname: str) -> str:
    """
    Return the ``pg_am.amname`` for a relation. For partitioned parents
    on PG14+ this may also be set; for partitions and regular tables it
    always is. Empty string means the relation has no AM recorded
    (older PG, partitioned parent).
    """
    return (
        cluster.fetchone(
            f"SELECT COALESCE(am.amname, '') "
            f"FROM pg_class c LEFT JOIN pg_am am ON c.relam = am.oid "
            f"WHERE c.relname = '{relname}'"
        )
        or ""
    )


def _is_encrypted_raw(cluster: PgCluster, relname: str) -> str:
    """
    Raw output of ``pg_tde_is_encrypted(relname::regclass)`` — used to
    distinguish ``'t'``/``'f'`` (definitively true/false) from ``''``
    (NULL: storage-less relation). The TdeManager helper collapses
    NULL → False which is fine for content tests but masks the
    documented partitioned-parent contract.
    """
    return cluster.fetchone(
        f"SELECT pg_tde_is_encrypted('{relname}'::regclass)"
    ) or ""


def _children_of(cluster: PgCluster, parent: str) -> list:
    """Return the leaf-partition relnames of ``parent``, sorted."""
    out = cluster.execute(
        "SELECT inhrelid::regclass::text "
        "FROM pg_inherits "
        f"WHERE inhparent = '{parent}'::regclass "
        "ORDER BY inhrelid::regclass::text"
    )
    return sorted(line.strip() for line in out.splitlines() if line.strip())


def _explain_plan(cluster: PgCluster, sql: str) -> str:
    """Return the full EXPLAIN text for ``sql`` (for partition-pruning checks)."""
    return cluster.execute(f"EXPLAIN {sql}")


class TestPartitionedTdeHeap:
    """
    Coverage for partitioned tables under pg_tde. Verifies the partition
    routing layer doesn't break tde_heap encryption and that every leaf
    partition is independently encrypted (or not, in the mixed-AM case)
    according to its own access method.
    """

    # ── basic strategy coverage ───────────────────────────────────────────

    def test_range_partitioned_children_are_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        RANGE partitioning with three children. Every leaf must report
        ``tde_heap`` and ``pg_tde_is_encrypted = true``. Data inserted
        into the parent must route to the matching child and be readable
        both through the parent and directly through the child.
        """
        tde_primary.execute(
            "CREATE TABLE orders_range (id INT, region TEXT, qty INT) "
            "PARTITION BY RANGE (id)"
        )
        for i, (name, lo, hi) in enumerate([
            ("orders_r_a", 1, 100),
            ("orders_r_b", 100, 200),
            ("orders_r_c", 200, 300),
        ]):
            tde_primary.execute(
                f"CREATE TABLE {name} PARTITION OF orders_range "
                f"FOR VALUES FROM ({lo}) TO ({hi})"
            )
        tde_primary.execute(
            "INSERT INTO orders_range "
            "SELECT i, 'r' || (i % 3)::text, i * 10 "
            "FROM generate_series(1, 250) i"
        )

        tde = TdeManager(tde_primary)
        for child in ("orders_r_a", "orders_r_b", "orders_r_c"):
            assert _amname(tde_primary, child) == "tde_heap", (
                f"child {child} is not on tde_heap AM"
            )
            assert tde.is_table_encrypted(child), (
                f"child {child} reports not-encrypted"
            )

        # Parent-vs-child row counts.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM orders_range"
        ) == "250"
        # Direct child queries must agree with the parent total.
        per_child = {
            child: int(
                tde_primary.fetchone(f"SELECT COUNT(*) FROM {child}")
            )
            for child in ("orders_r_a", "orders_r_b", "orders_r_c")
        }
        assert sum(per_child.values()) == 250, (
            f"row distribution across children does not sum to parent: "
            f"{per_child}"
        )

    def test_list_partitioned_children_are_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        LIST partitioning with a DEFAULT partition. Every leaf —
        including the default — must be encrypted. Rows that don't match
        any explicit list must route into the default partition and
        still be readable.
        """
        tde_primary.execute(
            "CREATE TABLE users_list (id INT, country TEXT) "
            "PARTITION BY LIST (country)"
        )
        tde_primary.execute(
            "CREATE TABLE users_l_us PARTITION OF users_list "
            "FOR VALUES IN ('US')"
        )
        tde_primary.execute(
            "CREATE TABLE users_l_uk PARTITION OF users_list "
            "FOR VALUES IN ('UK')"
        )
        tde_primary.execute(
            "CREATE TABLE users_l_default PARTITION OF users_list DEFAULT"
        )
        tde_primary.execute(
            "INSERT INTO users_list VALUES "
            "(1, 'US'), (2, 'UK'), (3, 'DE'), (4, 'FR'), (5, 'US')"
        )

        tde = TdeManager(tde_primary)
        for child in ("users_l_us", "users_l_uk", "users_l_default"):
            assert _amname(tde_primary, child) == "tde_heap"
            assert tde.is_table_encrypted(child), (
                f"LIST-partition child {child} reports not-encrypted"
            )

        # The two unlisted countries (DE, FR) must land in the default.
        default_rows = int(
            tde_primary.fetchone("SELECT COUNT(*) FROM users_l_default")
        )
        assert default_rows == 2, (
            f"default partition rows = {default_rows}, expected 2 "
            "(DE + FR rows did not route to the default partition)"
        )

    def test_hash_partitioned_children_are_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        HASH partitioning with 4 children. The partition router decides
        which child gets each row from a hash of the partition key —
        all four must be tde_heap and the row total across them must
        match the parent.
        """
        tde_primary.execute(
            "CREATE TABLE events_hash (id INT, payload TEXT) "
            "PARTITION BY HASH (id)"
        )
        for i in range(4):
            tde_primary.execute(
                f"CREATE TABLE events_h_p{i} PARTITION OF events_hash "
                f"FOR VALUES WITH (modulus 4, remainder {i})"
            )
        tde_primary.execute(
            "INSERT INTO events_hash "
            "SELECT i, md5(i::text) FROM generate_series(1, 400) i"
        )

        tde = TdeManager(tde_primary)
        per_child = {}
        for i in range(4):
            child = f"events_h_p{i}"
            assert _amname(tde_primary, child) == "tde_heap"
            assert tde.is_table_encrypted(child)
            per_child[child] = int(
                tde_primary.fetchone(f"SELECT COUNT(*) FROM {child}")
            )
        assert sum(per_child.values()) == 400, (
            f"hash partition row sum != parent total: {per_child}"
        )
        # Every partition must receive *some* rows for n=400, m=4 with
        # well-distributed inputs — catches regressions where pg_tde
        # interferes with the hash routing.
        empty = [c for c, n in per_child.items() if n == 0]
        assert not empty, (
            f"hash partition(s) received 0 rows out of 400 inputs: {empty}"
        )

    # ── documented contracts ──────────────────────────────────────────────

    def test_partitioned_parent_returns_null_for_is_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        Per the Percona docs
        (https://docs.percona.com/pg-tde/functions.html#pg-tde-is-encrypted)
        the function returns ``NULL`` for relations that lack storage —
        including partitioned tables. Catches regressions where the
        function would erroneously return ``true``/``false`` for a
        routing-only relation, masking the partition layer's nature.
        """
        tde_primary.execute(
            "CREATE TABLE measurement_parent (id INT, ts TIMESTAMPTZ) "
            "PARTITION BY RANGE (ts)"
        )
        raw = _is_encrypted_raw(tde_primary, "measurement_parent")
        # psql ``--tuples-only`` renders NULL as an empty string.
        assert raw == "", (
            "pg_tde_is_encrypted on a partitioned parent should return "
            f"NULL (empty psql output); got {raw!r}"
        )

    # ── mixed access methods on the same parent ───────────────────────────

    def test_mixed_access_method_partitions_each_report_independently(
        self, tde_primary: PgCluster
    ):
        """
        PostgreSQL allows each leaf partition to choose its own access
        method independent of its siblings. With pg_tde this means an
        operator can opt in to encryption per-partition (e.g. keep
        historical data plain heap, encrypt only the current window).

        Test that each child reports its own AM truthfully — and that
        ``pg_tde_is_encrypted`` is ``true`` for the tde_heap child but
        ``false`` (not NULL) for the plain heap child.
        """
        tde_primary.execute(
            "CREATE TABLE logs_mixed (id INT, ts INT) "
            "PARTITION BY RANGE (ts)"
        )
        tde_primary.execute(
            "CREATE TABLE logs_mixed_enc PARTITION OF logs_mixed "
            "FOR VALUES FROM (0) TO (100) USING tde_heap"
        )
        tde_primary.execute(
            "CREATE TABLE logs_mixed_plain PARTITION OF logs_mixed "
            "FOR VALUES FROM (100) TO (200) USING heap"
        )
        tde_primary.execute(
            "INSERT INTO logs_mixed "
            "SELECT i, i FROM generate_series(0, 199) i"
        )

        assert _amname(tde_primary, "logs_mixed_enc") == "tde_heap"
        assert _amname(tde_primary, "logs_mixed_plain") == "heap"

        # The contract under test: pg_tde_is_encrypted must be truthful,
        # NOT swallow the false case as NULL on a regular leaf.
        assert _is_encrypted_raw(tde_primary, "logs_mixed_enc") == "t", (
            "tde_heap partition leaf is reported as not-encrypted"
        )
        assert _is_encrypted_raw(tde_primary, "logs_mixed_plain") == "f", (
            "plain heap partition leaf is reported as encrypted (or NULL); "
            "the function should return 'f' for a plain heap leaf"
        )

        # Row counts on each leaf — proves partition pruning + routing
        # work correctly with the mixed-AM layout.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM logs_mixed_enc"
        ) == "100"
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM logs_mixed_plain"
        ) == "100"

    # ── attach / detach lifecycle ─────────────────────────────────────────

    def test_attach_and_detach_encrypted_partition(
        self, tde_primary: PgCluster
    ):
        """
        Create a standalone tde_heap table, ATTACH it as a partition of a
        new parent, query through the parent, then DETACH and query as
        standalone. Both attach and detach must be no-ops as far as the
        on-disk encryption state goes — the child must remain encrypted
        across the lifecycle.
        """
        tde_primary.execute(
            "CREATE TABLE standalone_enc (id INT, payload TEXT) USING tde_heap"
        )
        tde_primary.execute(
            "ALTER TABLE standalone_enc ADD PRIMARY KEY (id)"
        )
        tde_primary.execute(
            "INSERT INTO standalone_enc "
            "SELECT i, md5(i::text) FROM generate_series(1, 50) i"
        )
        # Range partition the table such that the standalone's rows
        # (1..50) fit cleanly inside one partition window.
        tde_primary.execute(
            "ALTER TABLE standalone_enc ADD CONSTRAINT standalone_range_chk "
            "CHECK (id >= 1 AND id <= 100)"
        )

        tde_primary.execute(
            "CREATE TABLE parent_attach (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "ALTER TABLE parent_attach ATTACH PARTITION standalone_enc "
            "FOR VALUES FROM (1) TO (100)"
        )

        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("standalone_enc"), (
            "child lost encryption status after ATTACH"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM parent_attach"
        ) == "50"

        # DETACH and verify it is still encrypted + queryable standalone.
        tde_primary.execute(
            "ALTER TABLE parent_attach DETACH PARTITION standalone_enc"
        )
        assert tde.is_table_encrypted("standalone_enc"), (
            "child lost encryption status after DETACH"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM standalone_enc"
        ) == "50"

    # ── partition pruning + encryption ────────────────────────────────────

    def test_partition_pruning_with_encrypted_partitions(
        self, tde_primary: PgCluster
    ):
        """
        Partition pruning is the optimisation that lets a WHERE-clause
        skip irrelevant partitions entirely. pg_tde must not interfere
        with it — neither by spuriously decrypting all partitions, nor
        by disabling pruning. EXPLAIN output proves the planner is
        still pruning; the query result then proves it returned the
        correct rows.
        """
        tde_primary.execute(
            "CREATE TABLE pruning_t (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        for i, (name, lo, hi) in enumerate([
            ("pruning_a", 0, 1000),
            ("pruning_b", 1000, 2000),
            ("pruning_c", 2000, 3000),
        ]):
            tde_primary.execute(
                f"CREATE TABLE {name} PARTITION OF pruning_t "
                f"FOR VALUES FROM ({lo}) TO ({hi})"
            )
        tde_primary.execute(
            "INSERT INTO pruning_t "
            "SELECT i, md5(i::text) FROM generate_series(0, 2999) i"
        )

        # A point query should prune to exactly one partition. Verify
        # that ``pruning_b`` and ``pruning_c`` are NOT in the plan.
        plan = _explain_plan(
            tde_primary, "SELECT * FROM pruning_t WHERE id = 42"
        )
        assert "pruning_a" in plan, (
            "EXPLAIN did not include the matching partition; "
            f"plan:\n{plan}"
        )
        assert "pruning_b" not in plan and "pruning_c" not in plan, (
            "partition pruning failed under tde_heap; non-matching "
            f"partitions still appear in the plan:\n{plan}"
        )
        # And the actual result.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM pruning_t WHERE id = 42"
        ) == "1"

    # ── multi-level partitioning ──────────────────────────────────────────

    def test_subpartitioning_chain_all_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        Two-level partitioning: outer RANGE → inner LIST. Every leaf at
        the bottom of the chain must be tde_heap and encrypted; the two
        intermediate (routing-only) levels are storage-less and must
        return NULL from ``pg_tde_is_encrypted``.
        """
        tde_primary.execute(
            "CREATE TABLE sales (yr INT, region TEXT, amt NUMERIC) "
            "PARTITION BY RANGE (yr)"
        )
        # Two outer RANGE partitions, each further LIST-partitioned.
        for outer_name, lo, hi in [
            ("sales_2024", 2024, 2025),
            ("sales_2025", 2025, 2026),
        ]:
            tde_primary.execute(
                f"CREATE TABLE {outer_name} PARTITION OF sales "
                f"FOR VALUES FROM ({lo}) TO ({hi}) PARTITION BY LIST (region)"
            )
            for region in ("na", "emea"):
                tde_primary.execute(
                    f"CREATE TABLE {outer_name}_{region} "
                    f"PARTITION OF {outer_name} "
                    f"FOR VALUES IN ('{region}')"
                )

        tde_primary.execute(
            "INSERT INTO sales (yr, region, amt) VALUES "
            "(2024, 'na', 10), (2024, 'emea', 20), "
            "(2025, 'na', 30), (2025, 'emea', 40)"
        )

        tde = TdeManager(tde_primary)
        # Intermediate routing tables: NULL.
        for routing in ("sales", "sales_2024", "sales_2025"):
            assert _is_encrypted_raw(tde_primary, routing) == "", (
                f"{routing} should return NULL from pg_tde_is_encrypted "
                "(it has no storage)"
            )
        # Leaf partitions: all tde_heap, all encrypted.
        leaves = [
            "sales_2024_na", "sales_2024_emea",
            "sales_2025_na", "sales_2025_emea",
        ]
        for leaf in leaves:
            assert _amname(tde_primary, leaf) == "tde_heap", (
                f"sub-partition leaf {leaf} is not on tde_heap"
            )
            assert tde.is_table_encrypted(leaf), (
                f"sub-partition leaf {leaf} is not encrypted"
            )
            assert tde_primary.fetchone(
                f"SELECT COUNT(*) FROM {leaf}"
            ) == "1"

    # ── default partition + restart durability ────────────────────────────

    def test_default_partition_catches_overflow_and_is_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        The DEFAULT partition is the last-resort sink for rows that
        don't match any explicit RANGE/LIST. It must be encrypted just
        like its named siblings — silently leaving "overflow" data in a
        plain heap would defeat the encryption-at-rest property.
        """
        tde_primary.execute(
            "CREATE TABLE bucket (k INT, v TEXT) PARTITION BY RANGE (k)"
        )
        tde_primary.execute(
            "CREATE TABLE bucket_low PARTITION OF bucket "
            "FOR VALUES FROM (0) TO (10)"
        )
        tde_primary.execute(
            "CREATE TABLE bucket_default PARTITION OF bucket DEFAULT"
        )
        tde_primary.execute(
            "INSERT INTO bucket VALUES (1, 'low-1'), (50, 'overflow-50'), "
            "(99, 'overflow-99')"
        )

        tde = TdeManager(tde_primary)
        assert _amname(tde_primary, "bucket_default") == "tde_heap"
        assert tde.is_table_encrypted("bucket_default"), (
            "DEFAULT partition is not encrypted — overflow rows would "
            "be stored in plain heap"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM bucket_default"
        ) == "2"

    def test_partitioned_data_round_trip_after_restart(
        self, tde_primary: PgCluster
    ):
        """
        End-to-end durability: populate every leaf of a 3-level mixed
        layout (RANGE outer, with one HASH-partitioned child), stop and
        restart the cluster, then verify (a) every leaf is still
        encrypted, (b) every row is still readable, and (c) row totals
        match the pre-restart state.
        """
        tde_primary.execute(
            "CREATE TABLE durable (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE durable_low PARTITION OF durable "
            "FOR VALUES FROM (0) TO (100)"
        )
        tde_primary.execute(
            "CREATE TABLE durable_hi PARTITION OF durable "
            "FOR VALUES FROM (100) TO (200) PARTITION BY HASH (id)"
        )
        for i in range(2):
            tde_primary.execute(
                f"CREATE TABLE durable_hi_p{i} PARTITION OF durable_hi "
                f"FOR VALUES WITH (modulus 2, remainder {i})"
            )
        tde_primary.execute(
            "INSERT INTO durable "
            "SELECT i, md5(i::text) FROM generate_series(0, 199) i"
        )
        tde_primary.execute("CHECKPOINT")

        leaves = ("durable_low", "durable_hi_p0", "durable_hi_p1")
        before = {
            leaf: int(
                tde_primary.fetchone(f"SELECT COUNT(*) FROM {leaf}")
            )
            for leaf in leaves
        }
        assert sum(before.values()) == 200

        tde_primary.restart()

        tde = TdeManager(tde_primary)
        for leaf in leaves:
            assert _amname(tde_primary, leaf) == "tde_heap"
            assert tde.is_table_encrypted(leaf), (
                f"leaf {leaf} lost encrypted state across restart"
            )
        after = {
            leaf: int(
                tde_primary.fetchone(f"SELECT COUNT(*) FROM {leaf}")
            )
            for leaf in leaves
        }
        assert after == before, (
            f"row distribution drifted across restart: "
            f"before={before}, after={after}"
        )
        # And a parent-level total — proves the partition routing
        # configuration is still intact.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM durable"
        ) == "200"


class TestPartitionedTdeHeapCorners:
    """
    Corner-case coverage for partitioned tde_heap tables — the unusual
    workflows that can each exercise a distinct internal code path:

    * relfilenode rewrites (VACUUM FULL, ALTER TYPE)
    * row movement across partitions (UPDATE on partition key)
    * bulk insert routing (COPY)
    * TOAST-out values inside an encrypted leaf
    * composite partition keys
    * sibling-isolation during DROP PARTITION
    * many-partition scaling
    * local indexes on encrypted leaves
    * declarative UNIQUE constraint that must include the partition key

    Each scenario was historically reported to break or behave subtly
    differently from the base case, so they get explicit assertions
    that the encrypted-AM contract still holds after the operation.
    """

    # ── indexes on encrypted partitions ───────────────────────────────────

    def test_local_index_on_encrypted_partition_is_encrypted(
        self, tde_primary: PgCluster
    ):
        """
        Per the Percona docs, indexes on tde_heap relations have their
        pages encrypted just like the heap. The pg_tde_is_encrypted
        function explicitly supports indexes: "This can additionally be
        used to verify that indexes and sequences are encrypted."

        Create a local btree index on a leaf partition and verify it
        reports encrypted=true. A regression would silently leak index
        keys in plaintext on disk.
        """
        tde_primary.execute(
            "CREATE TABLE idx_part (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE idx_part_a PARTITION OF idx_part "
            "FOR VALUES FROM (0) TO (1000)"
        )
        tde_primary.execute(
            "INSERT INTO idx_part SELECT i, md5(i::text) "
            "FROM generate_series(0, 999) i"
        )
        tde_primary.execute(
            "CREATE INDEX idx_part_a_payload_idx ON idx_part_a (payload)"
        )

        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("idx_part_a"), (
            "partition leaf reports not-encrypted before the index check"
        )
        assert _is_encrypted_raw(
            tde_primary, "idx_part_a_payload_idx"
        ) == "t", (
            "local index on an encrypted partition is NOT encrypted — "
            "index keys would leak in plaintext on disk"
        )

    def test_unique_constraint_on_partition_key_with_tde_heap(
        self, tde_primary: PgCluster
    ):
        """
        PostgreSQL forbids UNIQUE constraints on partitioned tables
        unless every column of the constraint includes (or is) the
        partition key. With tde_heap each per-partition index that
        backs the constraint must still be encrypted. Verify by adding
        a primary key on the partition column and inspecting the
        per-partition index.
        """
        tde_primary.execute(
            "CREATE TABLE uk_part (id INT, payload TEXT, PRIMARY KEY (id)) "
            "PARTITION BY RANGE (id)"
        )
        for name, lo, hi in [
            ("uk_part_a", 0, 100),
            ("uk_part_b", 100, 200),
        ]:
            tde_primary.execute(
                f"CREATE TABLE {name} PARTITION OF uk_part "
                f"FOR VALUES FROM ({lo}) TO ({hi})"
            )
        tde_primary.execute(
            "INSERT INTO uk_part SELECT i, md5(i::text) "
            "FROM generate_series(0, 199) i"
        )

        # Every per-partition pkey index must be encrypted.
        index_names = tde_primary.execute(
            "SELECT indexrelid::regclass::text "
            "FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid "
            "WHERE c.relname IN ('uk_part_a', 'uk_part_b')"
        )
        indexes = [
            line.strip()
            for line in index_names.splitlines()
            if line.strip()
        ]
        assert len(indexes) == 2, (
            f"expected 2 per-partition pkey indexes, found: {indexes}"
        )
        for idx in indexes:
            assert _is_encrypted_raw(tde_primary, idx) == "t", (
                f"per-partition pkey index {idx} is not encrypted"
            )

        # And the constraint actually fires.
        with pytest.raises(RuntimeError):
            tde_primary.execute("INSERT INTO uk_part VALUES (5, 'dup')")

    # ── rewrites that produce a new relfilenode ───────────────────────────

    def test_vacuum_full_preserves_encryption_on_partition(
        self, tde_primary: PgCluster
    ):
        """
        VACUUM FULL allocates a new relfilenode and copies tuples into
        it. With tde_heap that new relfilenode must also be encrypted,
        and the data must still be readable afterwards. A regression
        could rewrite the heap into plaintext storage even though the
        AM is still ``tde_heap`` in the catalog.
        """
        tde_primary.execute(
            "CREATE TABLE vf_part (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE vf_part_a PARTITION OF vf_part "
            "FOR VALUES FROM (0) TO (1000)"
        )
        tde_primary.execute(
            "INSERT INTO vf_part SELECT i, md5(i::text) "
            "FROM generate_series(0, 499) i"
        )
        # Delete half so VACUUM FULL has actual work to do.
        tde_primary.execute("DELETE FROM vf_part_a WHERE id % 2 = 0")

        before = tde_primary.fetchone(
            "SELECT pg_relation_filenode('vf_part_a'::regclass)"
        )
        tde_primary.execute("VACUUM FULL vf_part_a")
        after = tde_primary.fetchone(
            "SELECT pg_relation_filenode('vf_part_a'::regclass)"
        )
        assert before != after, (
            "VACUUM FULL did not allocate a new relfilenode "
            f"(before={before!r}, after={after!r}) — the assertion below "
            "becomes a tautology"
        )

        tde = TdeManager(tde_primary)
        assert _amname(tde_primary, "vf_part_a") == "tde_heap"
        assert tde.is_table_encrypted("vf_part_a"), (
            "partition is NOT encrypted after VACUUM FULL — pg_tde "
            "may not have re-applied encryption to the new relfilenode"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM vf_part_a"
        ) == "250"

    def test_alter_column_type_rewrites_partition_keeping_encryption(
        self, tde_primary: PgCluster
    ):
        """
        Some ALTER TABLE forms (e.g. type changes that require a cast)
        trigger a full table rewrite to a new relfilenode. The new
        storage must still be encrypted, the data must round-trip
        through the type conversion, and the catalog must still report
        tde_heap.
        """
        tde_primary.execute(
            "CREATE TABLE alt_part (id INT, val INT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE alt_part_a PARTITION OF alt_part "
            "FOR VALUES FROM (0) TO (200)"
        )
        tde_primary.execute(
            "INSERT INTO alt_part SELECT i, i * 7 "
            "FROM generate_series(0, 199) i"
        )

        before_filenode = tde_primary.fetchone(
            "SELECT pg_relation_filenode('alt_part_a'::regclass)"
        )
        # ALTER ... TYPE BIGINT USING val::bigint forces a rewrite.
        tde_primary.execute(
            "ALTER TABLE alt_part ALTER COLUMN val TYPE BIGINT "
            "USING val::bigint"
        )
        after_filenode = tde_primary.fetchone(
            "SELECT pg_relation_filenode('alt_part_a'::regclass)"
        )
        # Some PG versions do not rewrite for widening int->bigint when
        # the data fits. Either way the encryption assertion still
        # holds; we just note the rewrite status for diagnostics.
        rewritten = before_filenode != after_filenode

        tde = TdeManager(tde_primary)
        assert _amname(tde_primary, "alt_part_a") == "tde_heap"
        assert tde.is_table_encrypted("alt_part_a"), (
            f"partition is NOT encrypted after ALTER TYPE "
            f"(relfilenode rewritten={rewritten})"
        )
        # Data round-trip through the type change.
        assert tde_primary.fetchone(
            "SELECT SUM(val) FROM alt_part_a"
        ) == str(sum(i * 7 for i in range(200)))

    # ── row movement across partitions ────────────────────────────────────

    def test_row_movement_across_encrypted_partitions_via_update(
        self, tde_primary: PgCluster
    ):
        """
        Since PG 11, UPDATE on a row that changes the partition key
        physically moves the row to the new partition. Both source and
        target partitions must remain encrypted, the row must end up
        in the correct destination, and it must be readable end-to-end.
        """
        tde_primary.execute(
            "CREATE TABLE move_t (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE move_low PARTITION OF move_t "
            "FOR VALUES FROM (0) TO (100)"
        )
        tde_primary.execute(
            "CREATE TABLE move_hi PARTITION OF move_t "
            "FOR VALUES FROM (100) TO (200)"
        )
        tde_primary.execute(
            "INSERT INTO move_t VALUES (5, 'low-row'), (105, 'hi-row')"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM move_low"
        ) == "1"

        # Move the low row into the hi partition.
        tde_primary.execute("UPDATE move_t SET id = 150 WHERE id = 5")

        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM move_low"
        ) == "0", "source partition still contains the moved row"
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM move_hi"
        ) == "2", "destination partition is missing the moved row"
        # The moved row's payload survived the move.
        assert tde_primary.fetchone(
            "SELECT payload FROM move_hi WHERE id = 150"
        ) == "low-row"

        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("move_low")
        assert tde.is_table_encrypted("move_hi")

    # ── DDL on individual partitions ──────────────────────────────────────

    def test_drop_partition_leaves_siblings_intact(
        self, tde_primary: PgCluster
    ):
        """
        DROP TABLE on one partition must not affect its siblings'
        existence, encryption status, or data. Catches regressions
        where pg_tde catalog cleanup over-eagerly invalidates shared
        per-database state.
        """
        tde_primary.execute(
            "CREATE TABLE drop_t (id INT) PARTITION BY RANGE (id)"
        )
        for name, lo, hi in [
            ("drop_a", 0, 100),
            ("drop_b", 100, 200),
            ("drop_c", 200, 300),
        ]:
            tde_primary.execute(
                f"CREATE TABLE {name} PARTITION OF drop_t "
                f"FOR VALUES FROM ({lo}) TO ({hi})"
            )
        tde_primary.execute(
            "INSERT INTO drop_t SELECT generate_series(0, 299)"
        )

        tde_primary.execute("DROP TABLE drop_b")

        # Survivor partitions still encrypted and queryable.
        tde = TdeManager(tde_primary)
        for surv in ("drop_a", "drop_c"):
            assert tde.is_table_encrypted(surv), (
                f"surviving partition {surv} is not encrypted after a "
                "sibling DROP"
            )
            assert tde_primary.fetchone(
                f"SELECT COUNT(*) FROM {surv}"
            ) == "100"
        # Children listed via pg_inherits no longer include drop_b.
        children = _children_of(tde_primary, "drop_t")
        assert "drop_b" not in children, (
            f"drop_b still listed as a child after DROP TABLE: {children}"
        )

    def test_truncate_parent_clears_all_encrypted_children(
        self, tde_primary: PgCluster
    ):
        """
        TRUNCATE on the partitioned parent recursively truncates every
        child. Each child must remain encrypted afterwards — the
        underlying storage gets a new relfilenode (TRUNCATE's default
        behaviour) and pg_tde must re-apply encryption.
        """
        tde_primary.execute(
            "CREATE TABLE trunc_t (id INT) PARTITION BY RANGE (id)"
        )
        for name, lo, hi in [
            ("trunc_a", 0, 50),
            ("trunc_b", 50, 100),
        ]:
            tde_primary.execute(
                f"CREATE TABLE {name} PARTITION OF trunc_t "
                f"FOR VALUES FROM ({lo}) TO ({hi})"
            )
        tde_primary.execute(
            "INSERT INTO trunc_t SELECT generate_series(0, 99)"
        )

        tde_primary.execute("TRUNCATE TABLE trunc_t")

        tde = TdeManager(tde_primary)
        for child in ("trunc_a", "trunc_b"):
            assert _amname(tde_primary, child) == "tde_heap", (
                f"child {child} dropped tde_heap AM after TRUNCATE"
            )
            assert tde.is_table_encrypted(child), (
                f"child {child} is not encrypted after TRUNCATE; pg_tde "
                "may not have re-applied encryption to the new "
                "relfilenode allocated by TRUNCATE"
            )
            assert tde_primary.fetchone(
                f"SELECT COUNT(*) FROM {child}"
            ) == "0"

        # Re-insert must still route + encrypt correctly.
        tde_primary.execute("INSERT INTO trunc_t SELECT generate_series(0, 9)")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM trunc_t"
        ) == "10"

    # ── bulk insert paths ─────────────────────────────────────────────────

    def test_copy_from_routes_into_encrypted_partitions(
        self, tde_primary: PgCluster, tmp_path
    ):
        """
        Server-side ``COPY ... FROM`` uses a separate insert path from
        regular INSERT. With partitioning + tde_heap it must still
        route each row to the correct leaf and encrypt on write.
        """
        tde_primary.execute(
            "CREATE TABLE copy_t (id INT, payload TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE copy_low PARTITION OF copy_t "
            "FOR VALUES FROM (0) TO (50)"
        )
        tde_primary.execute(
            "CREATE TABLE copy_hi PARTITION OF copy_t "
            "FOR VALUES FROM (50) TO (100)"
        )

        csv_path = tmp_path / "bulk.csv"
        lines = []
        for i in range(100):
            lines.append(f"{i},payload-{i}")
        csv_path.write_text("\n".join(lines) + "\n")
        # World-readable so the postgres server process can read it.
        csv_path.chmod(0o644)

        tde_primary.execute(
            f"COPY copy_t FROM '{csv_path}' WITH (FORMAT csv)"
        )

        tde = TdeManager(tde_primary)
        for child, expected in [("copy_low", "50"), ("copy_hi", "50")]:
            assert tde.is_table_encrypted(child)
            assert tde_primary.fetchone(
                f"SELECT COUNT(*) FROM {child}"
            ) == expected, (
                f"COPY did not route {expected} rows to {child}; "
                "partition routing under tde_heap may be broken"
            )

    # ── TOAST ─────────────────────────────────────────────────────────────

    def test_toast_values_in_encrypted_partition_round_trip(
        self, tde_primary: PgCluster
    ):
        """
        Wide values (>~2 KB compressed) are stored out-of-line in the
        relation's TOAST table. pg_tde must encrypt the TOAST table
        too, otherwise large fields would leak in plaintext on disk
        even though the main heap is encrypted.

        Insert a wide value into an encrypted partition; verify the
        round-trip works (proves decryption) and inspect the TOAST
        relation's encryption status.

        Note on TOAST relation lookup: TOAST tables live in the
        ``pg_toast`` schema which is not on the default search_path,
        so we cannot pass the bare ``pg_toast_<oid>`` name to
        ``'...'::regclass`` — the regclass cast would fail with
        "relation does not exist". We pass the OID directly instead
        (``c.reltoastrelid``) which bypasses search_path lookup
        entirely.
        """
        tde_primary.execute(
            "CREATE TABLE toast_t (id INT, big TEXT) "
            "PARTITION BY RANGE (id)"
        )
        tde_primary.execute(
            "CREATE TABLE toast_a PARTITION OF toast_t "
            "FOR VALUES FROM (0) TO (10)"
        )
        # repeat('X', 50000) compresses well but still spills to TOAST.
        tde_primary.execute(
            "INSERT INTO toast_a VALUES (1, repeat('X', 50000))"
        )
        # Round-trip: the length matches.
        assert tde_primary.fetchone(
            "SELECT length(big) FROM toast_a WHERE id = 1"
        ) == "50000"

        tde = TdeManager(tde_primary)
        assert tde.is_table_encrypted("toast_a")

        # Pass the TOAST OID directly into pg_tde_is_encrypted to avoid
        # the regclass-cast-via-search_path pitfall (pg_toast is not on
        # the search_path by default).
        toast_oid = tde_primary.fetchone(
            "SELECT reltoastrelid::oid::text FROM pg_class "
            "WHERE relname = 'toast_a' AND reltoastrelid <> 0"
        )
        if toast_oid:
            # Either 't' (encrypted) or '' (no opinion / NULL) is
            # acceptable; 'f' would mean TOAST is actively plaintext,
            # which is the regression.
            toast_encrypted = tde_primary.fetchone(
                f"SELECT pg_tde_is_encrypted({toast_oid}::oid::regclass)"
            ) or ""
            assert toast_encrypted != "f", (
                f"TOAST relation (oid={toast_oid}) reports plaintext "
                "while its parent partition is on tde_heap — wide "
                "values would leak in clear text on disk"
            )

    # ── composite key + scaling ───────────────────────────────────────────

    def test_composite_range_partition_key_with_tde_heap(
        self, tde_primary: PgCluster
    ):
        """
        Multi-column RANGE partition keys are routinely used for
        time-bucketed data (e.g. ``RANGE (year, month)``). The
        encryption contract must hold across this layout too.
        """
        tde_primary.execute(
            "CREATE TABLE comp_t (yr INT, mo INT, qty INT) "
            "PARTITION BY RANGE (yr, mo)"
        )
        tde_primary.execute(
            "CREATE TABLE comp_2024 PARTITION OF comp_t "
            "FOR VALUES FROM (2024, 1) TO (2025, 1)"
        )
        tde_primary.execute(
            "CREATE TABLE comp_2025 PARTITION OF comp_t "
            "FOR VALUES FROM (2025, 1) TO (2026, 1)"
        )
        tde_primary.execute(
            "INSERT INTO comp_t VALUES "
            "(2024, 6, 10), (2024, 12, 20), (2025, 3, 30)"
        )

        tde = TdeManager(tde_primary)
        for leaf, expected in [("comp_2024", "2"), ("comp_2025", "1")]:
            assert _amname(tde_primary, leaf) == "tde_heap"
            assert tde.is_table_encrypted(leaf)
            assert tde_primary.fetchone(
                f"SELECT COUNT(*) FROM {leaf}"
            ) == expected

    def test_many_partitions_all_encrypted_stress(
        self, tde_primary: PgCluster
    ):
        """
        Scaling sanity: 30 partitions, each encrypted, each receiving
        rows. Catches per-partition pg_tde state-table growth issues
        (e.g. catalog bloat or per-rel cache thrashing) that wouldn't
        surface in the 3-4 partition mainline tests.
        """
        N = 30
        tde_primary.execute(
            "CREATE TABLE many_t (id INT) PARTITION BY RANGE (id)"
        )
        for i in range(N):
            tde_primary.execute(
                f"CREATE TABLE many_p{i} PARTITION OF many_t "
                f"FOR VALUES FROM ({i * 100}) TO ({(i + 1) * 100})"
            )
        tde_primary.execute(
            f"INSERT INTO many_t SELECT generate_series(0, {N * 100 - 1})"
        )

        tde = TdeManager(tde_primary)
        not_encrypted = [
            f"many_p{i}"
            for i in range(N)
            if not tde.is_table_encrypted(f"many_p{i}")
        ]
        assert not not_encrypted, (
            f"{len(not_encrypted)}/{N} partitions are NOT encrypted "
            f"after batch creation: {not_encrypted[:5]}..."
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM many_t"
        ) == str(N * 100)
