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

    # pg_waldump returns non-zero when it reaches the zero-padded tail of a
    # switched WAL segment ("invalid magic number ... in WAL segment ... LSN
    # X/YYY"). That's not a failure — it's how the tool signals "no more
    # records here." So we don't gate on the exit code; we check the
    # *content* it produced before bailing.
    _EOF_TAIL_STDERR_PHRASES = (
        "invalid magic number",
        "could not find a valid record",
        "out-of-sequence timeline ID",
    )

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
        #    pg_tde rmgr and decode the encrypted records.
        bin_path = cluster.bin / "pg_waldump"
        if not bin_path.exists():
            pytest.skip("pg_waldump binary not present in this build")

        env = os.environ.copy()
        lib_dir = str(cluster.install_dir / "lib")
        env["LD_LIBRARY_PATH"] = (
            f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
        )
        result = subprocess.run(
            [str(bin_path), str(seg)],
            capture_output=True, text=True, env=env,
        )

        # 3. The non-zero exit code is acceptable IF the stderr is just the
        #    "end of records in this segment" tail message. Any other
        #    non-zero exit is a real decode failure.
        if result.returncode != 0:
            stderr_lower = result.stderr.lower()
            is_eof_only = any(
                p in stderr_lower for p in self._EOF_TAIL_STDERR_PHRASES
            )
            assert is_eof_only, (
                f"pg_waldump on encrypted segment {seg.name} failed with "
                f"an error that's not the end-of-WAL tail.\n"
                f"stderr: {result.stderr}\n"
                f"stdout (head): {result.stdout[:600]}"
            )

        # 4. The decoded output must contain real rmgr lines — that's what
        #    proves pg_waldump actually decrypted the segment and walked
        #    records, rather than failing immediately on the encrypted bytes.
        out = result.stdout
        recognised = ("CHECKPOINT", "HEAP", "XLOG", "Standby", "Heap", "Btree")
        decoded_record_count = sum(out.count(tag) for tag in recognised)
        assert decoded_record_count >= 5, (
            "pg_waldump produced fewer than 5 decoded rmgr lines — the "
            "binary may not have decoded the encrypted WAL.\n"
            f"stdout head:\n{out[:1500]}\nstderr:\n{result.stderr[:500]}"
        )

    def test_pg_tde_registers_custom_resource_manager(
        self, pg_factory, tmp_path: Path
    ):
        """
        pg_tde registers a custom WAL resource manager (ID 140) at startup.
        Verify the registration log line appears in the server log — this is
        the underlying invariant pg_waldump depends on to decode pg_tde WAL
        records.

        Note: ``pg_waldump --rmgr=list`` only lists *built-in* rmgrs, not
        custom ones registered by extensions at backend startup. So that
        switch can't be used to prove the pg_tde rmgr exists; the server
        log is the authoritative source.
        """
        cluster = _start_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        # Generate some WAL so the rmgr would actually be exercised.
        cluster.execute("CREATE TABLE t (id INT) USING tde_heap")
        cluster.execute("INSERT INTO t SELECT generate_series(1, 50)")

        # The "registered custom resource manager 'pg_tde' with ID 140" log
        # line is emitted at postmaster startup; cluster.read_log fetches it.
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
