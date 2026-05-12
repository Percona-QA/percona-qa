"""
pg_tde_waldump tests against encrypted and plaintext WAL.

Background — three binaries are at play:

  * upstream ``pg_waldump`` (shipped by PostgreSQL): has no knowledge of the
    pg_tde rmgr (custom id 140) or of WAL segments encrypted via
    ``pg_tde.wal_encrypt = on``. Running it on encrypted WAL produces errors
    or far fewer decoded records. Used here only to pin that contract.

  * Percona's ``pg_tde_waldump``: wraps ``pg_waldump`` and adds:

        -k, --keyring-path=PATH   directory containing wal_keys + 1664_providers
                                  (usually $PGDATA/pg_tde). With ``-k`` it fully
                                  decrypts encrypted records. Without ``-k`` it
                                  silently skips encrypted bodies instead of
                                  erroring out, so the unencrypted rmgrs
                                  (CHECKPOINT, Standby, …) still decode.

These tests cover the full ``pg_tde_waldump`` CLI surface
(``-r``/``--rmgr``, ``-R``/``--relation``, ``-x``/``--xid``, ``-s``/``-e``,
``-n``/``--limit``, ``-z``/``--stats``, ``-q``/``--quiet``, ``-b``/``--bkp-details``,
``-F``/``--fork``, ``--save-fullpage``) and exercise decoded output across a
wide range of data types and relation kinds.
"""
import os
import subprocess
from pathlib import Path
from typing import List, Sequence, Tuple

import pytest

from conftest import allocate_port  # noqa: F401  (kept for parity with sibling tests)
from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums


pytestmark = [pytest.mark.encryption, pytest.mark.waldump]


# pg_waldump / pg_tde_waldump exit non-zero when they reach the zero-padded
# tail of a switched WAL segment — that is "no more records here", not a real
# failure. We tolerate any of these messages on stderr.
_EOF_TAIL_STDERR_PHRASES: Tuple[str, ...] = (
    "invalid magic number",
    "could not find a valid record",
    "out-of-sequence timeline ID",
    "invalid record length",
)


# ── helpers ───────────────────────────────────────────────────────────────────


