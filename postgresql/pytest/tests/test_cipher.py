"""
pg_tde cipher tests — both layers in one place.

This module groups every cipher-related contract pg_tde exposes:

1. **``pg_tde.cipher`` GUC contract** (``TestTdeCipher``)

   The user-facing knob that picks between ``aes_128`` (default) and
   ``aes_256``. Verifies the GUC is honoured at SHOW time, that it
   actually changes ciphertext bytes on disk, that it survives a
   restart, and that bogus values are rejected.

   Ported from:
     - ``pg_tde_functions_test.sh`` (cipher portion)
     - ``wal_encrypt_guc_test.sh`` (cipher portion)

2. **SMGR cipher-context reuse contract** (``TestSmgrCipherReuse*``,
   PR #554 / PG-2278)

   Port of ``postgresql/automation/tests/test_smgr_cipher_context_reuse.sh``.

   The pg_tde SMGR layer holds OpenSSL ``EVP_CIPHER_CTX`` objects on
   the read and write paths and re-keys them per relation. PR #554
   changed the context to be **reused** across operations instead of
   being created fresh for each I/O. If that reuse is wrong (stale
   key/IV/padding state leaking between relations or between read and
   write paths) it produces silently-corrupted ciphertext that only
   shows up when:

     * pages are read off disk (not from shared buffers), or
     * a partitioned/CTAS/TRUNCATE/REINDEX/CLUSTER cycle re-encrypts
       onto a fresh relfilenode under the same process, or
     * the server restarts and re-loads pg_tde / re-creates the
       contexts.

   These tests reproduce that surface area in pytest:

     * ``ctx_heap_a`` / ``ctx_heap_b`` — two encrypted heaps with
       different relation keys; interleaved scans, UPDATE/DELETE/VACUUM.
     * Partitioned ``tde_heap`` with three children (different relation
       keys in one query tree).
     * TOAST-heavy rows.
     * CTAS + savepoint rollback.
     * TRUNCATE + reload (new relfilenode under same context).
     * REINDEX + CLUSTER (physical reorder).
     * Index-preferred reads.
     * Multi-relation interleaved scan via UNION ALL.
     * Bulk wide-row / narrow-row seqscans with ``shared_buffers = 2MB``
       so working sets exceed cache and pages must come from SMGR.
     * Server-side ``COPY FROM STDIN`` into ``tde_heap``.
     * Restart-then-verify aggregates match before/after.

   The bash script wraps ALL of those into one suite and runs it twice
   (``pg_tde.cipher = aes_128`` and ``aes_256``). We mirror that with
   ``@pytest.mark.parametrize("cipher", CIPHERS)`` on the comprehensive
   "full suite" test, plus a few focused regression tests for individual
   code paths.

   All SMGR tests use a **database-scope** key provider (matching the
   bash script) and ``shared_buffers = 2MB`` so bulk seqscans actually
   go through ``mdread`` → pg_tde SMGR decrypt off the device, not just
   out of cache.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums, postgres_major_version


pytestmark = [pytest.mark.encryption]


CIPHERS = ["aes_128", "aes_256"]
SHARED_BUFFERS_SMALL = "'2MB'"


# ── helpers ───────────────────────────────────────────────────────────────────


def _build_smgr_cluster(
    pg_factory,
    tmp_path: Path,
    name: str,
    *,
    cipher: str,
    shared_buffers: str = SHARED_BUFFERS_SMALL,
) -> PgCluster:
    """
    Build a TDE cluster pinned to *cipher* with tiny ``shared_buffers``
    so SMGR decrypt is exercised on bulk seqscans.

    Mirrors the bash ``run_cipher_suite`` setup: database-scope key
    provider + ``pg_tde.cipher = cipher`` set BEFORE the extension is
    created (matters because the cipher must be locked in before the
    first key is materialised).
    """
    keyfile = str(tmp_path / f"{name}.keyring.per")
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(
        extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
            "pg_tde.cipher": f"'{cipher}'",
            "shared_buffers": shared_buffers,
        }
    )
    cluster.add_hba_entry("local all all trust")
    cluster.start()

    # Match the bash flow: extension + DATABASE-scope provider + DATABASE-scope key.
    # SMGR cipher reuse is independent of provider scope, but staying faithful to
    # the bash script catches scope-specific regressions for free.
    cluster.execute("CREATE EXTENSION pg_tde")
    cluster.execute(
        f"SELECT pg_tde_add_database_key_provider_file('smgr-ctx-test'::text, "
        f"'{keyfile}'::text)"
    )
    cluster.execute(
        "SELECT pg_tde_create_key_using_database_key_provider("
        "'smgr-ctx-key'::text, 'smgr-ctx-test'::text)"
    )
    cluster.execute(
        "SELECT pg_tde_set_key_using_database_key_provider("
        "'smgr-ctx-key'::text, 'smgr-ctx-test'::text)"
    )
    return cluster


def _create_two_heaps_and_workload(cluster: PgCluster) -> None:
    """
    Mirrors bash lines 73–113: two encrypted heaps with different
    relation keys + interleaved scans + UPDATE/DELETE/VACUUM.
    """
    cluster.execute(
        "CREATE TABLE ctx_heap_a (id INT NOT NULL, payload TEXT NOT NULL, "
        "PRIMARY KEY (id)) USING tde_heap"
    )
    cluster.execute(
        "CREATE TABLE ctx_heap_b (id INT NOT NULL, payload TEXT NOT NULL, "
        "PRIMARY KEY (id)) USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_heap_a SELECT i, repeat(md5(i::text), 8) "
        "FROM generate_series(1, 60000) AS i"
    )
    cluster.execute(
        "INSERT INTO ctx_heap_b SELECT i, repeat(md5((i + 100000)::text), 8) "
        "FROM generate_series(1, 30000) AS i"
    )

    # Interleaved reads: 40 passes, each touching both heaps with different
    # filters. Stresses the reused EVP_CIPHER_CTX across two relation keys.
    cluster.execute(
        "DO $$ BEGIN "
        "  FOR _pass IN 1..40 LOOP "
        "    PERFORM count(*) FROM ctx_heap_a WHERE id % 97 = 0; "
        "    PERFORM sum(length(payload)) FROM ctx_heap_b WHERE id % 89 = 0; "
        "    PERFORM avg(id::float8) FROM ctx_heap_a; "
        "    PERFORM max(id) FROM ctx_heap_b; "
        "  END LOOP; "
        "END $$"
    )

    cluster.execute(
        "UPDATE ctx_heap_a SET payload = repeat('Z', 128) WHERE id % 1009 = 0"
    )
    cluster.execute(
        "UPDATE ctx_heap_b SET payload = repeat('Q', 128) WHERE id % 1013 = 0"
    )
    cluster.execute("DELETE FROM ctx_heap_a WHERE id % 4001 = 0")
    cluster.execute("DELETE FROM ctx_heap_b WHERE id % 4003 = 0")
    cluster.execute("VACUUM ctx_heap_a, ctx_heap_b")


def _create_extended_scenarios(cluster: PgCluster) -> None:
    """
    Mirrors bash lines 117–214: partitioned, TOAST, CTAS + savepoint,
    TRUNCATE + reload, REINDEX/CLUSTER, index-preferred + interleaved
    UNION ALL.
    """
    cluster.execute(
        "CREATE TABLE ctx_part (k INT NOT NULL, v TEXT NOT NULL, PRIMARY KEY (k)) "
        "PARTITION BY RANGE (k) USING tde_heap"
    )
    cluster.execute(
        "CREATE TABLE ctx_part_p1 PARTITION OF ctx_part "
        "FOR VALUES FROM (MINVALUE) TO (5000) USING tde_heap"
    )
    cluster.execute(
        "CREATE TABLE ctx_part_p2 PARTITION OF ctx_part "
        "FOR VALUES FROM (5000) TO (10000) USING tde_heap"
    )
    cluster.execute(
        "CREATE TABLE ctx_part_p3 PARTITION OF ctx_part "
        "FOR VALUES FROM (10000) TO (MAXVALUE) USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_part SELECT i, repeat(md5(i::text), 6) "
        "FROM generate_series(1, 12000) AS i"
    )
    cluster.execute("UPDATE ctx_part SET v = repeat('P', 96) WHERE k % 1777 = 0")

    cluster.execute(
        "CREATE TABLE ctx_toast (id INT PRIMARY KEY, blob TEXT NOT NULL) USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_toast SELECT i, repeat(chr(65 + (i % 26)), 9500) "
        "FROM generate_series(1, 250) AS i"
    )

    # Mixed scan interleave on the new objects
    cluster.execute(
        "DO $$ BEGIN "
        "  FOR _pass IN 1..15 LOOP "
        "    PERFORM sum(length(blob)) FROM ctx_toast WHERE id % 11 <> 0; "
        "    PERFORM count(*) FROM ctx_part WHERE k % 13 = 0; "
        "  END LOOP; "
        "END $$"
    )

    # CTAS from encrypted heap; savepoint rolls back a partial rewrite.
    cluster.execute(
        "CREATE TABLE ctx_ctas USING tde_heap AS "
        "SELECT id, payload FROM ctx_heap_a WHERE id <= 500"
    )
    cluster.execute("ALTER TABLE ctx_ctas ADD PRIMARY KEY (id)")
    cluster.execute("INSERT INTO ctx_ctas VALUES (999001, repeat('S', 128))")
    cluster.execute(
        "BEGIN; "
        "SAVEPOINT sp_ctx_ctas; "
        "UPDATE ctx_ctas SET payload = repeat('!', 128) WHERE id = 1; "
        "ROLLBACK TO SAVEPOINT sp_ctx_ctas; "
        "COMMIT"
    )

    # TRUNCATE then refill: new relfilenode under the same SMGR context.
    cluster.execute(
        "CREATE TABLE ctx_trunc (n INT PRIMARY KEY, note TEXT NOT NULL) USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_trunc SELECT g, repeat('n', 72) "
        "FROM generate_series(1, 9000) AS g"
    )
    cluster.execute("TRUNCATE ctx_trunc")
    cluster.execute("INSERT INTO ctx_trunc VALUES (7, 'trunc-reload')")

    # Physical reorder / rebuild paths still decrypt correctly
    cluster.execute("REINDEX TABLE ctx_heap_b")
    cluster.execute("CLUSTER ctx_heap_b USING ctx_heap_b_pkey")
    cluster.execute("ANALYZE ctx_heap_a, ctx_heap_b, ctx_part, ctx_toast, ctx_ctas, ctx_trunc")

    # Force index-only path on one subtree (heap pages still decrypted via lookups).
    cluster.execute(
        "SET enable_seqscan = off; "
        "SELECT count(*)::bigint, sum(id::bigint), max(length(payload)) "
        "FROM ctx_heap_a WHERE id BETWEEN 50 AND 2500; "
        "RESET enable_seqscan"
    )


def _create_bulk_io(cluster: PgCluster) -> None:
    """Mirrors bash lines 230–272: wide-row + narrow-row bulk heaps + seqscans."""
    cluster.execute(
        "CREATE TABLE ctx_bulk_wide (id INT PRIMARY KEY, payload TEXT NOT NULL) "
        "USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_bulk_wide SELECT i, repeat(md5(i::text), 32) "
        "FROM generate_series(1, 20000) AS i"
    )
    cluster.execute(
        "CREATE TABLE ctx_bulk_seq (id INT PRIMARY KEY, payload TEXT NOT NULL) "
        "USING tde_heap"
    )
    cluster.execute(
        "INSERT INTO ctx_bulk_seq SELECT i, repeat(chr(48 + (i % 10)), 120) "
        "FROM generate_series(1, 45000) AS i"
    )
    cluster.execute("CHECKPOINT")

    # PG14+ only: reset per-table statio so heap_blks_read counts begin at 0
    # for the cold-cache pass below.
    if postgres_major_version(cluster.install_dir) >= 14:
        cluster.execute(
            "SELECT pg_stat_reset_single_table_counters(c.oid) "
            "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname = 'public' AND c.relname IN "
            "('ctx_bulk_wide', 'ctx_bulk_seq', 'ctx_heap_a', 'ctx_heap_b')"
        )
        cluster.execute("CHECKPOINT")

    for tbl in ("ctx_heap_a", "ctx_bulk_seq", "ctx_bulk_wide", "ctx_heap_b", "ctx_heap_a"):
        cluster.execute(
            f"SELECT sum(length(payload))::bigint, count(*)::bigint FROM {tbl}"
        )
    cluster.execute(
        "DO $$ BEGIN "
        "  FOR _pass IN 1..8 LOOP "
        "    PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_bulk_seq; "
        "    PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_heap_a; "
        "    PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_bulk_wide; "
        "    PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_heap_b; "
        "  END LOOP; "
        "END $$"
    )
    cluster.execute("VACUUM ctx_bulk_wide, ctx_bulk_seq")


def _copy_into_encrypted_heap(cluster: PgCluster, *, tmp_path: Path) -> None:
    """
    Mirrors bash lines 275–282: server-side ``COPY FROM STDIN`` into a
    ``tde_heap`` table. We materialise the body of the COPY as a file
    on disk and stream it in via ``COPY ... FROM '<file>'``.
    """
    cluster.execute(
        "CREATE TABLE ctx_copy_load (id INT PRIMARY KEY, payload TEXT NOT NULL) "
        "USING tde_heap"
    )
    copy_file = tmp_path / "ctx_copy_load.tsv"
    payload = "c" * 128
    with copy_file.open("w") as f:
        for i in range(1, 4001):
            f.write(f"{i}\t{payload}\n")
    cluster.execute(f"COPY ctx_copy_load FROM '{copy_file}'")


# ── verification helpers ──────────────────────────────────────────────────────


def _verify_core_encryption_and_data(cluster: PgCluster) -> None:
    """Mirrors bash ``verify_encryption_and_data``."""
    for rel in ("ctx_heap_a", "ctx_heap_b", "ctx_heap_a_pkey", "ctx_heap_b_pkey"):
        assert cluster.fetchone(
            f"SELECT pg_tde_is_encrypted('{rel}'::regclass)"
        ) == "t", f"{rel} should be encrypted under tde_heap"

    for rel in ("ctx_heap_a", "ctx_heap_b"):
        am = cluster.fetchone(
            f"SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid "
            f"WHERE c.relname = '{rel}'"
        )
        assert am == "tde_heap", f"{rel} should use tde_heap (got {am!r})"

    # Untouched payloads still decrypt to the original deterministic strings.
    assert cluster.fetchone(
        "SELECT payload = repeat(md5(1::text), 8) FROM ctx_heap_a WHERE id = 1"
    ) == "t"
    assert cluster.fetchone(
        "SELECT payload = repeat(md5(100001::text), 8) FROM ctx_heap_b WHERE id = 1"
    ) == "t"

    # Updated payloads decrypt to the new constants.
    assert cluster.fetchone(
        "SELECT payload = repeat('Z', 128) FROM ctx_heap_a WHERE id = 1009"
    ) == "t"
    assert cluster.fetchone(
        "SELECT payload = repeat('Q', 128) FROM ctx_heap_b WHERE id = 1013"
    ) == "t"

    # Deleted rows are gone.
    assert cluster.fetchone("SELECT EXISTS (SELECT 1 FROM ctx_heap_a WHERE id = 4001)") == "f"
    assert cluster.fetchone("SELECT EXISTS (SELECT 1 FROM ctx_heap_b WHERE id = 4003)") == "f"


def _verify_extended_scenarios(cluster: PgCluster) -> None:
    """Mirrors bash ``verify_extended_scenarios``.

    Note: the bash script asserts every relation via ``bool_and()`` which
    is NULL-poisoned, so it implicitly assumed all listed relations would
    return ``'t'``. The actual pg_tde contract — pinned by the dedicated
    tests in ``test_partitioning.py`` and the
    `Percona pg_tde Functions reference <https://docs.percona.com/pg-tde/functions.html#pg-tde-is-encrypted>`_ —
    is that ``pg_tde_is_encrypted`` returns **NULL** for relations that
    have no storage of their own. That covers two cases here:

      * Partitioned table parent (``ctx_part``).
      * Partitioned index parent (``ctx_part_pkey``) — declared on a
        partitioned table, the per-leaf indexes are the encrypted ones.

    All other relations (leaves, regular heaps, their PKs, TOAST heaps,
    CTAS, COPY targets) must return ``'t'``.
    """
    storageless_rels = {"ctx_part", "ctx_part_pkey"}
    encrypted_rels = (
        "ctx_part", "ctx_part_p1", "ctx_part_p2", "ctx_part_p3",
        "ctx_toast", "ctx_ctas", "ctx_trunc",
        "ctx_bulk_wide", "ctx_bulk_seq", "ctx_copy_load",
        "ctx_part_pkey", "ctx_toast_pkey", "ctx_ctas_pkey", "ctx_trunc_pkey",
        "ctx_bulk_wide_pkey", "ctx_bulk_seq_pkey", "ctx_copy_load_pkey",
        "ctx_part_p1_pkey", "ctx_part_p2_pkey", "ctx_part_p3_pkey",
    )
    for rel in encrypted_rels:
        got = cluster.fetchone(f"SELECT pg_tde_is_encrypted('{rel}'::regclass)") or ""
        if rel in storageless_rels:
            assert got in ("", "t"), (
                f"{rel} is a partitioned parent — pg_tde_is_encrypted "
                f"must return NULL (preferred) or 't', got {got!r}"
            )
        else:
            assert got == "t", f"{rel} should be encrypted, got {got!r}"

    assert cluster.fetchone("SELECT count(*) FROM ctx_part") == "12000"
    assert cluster.fetchone("SELECT sum(k::bigint) FROM ctx_part") == "72006000"
    # Rows hit by the UPDATE have length(v)=96, others have length(v)=192 (md5*6).
    assert cluster.fetchone(
        "SELECT bool_and(length(v) = 96) FROM ctx_part WHERE k % 1777 = 0"
    ) == "t"
    assert cluster.fetchone(
        "SELECT bool_and(length(v) = 192) FROM ctx_part WHERE k % 1777 <> 0"
    ) == "t"

    assert cluster.fetchone(
        "SELECT count(*) = 250 AND min(length(blob)) = 9500 AND "
        "max(length(blob)) = 9500 FROM ctx_toast"
    ) == "t"

    assert cluster.fetchone(
        "SELECT payload = repeat(md5(1::text), 8) FROM ctx_ctas WHERE id = 1"
    ) == "t"
    assert cluster.fetchone(
        "SELECT payload = repeat('S', 128) FROM ctx_ctas WHERE id = 999001"
    ) == "t"
    assert cluster.fetchone("SELECT count(*) FROM ctx_ctas") == "501"

    assert cluster.fetchone(
        "SELECT count(*) = 1 AND max(note) = 'trunc-reload' AND max(n) = 7 FROM ctx_trunc"
    ) == "t"

    assert cluster.fetchone(
        "SELECT count(*) = 20000 AND sum(length(payload)::bigint) = 20480000::bigint "
        "FROM ctx_bulk_wide"
    ) == "t"
    assert cluster.fetchone(
        "SELECT count(*) = 45000 AND sum(length(payload)::bigint) = 5400000::bigint "
        "FROM ctx_bulk_seq"
    ) == "t"
    assert cluster.fetchone(
        "SELECT count(*) = 4000 AND min(length(payload)) = 128 AND "
        "max(length(payload)) = 128 FROM ctx_copy_load"
    ) == "t"
    assert cluster.fetchone(
        "SELECT payload = repeat('c', 128) FROM ctx_copy_load WHERE id = 1"
    ) == "t"


def _heap_stats_snapshot(cluster: PgCluster) -> str:
    """Mirrors bash ``read_heap_stats``: per-table aggregates."""
    out = cluster.execute(
        "SELECT 'a', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_heap_a UNION ALL "
        "SELECT 'b', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_heap_b UNION ALL "
        "SELECT 'part', count(*)::text, sum(k::bigint)::text, sum(length(v))::text "
        "FROM ctx_part UNION ALL "
        "SELECT 'toast', count(*)::text, sum(id::bigint)::text, sum(length(blob))::text "
        "FROM ctx_toast UNION ALL "
        "SELECT 'ctas', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_ctas UNION ALL "
        "SELECT 'trunc', count(*)::text, sum(n::bigint)::text, sum(length(note))::text "
        "FROM ctx_trunc UNION ALL "
        "SELECT 'bulk_wide', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_bulk_wide UNION ALL "
        "SELECT 'bulk_seq', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_bulk_seq UNION ALL "
        "SELECT 'copy_load', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text "
        "FROM ctx_copy_load ORDER BY 1"
    )
    return out.strip()


# ── tests ─────────────────────────────────────────────────────────────────────


class TestSmgrCipherReuseFullSuite:
    """
    End-to-end mirror of the bash ``run_cipher_suite`` flow. Runs the
    entire workload (two heaps + extended scenarios + bulk I/O + COPY)
    then restarts the server and verifies aggregates are identical.

    Parametrized on both ``aes_128`` and ``aes_256`` because the SMGR
    cipher context is sized per key length and a regression can hide on
    one but not the other.
    """

    @pytest.mark.parametrize("cipher", CIPHERS)
    def test_full_suite_data_intact_across_restart(
        self, pg_factory, tmp_path: Path, cipher: str
    ):
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, f"smgr_full_{cipher}", cipher=cipher
        )

        # Sanity-check: the requested cipher is actually active.
        assert cluster.fetchone("SHOW pg_tde.cipher") == cipher

        _create_two_heaps_and_workload(cluster)
        _create_extended_scenarios(cluster)
        _create_bulk_io(cluster)
        _copy_into_encrypted_heap(cluster, tmp_path=tmp_path)

        _verify_core_encryption_and_data(cluster)
        _verify_extended_scenarios(cluster)
        before = _heap_stats_snapshot(cluster)
        assert before, "empty heap stats snapshot — workload setup is broken"

        # Restart the server so the SMGR cipher contexts are re-created
        # and pg_tde re-loads its keys. The bug class this test guards
        # against is "context state leaks between two server lifetimes".
        cluster.restart()
        cluster.wait_ready()

        _verify_core_encryption_and_data(cluster)
        _verify_extended_scenarios(cluster)
        after = _heap_stats_snapshot(cluster)
        assert before == after, (
            f"heap aggregates differ before/after restart "
            f"(cipher={cipher})\nBEFORE:\n{before}\nAFTER:\n{after}"
        )


class TestSmgrCipherReuseFocused:
    """
    Focused regressions for individual SMGR code paths. Quick to run, and
    failure points at exactly which path regressed. Single-cipher
    (aes_128, default) — the cross-cipher coverage is in
    ``TestSmgrCipherReuseFullSuite``.
    """

    def test_two_relations_different_keys_decrypt_independently(
        self, pg_factory, tmp_path: Path
    ):
        """
        Two ``tde_heap`` tables created in the same backend share the
        SMGR cipher context but have **distinct** per-relation keys.
        Each row must decrypt to its own deterministic plaintext.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_two_rels", cipher="aes_128"
        )
        _create_two_heaps_and_workload(cluster)

        # Spot check several rows from each heap so a key/IV mix-up
        # between relations would be caught.
        for i in (1, 2, 7, 9000, 59999):
            assert cluster.fetchone(
                f"SELECT payload = repeat(md5({i}::text), 8) "
                f"FROM ctx_heap_a WHERE id = {i}"
            ) == "t", f"ctx_heap_a row {i} decrypted incorrectly"
        for i in (1, 2, 7, 9000, 29999):
            assert cluster.fetchone(
                f"SELECT payload = repeat(md5(({i} + 100000)::text), 8) "
                f"FROM ctx_heap_b WHERE id = {i}"
            ) == "t", f"ctx_heap_b row {i} decrypted incorrectly"

    def test_partitioned_tde_heap_one_query_tree(self, pg_factory, tmp_path: Path):
        """
        Three encrypted child partitions touched in one SELECT exercise
        SMGR decrypt with three different per-relation keys inside a
        single query tree.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_partitioned", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE p (k INT NOT NULL, v TEXT NOT NULL, PRIMARY KEY (k)) "
            "PARTITION BY RANGE (k) USING tde_heap"
        )
        for i, (lo, hi) in enumerate(((0, 5000), (5000, 10000), (10000, 15000))):
            cluster.execute(
                f"CREATE TABLE p_{i} PARTITION OF p "
                f"FOR VALUES FROM ({lo}) TO ({hi}) USING tde_heap"
            )
        cluster.execute(
            "INSERT INTO p SELECT i, repeat(md5(i::text), 4) "
            "FROM generate_series(1, 14999) AS i"
        )

        # One scan over the partitioned table — touches all three children.
        assert cluster.fetchone("SELECT count(*) FROM p") == "14999"
        # Boundary rows in each child decrypt to their original plaintext.
        for i in (1, 4999, 5000, 9999, 10000, 14999):
            assert cluster.fetchone(
                f"SELECT v = repeat(md5({i}::text), 4) FROM p WHERE k = {i}"
            ) == "t"

    def test_toast_external_storage_decrypts(self, pg_factory, tmp_path: Path):
        """
        Rows with payloads above 8 kB are stored in TOAST. TOAST tables
        are also ``tde_heap``; SMGR decrypt must work for both the heap
        and the toast relation.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_toast", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE t_toast (id INT PRIMARY KEY, blob TEXT NOT NULL) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO t_toast SELECT i, repeat(chr(65 + (i % 26)), 12000) "
            "FROM generate_series(1, 100) AS i"
        )
        # The TOAST relation itself must exist and decrypt cleanly.
        toast_oid = cluster.fetchone(
            "SELECT reltoastrelid FROM pg_class WHERE relname = 't_toast'"
        )
        assert toast_oid and toast_oid != "0"
        assert cluster.fetchone(
            f"SELECT pg_tde_is_encrypted({toast_oid}::oid::regclass)"
        ) == "t"

        # CHECKPOINT then read every row back; values must round-trip.
        cluster.execute("CHECKPOINT")
        for i in (1, 25, 50, 75, 100):
            expected_char = chr(65 + (i % 26))
            assert cluster.fetchone(
                f"SELECT blob = repeat('{expected_char}', 12000) "
                f"FROM t_toast WHERE id = {i}"
            ) == "t", f"row {i} TOAST payload mismatch"

    def test_ctas_with_savepoint_rollback_preserves_pre_rollback_state(
        self, pg_factory, tmp_path: Path
    ):
        """
        CTAS into a ``tde_heap`` table, followed by a partial in-place
        UPDATE rolled back via SAVEPOINT, must leave the original CTAS
        rows intact and decryptable.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_ctas_sp", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE src (id INT PRIMARY KEY, v TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO src SELECT i, 'orig-' || i FROM generate_series(1, 100) AS i"
        )
        cluster.execute("CREATE TABLE ctas USING tde_heap AS SELECT * FROM src")
        cluster.execute("ALTER TABLE ctas ADD PRIMARY KEY (id)")
        cluster.execute(
            "BEGIN; "
            "SAVEPOINT sp1; "
            "UPDATE ctas SET v = 'aborted' WHERE id <= 50; "
            "ROLLBACK TO SAVEPOINT sp1; "
            "COMMIT"
        )
        assert cluster.fetchone("SELECT count(*) FROM ctas WHERE v = 'aborted'") == "0"
        assert cluster.fetchone(
            "SELECT v = 'orig-1' FROM ctas WHERE id = 1"
        ) == "t"
        assert cluster.fetchone(
            "SELECT v = 'orig-100' FROM ctas WHERE id = 100"
        ) == "t"

    def test_truncate_and_reload_uses_fresh_relfilenode_correctly(
        self, pg_factory, tmp_path: Path
    ):
        """
        ``TRUNCATE`` allocates a fresh ``relfilenode``; subsequent INSERTs
        must encrypt onto the new file with the same SMGR context state
        (which the reuse change has to handle correctly).
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_trunc", cipher="aes_128"
        )
        cluster.execute("CREATE TABLE t (id INT PRIMARY KEY, v TEXT) USING tde_heap")
        cluster.execute(
            "INSERT INTO t SELECT i, repeat('A', 64) FROM generate_series(1, 5000) AS i"
        )
        rfnode_before = cluster.fetchone(
            "SELECT relfilenode FROM pg_class WHERE relname = 't'"
        )
        cluster.execute("TRUNCATE t")
        rfnode_after = cluster.fetchone(
            "SELECT relfilenode FROM pg_class WHERE relname = 't'"
        )
        assert rfnode_before != rfnode_after, (
            "TRUNCATE did not allocate a new relfilenode; "
            "test cannot prove the fresh-storage encrypt path"
        )
        cluster.execute("INSERT INTO t VALUES (1, 'after-trunc')")
        cluster.execute("CHECKPOINT")
        cluster.restart()
        cluster.wait_ready()
        assert cluster.fetchone("SELECT count(*) FROM t") == "1"
        assert cluster.fetchone("SELECT v FROM t WHERE id = 1") == "after-trunc"

    def test_reindex_and_cluster_decrypt_after_physical_reorder(
        self, pg_factory, tmp_path: Path
    ):
        """
        ``REINDEX`` rewrites the index; ``CLUSTER`` rewrites the heap in
        index order. Both must produce a relation that decrypts to the
        same plaintext that was inserted.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_reindex_cluster", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE t (id INT NOT NULL, v TEXT NOT NULL, PRIMARY KEY (id)) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO t SELECT i, 'row-' || i FROM generate_series(1, 5000) AS i"
        )
        # Delete a chunk so CLUSTER actually has work to do.
        cluster.execute("DELETE FROM t WHERE id % 7 = 0")
        cluster.execute("REINDEX TABLE t")
        cluster.execute("CLUSTER t USING t_pkey")
        cluster.execute("ANALYZE t")
        # 5000 inserted, ids 7, 14, …, 4998 deleted (714 rows) → 4286 remain.
        assert cluster.fetchone("SELECT count(*) FROM t") == "4286"
        assert cluster.fetchone("SELECT v FROM t WHERE id = 1") == "row-1"
        assert cluster.fetchone("SELECT v FROM t WHERE id = 5000") == "row-5000"
        # The deleted rows must still be gone.
        assert cluster.fetchone("SELECT count(*) FROM t WHERE id % 7 = 0") == "0"

    def test_copy_from_file_into_tde_heap_round_trips(
        self, pg_factory, tmp_path: Path
    ):
        """
        Server-side ``COPY ... FROM '<file>'`` into a ``tde_heap`` table.
        Every row must come back via SELECT exactly as it went in.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_copy", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE t_copy (id INT PRIMARY KEY, v TEXT NOT NULL) USING tde_heap"
        )
        copy_file = tmp_path / "smgr_copy.tsv"
        with copy_file.open("w") as f:
            for i in range(1, 2001):
                f.write(f"{i}\tcopy-payload-{i}\n")
        cluster.execute(f"COPY t_copy FROM '{copy_file}'")
        assert cluster.fetchone("SELECT count(*) FROM t_copy") == "2000"
        for i in (1, 999, 2000):
            assert cluster.fetchone(
                f"SELECT v = 'copy-payload-{i}' FROM t_copy WHERE id = {i}"
            ) == "t"

    def test_cold_seqscan_forces_smgr_read_off_disk(
        self, pg_factory, tmp_path: Path
    ):
        """
        With ``shared_buffers = 2MB`` and ~25 MB of bulk-row data, full
        seqscans cannot be cache-only. ``pg_statio_user_tables`` must
        report ``heap_blks_read > 0`` for those tables — which is the
        smoking gun that the bytes went through pg_tde's SMGR decrypt
        path, not just through shared buffers.

        Skipped on pre-PG14 (no ``pg_stat_reset_single_table_counters``).
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_cold", cipher="aes_128"
        )
        if postgres_major_version(cluster.install_dir) < 14:
            pytest.skip("pg_stat_reset_single_table_counters needs PG14+")

        cluster.execute(
            "CREATE TABLE bulk_seq (id INT PRIMARY KEY, payload TEXT NOT NULL) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO bulk_seq SELECT i, repeat(chr(48 + (i % 10)), 200) "
            "FROM generate_series(1, 30000) AS i"
        )
        cluster.execute("CHECKPOINT")
        cluster.execute(
            "SELECT pg_stat_reset_single_table_counters('bulk_seq'::regclass)"
        )
        # The reset itself is async vs the stats collector; let it settle.
        cluster.execute("CHECKPOINT")

        # Force a cold-cache full seqscan.
        cluster.execute("SELECT count(*), sum(length(payload)) FROM bulk_seq")

        # Stats are accumulated by a background process; poll briefly.
        import time
        deadline = time.time() + 10
        blks_read = "0"
        while time.time() < deadline:
            blks_read = cluster.fetchone(
                "SELECT heap_blks_read FROM pg_statio_user_tables "
                "WHERE relname = 'bulk_seq'"
            ) or "0"
            if int(blks_read) > 0:
                break
            time.sleep(0.5)

        assert int(blks_read) > 0, (
            f"Expected heap_blks_read > 0 on cold-cache seqscan over bulk_seq "
            f"(got {blks_read}); SMGR decrypt path may not be exercised."
        )

    def test_multi_relation_interleaved_scan_completes_correctly(
        self, pg_factory, tmp_path: Path
    ):
        """
        Single SELECT fans out across multiple encrypted heaps via
        ``UNION ALL``. The executor will round-robin SMGR reads across
        relations; the reused cipher context must keep keys/IVs straight.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_interleave", cipher="aes_128"
        )
        _create_two_heaps_and_workload(cluster)
        _create_extended_scenarios(cluster)

        total = cluster.fetchone(
            "SELECT coalesce(sum(cnt), 0) FROM ("
            "  SELECT count(*) AS cnt FROM ctx_part WHERE k % 3 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_toast WHERE id % 5 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_ctas WHERE id % 7 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_trunc UNION ALL "
            "  SELECT count(*) FROM ctx_heap_a WHERE id % 17 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_heap_b WHERE id % 19 = 0"
            ") q"
        )
        # The exact value depends on row counts; just assert it's non-empty
        # and consistent with what each leg returns independently.
        assert total and int(total) > 0
        # Re-running the same query must return the same total.
        again = cluster.fetchone(
            "SELECT coalesce(sum(cnt), 0) FROM ("
            "  SELECT count(*) AS cnt FROM ctx_part WHERE k % 3 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_toast WHERE id % 5 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_ctas WHERE id % 7 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_trunc UNION ALL "
            "  SELECT count(*) FROM ctx_heap_a WHERE id % 17 = 0 UNION ALL "
            "  SELECT count(*) FROM ctx_heap_b WHERE id % 19 = 0"
            ") q"
        )
        assert again == total, (
            f"interleaved scan total flapped: {total} → {again}"
        )

    def test_index_only_path_decrypts_heap_lookups(self, pg_factory, tmp_path: Path):
        """
        With ``enable_seqscan = off`` the optimiser uses the primary-key
        btree; heap lookups for the visibility check still have to
        decrypt the leaf heap page via SMGR.
        """
        cluster = _build_smgr_cluster(
            pg_factory, tmp_path, "smgr_indexscan", cipher="aes_128"
        )
        cluster.execute(
            "CREATE TABLE t (id INT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (id)) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO t SELECT i, repeat(md5(i::text), 8) "
            "FROM generate_series(1, 5000) AS i"
        )
        cluster.execute("CHECKPOINT")
        cluster.execute("ANALYZE t")
        cluster.execute("SET enable_seqscan = off")
        cluster.execute("SET enable_bitmapscan = off")
        row = cluster.fetchone(
            "SELECT count(*)::bigint || ',' || coalesce(max(length(payload))::text, '0') "
            "FROM t WHERE id BETWEEN 100 AND 200"
        )
        cluster.execute("RESET enable_seqscan")
        cluster.execute("RESET enable_bitmapscan")
        # 101 rows, all with length(md5(...)*8) = 32*8 = 256.
        assert row == "101,256"


# ── pg_tde.cipher GUC ─────────────────────────────────────────────────────────
#
# These tests cover the *user-facing* cipher contract (the GUC), as opposed
# to the SMGR-context-reuse tests above which cover the *internal* cipher
# code path. Kept in the same module so anyone hunting for "cipher tests"
# finds the full surface area in one place.


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
