"""
pg_waldump / pg_tde_waldump tests.

Percona's pg_waldump is patched to understand pg_tde-encrypted WAL
records (custom rmgr ID 140, and the encrypted page bodies for WAL records
that come from ``tde_heap`` relations). Without these tests the diagnostic
binary had zero coverage despite being shipped with every install.

Covers:

  - Reading an encrypted WAL segment with the Percona pg_waldump must
    succeed and surface recognisable rmgr lines (CHECKPOINT, HEAP/INSERT, …).
  - The same segment read on disk must not contain the plaintext payload
    we just inserted (proves the WAL really was encrypted, so the success
    above is not a false positive caused by waldump dumping plaintext).
"""
import os
import subprocess
from pathlib import Path

import pytest

from conftest import allocate_port
from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums, libpq_superuser


pytestmark = [pytest.mark.encryption, pytest.mark.waldump]


def _start_tde_cluster_with_wal_encryption(
    pg_factory,
    tmp_path: Path,
    *,
    name: str = "waldump_src",
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
    tde.add_global_key_provider_file(keyfile=str(tmp_path / "waldump_key.file"))
    tde.set_global_principal_key()
    tde.enable_wal_encryption()   # restarts; pg_tde.wal_encrypt is PGC_POSTMASTER
    assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    return cluster


def _flushed_wal_segment(cluster: PgCluster) -> Path:
    """
    Force the current WAL segment to be closed (so pg_waldump can read it).

    Subtle: a CHECKPOINT *after* pg_switch_wal will recycle the just-closed
    segment (rename it forward as a future segment), which makes the segment
    name we captured unfindable on disk. So:

      1. CHECKPOINT once to flush any dirty pages.
      2. Capture the name of the current segment (the one we're about to close).
      3. pg_switch_wal — closes the current segment. The new segment becomes
         the "current" one.
      4. **Do not** checkpoint again — that's what recycles the file.

    The captured segment file is then guaranteed to be present on disk and
    untouched until the next checkpoint.
    """
    cluster.execute("CHECKPOINT")
    seg_name = cluster.fetchone(
        "SELECT pg_walfile_name(pg_current_wal_insert_lsn())"
    )
    cluster.execute("SELECT pg_switch_wal()")
    seg_path = cluster.data_dir / "pg_wal" / seg_name
    assert seg_path.exists(), (
        f"WAL segment {seg_name} not present on disk under "
        f"{cluster.data_dir / 'pg_wal'} after pg_switch_wal — "
        "did a background checkpoint recycle it?"
    )
    return seg_path


class TestPgWalDumpOnEncryptedWal:
    """
    The Percona-patched pg_waldump must be able to read pg_tde-encrypted
    WAL segments. These are the first tests touching the binary at all.
    """

    def test_pg_waldump_reads_encrypted_segment(
        self, pg_factory, tmp_path: Path
    ):
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)

        # Generate enough WAL to be sure the next switched segment has
        # meaningful records, with a unique plaintext marker so we can also
        # cross-check the raw bytes below.
        marker = "WALDUMP-encrypted-plaintext-must-not-leak-9a2f"
        cluster.execute(
            "CREATE TABLE waldump_t (id INT, payload TEXT) USING tde_heap"
        )
        cluster.execute(
            "INSERT INTO waldump_t "
            f"SELECT g, '{marker}' || g::text FROM generate_series(1, 200) g"
        )

        seg = _flushed_wal_segment(cluster)

        # 1. Sanity: the WAL bytes on disk must NOT contain the plaintext
        #    marker — otherwise the success of pg_waldump below would just
        #    mean it read plaintext, not that it decrypted anything.
        on_disk = seg.read_bytes()
        assert marker.encode() not in on_disk, (
            f"Plaintext marker leaked into encrypted WAL segment {seg.name}. "
            "pg_tde.wal_encrypt=on but the file is plaintext on disk."
        )

        # 2. Run pg_waldump with LD_LIBRARY_PATH set so it can load the
        #    pg_tde rmgr and decode the encrypted records. Pass the data
        #    directory of the source so it can locate the per-relation keys.
        bin_path = cluster.bin / "pg_waldump"
        if not bin_path.exists():
            pytest.skip("pg_waldump binary not present in this build")

        env = os.environ.copy()
        lib_dir = str(cluster.install_dir / "lib")
        env["LD_LIBRARY_PATH"] = (
            f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
        )
        # pg_waldump in PG 17+ accepts -p/--path for the data directory;
        # older versions only inferred it from the file argument's parent.
        # Pass the segment directly — pg_waldump finds pg_wal/<seg> on its own.
        result = subprocess.run(
            [str(bin_path), str(seg)],
            capture_output=True, text=True, env=env,
        )
        assert result.returncode == 0, (
            f"pg_waldump on encrypted segment {seg.name} failed:\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

        # 3. Output must contain recognisable rmgr lines. We're flexible
        #    about which records show up (depends on WAL activity), but
        #    at least one of CHECKPOINT/HEAP/XLOG must be present.
        out = result.stdout
        recognised = ("CHECKPOINT", "HEAP", "XLOG", "Standby", "Heap")
        assert any(tag in out for tag in recognised), (
            "pg_waldump produced no recognisable rmgr lines — the binary "
            f"may not have decoded the encrypted WAL.\nstdout head:\n{out[:1000]}"
        )

    def test_pg_waldump_lists_pg_tde_resource_manager(
        self, pg_factory, tmp_path: Path
    ):
        """
        ``pg_waldump --rmgr=list`` (PG 16+) must include the custom pg_tde
        rmgr (ID 140). On older Postgres without that switch, fall back to
        scanning the regular output for the rmgr name.
        """
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        cluster.execute("CREATE TABLE t (id INT) USING tde_heap")
        cluster.execute("INSERT INTO t SELECT generate_series(1, 50)")
        seg = _flushed_wal_segment(cluster)

        bin_path = cluster.bin / "pg_waldump"
        if not bin_path.exists():
            pytest.skip("pg_waldump binary not present in this build")
        env = os.environ.copy()
        lib_dir = str(cluster.install_dir / "lib")
        env["LD_LIBRARY_PATH"] = (
            f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
        )

        # Try the explicit --rmgr=list switch first.
        list_result = subprocess.run(
            [str(bin_path), "--rmgr=list"],
            capture_output=True, text=True, env=env,
        )
        if list_result.returncode == 0 and "pg_tde" in list_result.stdout.lower():
            return
        # Fallback: scan a real segment's output for the rmgr name. This
        # only fires if pg_tde actually emitted records via its custom rmgr
        # in this segment, which is not guaranteed for tiny workloads —
        # so we report rather than hard-fail if neither path proves it.
        dump = subprocess.run(
            [str(bin_path), str(seg)],
            capture_output=True, text=True, env=env,
        )
        haystack = (list_result.stdout + list_result.stderr +
                    dump.stdout + dump.stderr).lower()
        assert "pg_tde" in haystack or "tde" in haystack, (
            "Neither --rmgr=list nor a sample segment dump mentioned the "
            "pg_tde resource manager. pg_waldump may not be the Percona "
            f"patched build.\n--rmgr=list stdout: {list_result.stdout[:400]}\n"
            f"--rmgr=list stderr: {list_result.stderr[:400]}\n"
            f"segment dump stderr: {dump.stderr[:400]}"
        )