def _env(install_dir: Path) -> dict:
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = (
        f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    return env


def _waldump_bin(cluster: PgCluster, name: str) -> Path:
    """Return the binary path, skipping the test if not present in the build."""
    p = cluster.bin / name
    if not p.exists():
        pytest.skip(f"{name} not present at {p}")
    return p


def _run_waldump(
    cluster: PgCluster,
    args: Sequence,
    *,
    binary: str = "pg_tde_waldump",
    with_keyring: bool = True,
) -> subprocess.CompletedProcess:
    """
    Invoke pg_waldump / pg_tde_waldump with the right LD_LIBRARY_PATH and,
    for the TDE wrapper, ``-k <pgdata>/pg_tde`` so encrypted records decode.
    """
    bin_path = _waldump_bin(cluster, binary)
    cmd: List[str] = [str(bin_path)]
    if binary == "pg_tde_waldump" and with_keyring:
        cmd.extend(["-k", str(cluster.data_dir / "pg_tde")])
    cmd.extend(str(a) for a in args)
    return subprocess.run(
        cmd, capture_output=True, text=True, env=_env(cluster.install_dir)
    )


def _is_eof_tail(stderr: str) -> bool:
    s = stderr.lower()
    return any(p in s for p in _EOF_TAIL_STDERR_PHRASES)


def _assert_ok_or_eof_tail(
    result: subprocess.CompletedProcess, *, descr: str
) -> None:
    """A non-zero exit is OK iff the message is just an EOF-tail signal."""
    if result.returncode == 0:
        return
    assert _is_eof_tail(result.stderr), (
        f"{descr} failed with a non-EOF error.\n"
        f"stderr:\n{result.stderr}\nstdout head:\n{result.stdout[:1500]}"
    )


def _decoded_record_count(stdout: str) -> int:
    """Approximate number of decoded WAL records in stdout."""
    return sum(1 for line in stdout.splitlines() if line.startswith("rmgr:"))


def _decoded_rmgrs(stdout: str) -> set:
    """Set of rmgr names that appear in stdout (the 2nd whitespace token)."""
    rmgrs = set()
    for line in stdout.splitlines():
        if line.startswith("rmgr:"):
            parts = line.split()
            if len(parts) >= 2:
                rmgrs.add(parts[1])
    return rmgrs


def _start_tde_cluster_with_wal_encryption(
    pg_factory,
    tmp_path: Path,
    *,
    name: str = "wd_src",
) -> PgCluster:
    """Build a TDE cluster with ``pg_tde.wal_encrypt = on`` ready to write WAL."""
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
    tde.add_global_key_provider_file(keyfile=str(tmp_path / f"{name}.per"))
    tde.set_global_principal_key()
    tde.enable_wal_encryption()  # restarts; pg_tde.wal_encrypt is PGC_POSTMASTER
    assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    return cluster


def _start_plaintext_cluster(pg_factory, *, name: str = "wd_plain") -> PgCluster:
    cluster = pg_factory(name)
    cluster.initdb()
    cluster.write_default_config()
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    return cluster


def _flushed_segment(cluster: PgCluster) -> Path:
    """
    Force a WAL segment switch and return the file path of the just-closed
    segment. We deliberately do NOT checkpoint *after* pg_switch_wal — that
    can recycle the file we just captured.
    """
    cluster.execute("CHECKPOINT")
    seg_name = cluster.fetchone(
        "SELECT pg_walfile_name(pg_current_wal_insert_lsn())"
    )
    cluster.execute("SELECT pg_switch_wal()")
    seg_path = cluster.data_dir / "pg_wal" / seg_name
    assert seg_path.exists(), (
        f"WAL segment {seg_name} not present under {cluster.data_dir/'pg_wal'} "
        "after pg_switch_wal — did a background checkpoint recycle it?"
    )
    return seg_path


def _lsn_now(cluster: PgCluster) -> str:
    return cluster.fetchone("SELECT pg_current_wal_insert_lsn()")


def _relation_filter(cluster: PgCluster, table: str, dbname: str = "postgres") -> str:
    """
    Build the ``T/D/R`` relation locator used by ``-R/--relation``:
    tablespace_oid / database_oid / relfilenode. For tables in the default
    tablespace ``reltablespace`` is 0; fall back to ``pg_default``'s OID.
    """
    return cluster.fetchone(
        "SELECT COALESCE(NULLIF(c.reltablespace, 0), "
        "                (SELECT oid FROM pg_tablespace WHERE spcname='pg_default'))::text "
        " || '/' || (SELECT oid FROM pg_database WHERE datname=current_database())::text "
        " || '/' || pg_relation_filenode(c.oid)::text "
        f"FROM pg_class c WHERE c.relname='{table}'",
        dbname,
    )


def _assert_no_plaintext(seg: Path, marker: str) -> None:
    on_disk = seg.read_bytes()
    assert marker.encode() not in on_disk, (
        f"Plaintext marker '{marker[:40]}…' leaked into encrypted WAL segment "
        f"{seg.name} (pg_tde.wal_encrypt=on but the file is plaintext on disk)."
    )


# ── vanilla pg_waldump vs pg_tde_waldump on encrypted WAL ────────────────────


class TestPgWaldumpVsPgTdeWaldumpOnEncryptedWal:
    """
    With ``pg_tde.wal_encrypt = on`` only pg_tde_waldump with ``-k`` can fully
    decode the segment. Pin the contract:

      * vanilla pg_waldump cannot decode encrypted WAL (it either errors or
        produces noticeably fewer records than the wrapper);
      * pg_tde_waldump without ``-k`` does not crash and still walks
        unencrypted rmgrs;
      * pg_tde_waldump with ``-k`` produces a full, dense decode.
    """

    def _prepare(self, pg_factory, tmp_path) -> Tuple[PgCluster, Path, str]:
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "WD-vanilla-marker-9a2f-MUST-NOT-LEAK"
        cluster.execute(
            "CREATE TABLE wd_basic (id INT, payload TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_basic "
            f"SELECT g, '{marker}' || g::text FROM generate_series(1, 200) g"
        )
        seg = _flushed_segment(cluster)
        _assert_no_plaintext(seg, marker)
        return cluster, seg, marker

    def test_vanilla_pg_waldump_cannot_decode_encrypted_wal(
        self, pg_factory, tmp_path
    ):
        cluster, seg, _ = self._prepare(pg_factory, tmp_path)
        vanilla = _run_waldump(cluster, [str(seg)], binary="pg_waldump")
        tde = _run_waldump(cluster, [str(seg)])

        # If vanilla pg_waldump exits non-zero on the encrypted segment that's
        # the textbook case ("throws error on encrypted WAL"). Nothing more to
        # assert.
        if vanilla.returncode != 0:
            return

        # Otherwise: it ran to "EOF tail" without erroring — but it MUST have
        # decoded strictly fewer records than pg_tde_waldump -k did. Identical
        # counts would mean the WAL isn't really encrypted (or the wrapper
        # adds nothing).
        v_records = _decoded_record_count(vanilla.stdout)
        t_records = _decoded_record_count(tde.stdout)
        assert v_records < t_records, (
            f"vanilla pg_waldump produced {v_records} records, "
            f"pg_tde_waldump -k produced {t_records}; expected vanilla to "
            "produce *fewer* records on encrypted WAL."
        )

    def test_pg_tde_waldump_no_keyring_does_not_fatal_on_encrypted_wal(
        self, pg_factory, tmp_path
    ):
        cluster, seg, _ = self._prepare(pg_factory, tmp_path)
        result = _run_waldump(
            cluster, [str(seg)], binary="pg_tde_waldump", with_keyring=False
        )
        # Per the wrapper's --help: without -k it "will not try to decrypt
        # WAL". So it must NOT hard-fail on encryption; only EOF-tail exits
        # are acceptable. We do NOT pin a record count here because exactly
        # which rmgrs pg_tde encrypts (whole stream vs only sensitive
        # records) is an internal detail that has shifted between releases.
        _assert_ok_or_eof_tail(
            result, descr="pg_tde_waldump (no -k) on encrypted seg"
        )
        # And it must strictly produce fewer records than the same binary
        # *with* -k — that's what proves the wrapper is honouring the
        # "skip encrypted" mode rather than secretly using a stashed key.
        with_key = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(with_key, descr="pg_tde_waldump -k seg")
        assert _decoded_record_count(result.stdout) < _decoded_record_count(
            with_key.stdout
        ), (
            "pg_tde_waldump without -k decoded the same number of records "
            "as with -k — the wrapper appears to be decrypting without a "
            "keyring path, which contradicts the documented contract."
        )

    def test_pg_tde_waldump_with_keyring_decodes_encrypted_wal(
        self, pg_factory, tmp_path
    ):
        cluster, seg, _ = self._prepare(pg_factory, tmp_path)
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="pg_tde_waldump -k seg")
        rmgrs = _decoded_rmgrs(result.stdout)
        assert "Heap" in rmgrs or "Heap2" in rmgrs, (
            "pg_tde_waldump -k did not produce any Heap records on the "
            f"encrypted segment.\nrmgrs seen: {rmgrs}\n"
            f"stdout head:\n{result.stdout[:1500]}"
        )
        assert _decoded_record_count(result.stdout) >= 10


# ── data types in encrypted WAL ──────────────────────────────────────────────


class TestPgTdeWaldumpDataTypes:
    """
    For each common type-family: write rows to a ``tde_heap`` table, switch
    WAL to flush a segment, then run ``pg_tde_waldump -k``. The decoded
    output must show Heap records and the raw segment must not contain the
    plaintext marker — together this proves the data was actually encrypted
    AND that the wrapper decrypted it.
    """

    def _verify(self, cluster: PgCluster, seg: Path, marker: str) -> None:
        _assert_no_plaintext(seg, marker)
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr=f"pg_tde_waldump {seg.name}")
        rmgrs = _decoded_rmgrs(result.stdout)
        assert ({"Heap"} & rmgrs) or ({"Heap2"} & rmgrs), (
            f"no Heap/Heap2 records decoded; rmgrs={rmgrs}\n"
            f"stdout head:\n{result.stdout[:1500]}"
        )

    def test_text_jsonb_bytea(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "type-text-jsonb-bytea-marker-7e"
        cluster.execute(
            "CREATE TABLE wd_mix (id INT, t TEXT, j JSONB, b BYTEA) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_mix SELECT "
            f"  g, '{marker}-' || g, "
            f"  jsonb_build_object('m', '{marker}', 'n', g), "
            f"  decode(md5('{marker}-' || g), 'hex') "
            "FROM generate_series(1, 150) g"
        )
        self._verify(cluster, _flushed_segment(cluster), marker)

    def test_numeric_array_timestamp_uuid(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "type-numeric-array-uuid-marker-22b"
        cluster.execute(
            "CREATE TABLE wd_num (id INT, n NUMERIC(20,4), arr INT[], "
            "ts TIMESTAMPTZ, u UUID, lbl TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_num SELECT "
            "  g, (g * 1.000001)::NUMERIC(20,4), "
            "  ARRAY[g, g+1, g+2], "
            "  now() + (g || ' seconds')::interval, "
            "  gen_random_uuid(), "
            f"  '{marker}-' || g "
            "FROM generate_series(1, 150) g"
        )
        self._verify(cluster, _flushed_segment(cluster), marker)

    def test_geometric_range_inet_xml(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "type-geom-range-xml-marker-44c"
        cluster.execute(
            "CREATE TABLE wd_geo (id INT, p POINT, b BOX, r INT4RANGE, "
            "ip INET, x XML, lbl TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_geo SELECT "
            "  g, POINT(g, g+1), BOX(POINT(0,0), POINT(g,g)), "
            "  int4range(g, g+10), "
            "  ('192.0.2.' || (g % 250 + 1))::inet, "
            f"  XMLPARSE(CONTENT '<r>' || '{marker}-' || g::text || '</r>'), "
            f"  '{marker}-' || g "
            "FROM generate_series(1, 150) g"
        )
        self._verify(cluster, _flushed_segment(cluster), marker)

    def test_tsvector_and_hstore_like(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "type-tsv-marker-77d"
        cluster.execute(
            "CREATE TABLE wd_tsv (id INT, doc TSVECTOR, tags TEXT[], lbl TEXT) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_tsv SELECT "
            f"  g, to_tsvector('english', '{marker} payload ' || g::text), "
            f"  ARRAY['{marker}', 'tag-' || g::text], "
            f"  '{marker}-' || g "
            "FROM generate_series(1, 120) g"
        )
        self._verify(cluster, _flushed_segment(cluster), marker)

    def test_toasted_wide_rows(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "type-toast-marker-95e-must-not-leak"
        cluster.execute(
            "CREATE TABLE wd_toast (id INT, payload TEXT) USING tde_heap"
        )
        # STORAGE EXTERNAL disables compression so the marker is verifiably
        # detectable in raw bytes if encryption were broken.
        cluster.execute(
            "ALTER TABLE wd_toast ALTER COLUMN payload SET STORAGE EXTERNAL"
        )
        cluster.execute(
            "INSERT INTO wd_toast "
            f"SELECT g, repeat('{marker}-', 400) FROM generate_series(1, 30) g"
        )
        self._verify(cluster, _flushed_segment(cluster), marker)


# ── different relation kinds ────────────────────────────────────────────────


class TestPgTdeWaldumpRelationKinds:
    """
    Exercise pg_tde_waldump across non-trivial relation kinds (partitions,
    indexes, multi-database, mixed access methods, materialized views) so the
    decoder is verified against the rmgrs each kind produces.
    """

    def test_partitioned_table_decoded(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "rel-partition-marker-cc8"
        cluster.execute(
            "CREATE TABLE wd_sales (id INT, region TEXT, lbl TEXT) "
            "PARTITION BY LIST (region); "
            "CREATE TABLE wd_sales_e PARTITION OF wd_sales "
            "  FOR VALUES IN ('east') USING tde_heap; "
            "CREATE TABLE wd_sales_w PARTITION OF wd_sales "
            "  FOR VALUES IN ('west') USING tde_heap;"
        )
        cluster.execute(
            "INSERT INTO wd_sales SELECT "
            "  g, CASE g % 2 WHEN 0 THEN 'east' ELSE 'west' END, "
            f"  '{marker}-' || g "
            "FROM generate_series(1, 200) g"
        )
        seg = _flushed_segment(cluster)
        _assert_no_plaintext(seg, marker)
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="partition seg")
        assert "Heap" in _decoded_rmgrs(result.stdout)

    def test_indexed_table_emits_index_rmgrs(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "rel-index-marker-ad9"
        cluster.execute(
            "CREATE TABLE wd_idx (id INT, txt TEXT, arr INT[], n INT) "
            "USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO wd_idx "
            f"SELECT g, '{marker}-' || g, ARRAY[g, g+1], (g % 1000) "
            "FROM generate_series(1, 800) g"
        )
        cluster.execute(
            "CREATE INDEX wd_idx_btree ON wd_idx USING btree (id); "
            "CREATE INDEX wd_idx_hash  ON wd_idx USING hash  (txt); "
            "CREATE INDEX wd_idx_gin   ON wd_idx USING gin   (arr); "
            "CREATE INDEX wd_idx_brin  ON wd_idx USING brin  (n);"
        )
        seg = _flushed_segment(cluster)
        _assert_no_plaintext(seg, marker)
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="indexed-rel seg")
        rmgrs = _decoded_rmgrs(result.stdout)
        assert "Heap" in rmgrs, f"no Heap rmgr; got {rmgrs}"
        # CREATE INDEX records may straddle several segments; require at
        # least ONE index AM rmgr in this segment.
        index_rmgrs = {"Btree", "Hash", "Gin", "Brin"} & rmgrs
        assert index_rmgrs, (
            "pg_tde_waldump decoded no index AM rmgrs after CREATE INDEX "
            f"bursts; got {rmgrs}\nstdout head:\n{result.stdout[:1500]}"
        )

    def test_mixed_tde_heap_and_plain_heap(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "rel-mixed-marker-fe1"
        cluster.execute(
            "CREATE TABLE wd_plain (id INT, lbl TEXT) USING heap; "
            "CREATE TABLE wd_enc   (id INT, lbl TEXT) USING tde_heap; "
            f"INSERT INTO wd_plain SELECT g, 'PLAIN-{marker}-' || g "
            "FROM generate_series(1, 100) g; "
            f"INSERT INTO wd_enc   SELECT g, 'ENC-{marker}-' || g "
            "FROM generate_series(1, 100) g;"
        )
        seg = _flushed_segment(cluster)
        on_disk = seg.read_bytes()
        # IMPORTANT — pg_tde.wal_encrypt encrypts the WHOLE WAL stream, not
        # just records from tde_heap relations. So neither plain nor encrypted
        # heap row markers may leak on disk.
        assert b"PLAIN-" + marker.encode() not in on_disk, (
            "plain heap row plaintext leaked: WAL encryption should wrap "
            "the entire stream, not only tde_heap records."
        )
        assert b"ENC-" + marker.encode() not in on_disk
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="mixed seg")
        assert _decoded_record_count(result.stdout) >= 20

    def test_multiple_databases_with_tde(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "rel-multidb-marker-22a"
        # Both databases reuse the existing global key provider; for the
        # second DB we only set a per-database key so the server key (set in
        # _start_tde_cluster_with_wal_encryption) is left alone.
        cluster.execute("CREATE DATABASE wd_db2")
        cluster.execute("CREATE EXTENSION pg_tde", dbname="wd_db2")
        cluster.execute(
            "SELECT pg_tde_create_key_using_global_key_provider("
            "'wd_db2_key', 'file_provider')",
            dbname="wd_db2",
        )
        cluster.execute(
            "SELECT pg_tde_set_key_using_global_key_provider("
            "'wd_db2_key', 'file_provider')",
            dbname="wd_db2",
        )
        for db in ("postgres", "wd_db2"):
            cluster.execute(
                "CREATE TABLE wd_dbtest (id INT, lbl TEXT) USING tde_heap; "
                "INSERT INTO wd_dbtest "
                f"SELECT g, '{marker}-{db}-' || g "
                "FROM generate_series(1, 80) g",
                dbname=db,
            )
        seg = _flushed_segment(cluster)
        on_disk = seg.read_bytes()
        for db in ("postgres", "wd_db2"):
            assert f"{marker}-{db}-".encode() not in on_disk, (
                f"plaintext from db={db} leaked into encrypted WAL"
            )
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="multidb seg")
        assert _decoded_record_count(result.stdout) >= 10

    def test_materialized_view_refresh_logs_wal(self, pg_factory, tmp_path):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "rel-matview-marker-9b3"
        cluster.execute(
            "CREATE TABLE wd_base (id INT, lbl TEXT) USING tde_heap; "
            f"INSERT INTO wd_base SELECT g, '{marker}-' || g "
            "FROM generate_series(1, 200) g; "
            "CREATE MATERIALIZED VIEW wd_mv AS "
            "  SELECT id, lbl FROM wd_base WHERE id % 2 = 0; "
            "REFRESH MATERIALIZED VIEW wd_mv;"
        )
        seg = _flushed_segment(cluster)
        _assert_no_plaintext(seg, marker)
        result = _run_waldump(cluster, [str(seg)])
        _assert_ok_or_eof_tail(result, descr="matview seg")
        assert _decoded_record_count(result.stdout) >= 5


# ── CLI filter / option switches ────────────────────────────────────────────


class TestPgTdeWaldumpFilters:
    """
    Cover every pg_tde_waldump filter switch with the same controlled
    workload, so we can make precise per-flag assertions.
    """

    def _build(
        self, pg_factory, tmp_path
    ) -> Tuple[PgCluster, Path, str, str, str, str]:
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        marker = "filter-marker-d3"
        cluster.execute(
            "CREATE TABLE wd_filter_a (id INT, lbl TEXT) USING tde_heap; "
            "CREATE TABLE wd_filter_b (id INT, lbl TEXT) USING tde_heap;"
        )
        start_lsn = _lsn_now(cluster)
        # Anchor INSERT — capture its XID for the --xid test.
        xid = cluster.fetchone(
            "INSERT INTO wd_filter_a VALUES (-1, 'xid-anchor') RETURNING xmin"
        )
        cluster.execute(
            f"INSERT INTO wd_filter_a SELECT g, '{marker}-A-' || g "
            "FROM generate_series(1, 200) g"
        )
        cluster.execute(
            f"INSERT INTO wd_filter_b SELECT g, '{marker}-B-' || g "
            "FROM generate_series(1, 200) g"
        )
        cluster.execute(
            "CREATE INDEX wd_filter_a_idx ON wd_filter_a (id); "
            "CREATE INDEX wd_filter_b_idx ON wd_filter_b (id);"
        )
        end_lsn = _lsn_now(cluster)
        seg = _flushed_segment(cluster)
        _assert_no_plaintext(seg, marker)
        return cluster, seg, marker, start_lsn, end_lsn, xid

    def test_rmgr_filter_heap_only(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-r", "Heap", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--rmgr=Heap")
        rmgrs = _decoded_rmgrs(result.stdout)
        non_heap = rmgrs - {"Heap"}
        assert not non_heap, (
            f"--rmgr=Heap leaked other rmgrs: {non_heap}\n"
            f"stdout head:\n{result.stdout[:1500]}"
        )
        assert "Heap" in rmgrs, "--rmgr=Heap returned zero Heap records"

    def test_relation_filter(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        tdr = _relation_filter(cluster, "wd_filter_a")
        assert tdr.count("/") == 2, f"unexpected relation locator {tdr!r}"
        result = _run_waldump(cluster, ["-R", tdr, str(seg)])
        _assert_ok_or_eof_tail(result, descr=f"--relation={tdr}")
        # Every "blkref ... rel T/D/R ..." line must reference the chosen
        # relation. Lines without rel references are fine.
        for line in result.stdout.splitlines():
            if "blkref" in line and " rel " in line:
                assert tdr in line, (
                    f"--relation filter leak — line refers to a different "
                    f"relation than {tdr}:\n{line}"
                )

    def test_xid_filter(self, pg_factory, tmp_path):
        cluster, seg, _, _, _, xid = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-x", xid, str(seg)])
        _assert_ok_or_eof_tail(result, descr=f"--xid={xid}")
        bad = []
        for line in result.stdout.splitlines():
            if line.startswith("rmgr:") and "tx:" in line:
                got = line.split("tx:", 1)[1].split(",", 1)[0].strip()
                if got != xid:
                    bad.append((got, line))
        assert not bad, (
            f"--xid={xid} returned records for other XIDs (first 3): {bad[:3]}"
        )

    def test_lsn_range(self, pg_factory, tmp_path):
        cluster, _, _, start_lsn, end_lsn, _ = self._build(pg_factory, tmp_path)
        # Point pg_tde_waldump at the whole pg_wal directory and bound it
        # with -s/-e LSNs (the flushed segment lives there).
        result = _run_waldump(
            cluster,
            ["-p", str(cluster.data_dir / "pg_wal"),
             "-s", start_lsn, "-e", end_lsn],
        )
        _assert_ok_or_eof_tail(result, descr="-s/-e LSN range")
        records = [
            l for l in result.stdout.splitlines() if l.startswith("rmgr:")
        ]
        assert records, (
            f"LSN range [{start_lsn}, {end_lsn}] decoded zero records.\n"
            f"stderr:\n{result.stderr}"
        )

    def test_limit_records(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-n", "10", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--limit=10")
        records = [
            l for l in result.stdout.splitlines() if l.startswith("rmgr:")
        ]
        assert len(records) == 10, (
            f"--limit=10 returned {len(records)} records, expected 10.\n"
            + "\n".join(records[:5])
        )

    def test_stats_mode(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-z", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--stats")
        out = result.stdout
        # --stats prints a summary table; "Type" + one of "Record size" /
        # "Records" must appear, and per-record "rmgr:" lines must NOT.
        assert "Type" in out and ("Record size" in out or "Records" in out), (
            "--stats output does not look like a stats table:\n" + out[:1500]
        )
        assert "rmgr: " not in out, (
            "--stats mode unexpectedly emitted per-record lines"
        )

    def test_stats_per_record(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["--stats=record", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--stats=record")
        # Per-record stats break Heap down by op (INSERT, UPDATE, DELETE…).
        assert "INSERT" in result.stdout.upper(), (
            "--stats=record output does not mention INSERT — workload should "
            "have produced INSERT records.\n" + result.stdout[:1500]
        )

    def test_quiet_flag(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-q", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--quiet")
        assert "rmgr:" not in result.stdout, (
            "--quiet still printed records:\n" + result.stdout[:500]
        )

    def test_bkp_details(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-b", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--bkp-details")
        assert "blkref" in result.stdout, (
            "--bkp-details did not print any blkref lines:\n"
            + result.stdout[:1500]
        )
        assert _decoded_record_count(result.stdout) >= 5

    def test_fork_filter_main_only(self, pg_factory, tmp_path):
        cluster, seg, *_ = self._build(pg_factory, tmp_path)
        result = _run_waldump(cluster, ["-F", "main", str(seg)])
        _assert_ok_or_eof_tail(result, descr="--fork=main")
        # Every blkref line in --fork=main output must reference the main
        # fork; pg_waldump prints "fork fsm" / "fork vm" / "fork init" for
        # non-main forks.
        for line in result.stdout.splitlines():
            if "blkref" in line:
                for non_main in (" fsm ", " vm ", " init "):
                    assert non_main not in line, (
                        f"--fork=main returned a non-main blkref: {line}"
                    )

    def test_save_fullpage_extracts_decrypted_images(
        self, pg_factory, tmp_path
    ):
        cluster = _start_tde_cluster_with_wal_encryption(
            pg_factory, tmp_path, name="wd_fpi"
        )
        marker = "fpi-marker-7d"
        cluster.execute(
            "CREATE TABLE wd_fpi (id INT, payload TEXT) USING tde_heap; "
            f"INSERT INTO wd_fpi SELECT g, '{marker}-' || g "
            "FROM generate_series(1, 400) g;"
        )
        # CHECKPOINT + UPDATE forces full-page images on the next writes.
        cluster.execute("CHECKPOINT")
        cluster.execute(
            "UPDATE wd_fpi SET payload = payload || '-upd' WHERE id <= 60"
        )
        seg = _flushed_segment(cluster)

        save_dir = tmp_path / "fpi_saved"
        save_dir.mkdir()
        result = _run_waldump(
            cluster, [f"--save-fullpage={save_dir}", str(seg)]
        )
        _assert_ok_or_eof_tail(result, descr="--save-fullpage")

        files = sorted(p for p in save_dir.iterdir() if p.is_file())
        assert files, (
            "--save-fullpage produced no files; expected FPIs after "
            "CHECKPOINT + UPDATE.\nstderr:\n" + result.stderr
        )
        # The saved page images are the *decrypted* page bodies — the
        # plaintext marker must appear in at least one of them, proving the
        # wrapper decrypted before saving.
        joined = b"".join(p.read_bytes() for p in files)
        assert marker.encode() in joined, (
            "saved FPI files do not contain the plaintext marker — the "
            "wrapper may not have decrypted the page bodies before saving."
        )


# ── plaintext WAL (no wal_encrypt) ───────────────────────────────────────────


class TestPgTdeWaldumpPlaintextWal:
    """
    Plaintext WAL (no ``pg_tde.wal_encrypt``): both pg_tde_waldump and
    upstream pg_waldump must decode fully. ``-k`` is irrelevant here.
    """

    def _setup(self, pg_factory) -> Tuple[PgCluster, Path]:
        cluster = _start_plaintext_cluster(pg_factory)
        cluster.execute(
            "CREATE TABLE wd_plain (id INT, lbl TEXT); "
            "INSERT INTO wd_plain SELECT g, 'plain-' || g "
            "FROM generate_series(1, 200) g;"
        )
        return cluster, _flushed_segment(cluster)

    def test_pg_tde_waldump_on_plaintext_wal_without_keyring(
        self, pg_factory, tmp_path
    ):
        cluster, seg = self._setup(pg_factory)
        result = _run_waldump(
            cluster, [str(seg)], binary="pg_tde_waldump", with_keyring=False
        )
        _assert_ok_or_eof_tail(result, descr="pg_tde_waldump plaintext")
        assert "Heap" in _decoded_rmgrs(result.stdout)

    def test_pg_waldump_on_plaintext_wal(self, pg_factory, tmp_path):
        cluster, seg = self._setup(pg_factory)
        result = _run_waldump(cluster, [str(seg)], binary="pg_waldump")
        _assert_ok_or_eof_tail(result, descr="pg_waldump plaintext")
        assert "Heap" in _decoded_rmgrs(result.stdout)


# ── pg_tde custom resource manager registration ─────────────────────────────


class TestPgTdeWaldumpCustomRmgrRegistered:
    """
    pg_tde registers a custom WAL resource manager (ID 140) at postmaster
    startup. pg_tde_waldump depends on that registration to decode encrypted
    records; verify it shows up in the server log.

    Note: ``pg_waldump --rmgr=list`` lists only *built-in* rmgrs, not custom
    ones registered by extensions, so it can't be used to prove this.
    """

    def test_pg_tde_registers_custom_resource_manager(
        self, pg_factory, tmp_path
    ):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        cluster.execute("CREATE TABLE t (id INT) USING tde_heap")
        cluster.execute("INSERT INTO t SELECT generate_series(1, 50)")
        server_log = cluster.read_log(last_n=500)
        assert "custom resource manager" in server_log.lower(), (
            "Server log does not mention any custom resource manager — "
            "pg_tde may have failed to load.\nLog tail:\n" + server_log[-2000:]
        )
        assert "pg_tde" in server_log, (
            "Server log mentions a custom resource manager but not pg_tde "
            "specifically — the rmgr name may have changed.\nLog tail:\n"
            + server_log[-2000:]
        )
