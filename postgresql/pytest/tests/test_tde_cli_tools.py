"""
Direct CLI coverage for the pg_tde wrapper binaries:

  * ``pg_tde_checksums``        — TDE-aware ``pg_checksums``: decrypts
                                  ``tde_heap`` pages and validates checksums
                                  (PG-2399); plain ``heap`` pages use the
                                  standard algorithm unchanged.
  * ``pg_tde_resetwal``         — TDE-aware ``pg_resetwal``: rewrites pg_control
                                  / clears pg_wal on a cluster with WAL
                                  encryption enabled; the cluster must come
                                  back up and the encrypted relations must
                                  still be readable.
  * ``pg_tde_archive_decrypt``  — WAL archive_command wrapper that decrypts
                                  the segment into the archive (so external
                                  tooling can read it).
  * ``pg_tde_restore_encrypt``  — restore_command counterpart: re-encrypts
                                  the segment on the way back into pg_wal/
                                  during recovery.

The other wrappers in this build —
``pg_tde_rewind``, ``pg_tde_upgrade``, ``pg_tde_waldump``, ``pg_tde_basebackup``
and ``pg_tde_change_key_provider`` — are covered deeply by their own files
(``test_tde_rewind_advanced.py``, ``test_tde_pg_upgrade.py``,
``test_waldump.py``, ``test_pg_basebackup.py``,
``test_change_key_provider.py``).

Ported from automation/tests/:
  - pg_tde_checksums_test.sh
  - pg_resetwal.sh / pg_resetwal_iteration.sh
  - pg_tde_restore_encrypt_using_archive_decrypt.sh
  - pitr_encrypted_wal.sh
"""
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Optional, Tuple

import pytest

from conftest import allocate_port
from lib import (
    PgCluster,
    TdeManager,
    archive_restore_conf_values,
    restore_conf_line_raw,
    wrappers_available,
)
from lib.cluster import initdb_args_no_data_checksums, initdb_io_method_args


pytestmark = [pytest.mark.encryption]


# ── shared helpers ────────────────────────────────────────────────────────────


def _env(install_dir: Path) -> dict:
    """Environment with LD_LIBRARY_PATH prefixed so the wrappers load libpq."""
    env = os.environ.copy()
    lib_dir = str(install_dir / "lib")
    env["LD_LIBRARY_PATH"] = (
        f"{lib_dir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    return env


def _bin_or_skip(install_dir: Path, name: str) -> Path:
    p = install_dir / "bin" / name
    if not p.is_file():
        pytest.skip(f"{name} not present at {p} — wrapper not in this build")
    return p


# ── pg_tde_checksums ──────────────────────────────────────────────────────────


def _checksum_initdb_args(install_dir: Path, io_method: str) -> list[str]:
    """Match ``pg_tde_checksums_test.sh``: ``initdb -k`` + pg_tde preload + io_method."""
    args = ["-k", "--set", "shared_preload_libraries=pg_tde"]
    args.extend(initdb_io_method_args(install_dir, io_method))
    return args


def _make_initdb_only_checksum_cluster(
    pg_factory, install_dir: Path, io_method: str
) -> PgCluster:
    """Fresh PGDATA with checksums on; extension not created (bash steps 1–3)."""
    cluster = pg_factory("tde_checksums_initdb")
    cluster.initdb(extra_args=_checksum_initdb_args(install_dir, io_method))
    return cluster


def _run_pg_checksums(
    install_dir: Path, *args: str
) -> subprocess.CompletedProcess:
    bin_path = install_dir / "bin" / "pg_checksums"
    if not bin_path.is_file():
        pytest.skip(f"pg_checksums not present at {bin_path}")
    return subprocess.run(
        [str(bin_path), *args],
        capture_output=True,
        text=True,
        env=_env(install_dir),
    )


def _build_tde_cluster_with_checksums(
    pg_factory,
    tmp_path: Path,
    *,
    io_method: str,
    wal_encrypt: bool = True,
) -> PgCluster:
    """
    Build a cluster with **data checksums enabled** (``initdb -k``) and
    pg_tde fully configured. The bash matrix runs against checksum-enabled
    clusters because that's the only configuration where ``pg_tde_checksums``
    has any pages to validate — with checksums off the binary returns 0
    immediately and there's nothing meaningful to assert.
    """
    cluster = pg_factory("tde_checksums")
    cluster.initdb(extra_args=_checksum_initdb_args(cluster.install_dir, io_method))
    cluster.write_default_config(extra_params={
        "shared_preload_libraries": "'pg_tde'",
        "default_table_access_method": "'tde_heap'",
    })
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(
        keyfile=str(tmp_path / "tde_checksums_keyring.per")
    )
    tde.set_global_principal_key("checksums_key")
    if wal_encrypt:
        tde.enable_wal_encryption()
    return cluster


def _corrupt_first_data_page(data_file: Path) -> None:
    """
    Overwrite 16 bytes past the page header in the first 8 KB block —
    enough to break the page's data checksum without truncating the file.
    """
    assert data_file.is_file(), f"data file not found: {data_file}"
    with data_file.open("r+b") as f:
        f.seek(100)
        f.write(os.urandom(16))


def _run_checksums(
    install_dir: Path, *args: str
) -> subprocess.CompletedProcess:
    bin_path = _bin_or_skip(install_dir, "pg_tde_checksums")
    return subprocess.run(
        [str(bin_path), *args],
        capture_output=True, text=True, env=_env(install_dir),
    )


def _table_path(cluster: PgCluster, table: str) -> Path:
    """Resolve $PGDATA/base/<db_oid>/<relfilenode> for a relation."""
    db_oid = cluster.fetchone(
        "SELECT oid FROM pg_database WHERE datname = current_database()"
    )
    relfilenode = cluster.fetchone(
        f"SELECT pg_relation_filenode('{table}')"
    )
    return cluster.data_dir / "base" / str(db_oid) / str(relfilenode)


class TestPgTdeChecksumsCLI:
    """
    ``pg_tde_checksums`` is the TDE-aware counterpart to ``pg_checksums``:
    for ``tde_heap`` relations it decrypts each page, then validates or
    enables the standard PostgreSQL page checksum (PG-2399, parity with
    ``pg_tde/t/pg_tde_checksums.pl``).  Plain ``heap`` relations are handled
    like upstream ``pg_checksums``.

    Parity with ``pg_tde_checksums_test.sh`` (updated for PG-2399):

    * Pre-extension ``pg_checksums`` / ``pg_tde_checksums`` on stopped PGDATA
    * Combined verify with ``tde_heap`` + ``heap`` before corruption
    * Encrypted and plain corruption both reported as checksum failures
    """

    def test_binary_exists(self, install_dir: Path):
        """All other tests assume the wrapper is present in this build."""
        bin_path = install_dir / "bin" / "pg_tde_checksums"
        assert bin_path.is_file(), (
            f"pg_tde_checksums not found at {bin_path}; this build does not "
            "ship the wrapper."
        )

    def test_fresh_initdb_pg_checksums_before_extension(
        self, pg_factory, install_dir: Path, io_method: str
    ):
        """Bash step 2: healthy initdb cluster passes vanilla ``pg_checksums -c``."""
        cluster = _make_initdb_only_checksum_cluster(
            pg_factory, install_dir, io_method
        )
        result = _run_pg_checksums(install_dir, "-c", "-D", str(cluster.data_dir))
        assert result.returncode == 0, (
            "pg_checksums failed on a fresh checksum-enabled cluster "
            "without pg_tde extension:\n"
            f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
        )

    def test_fresh_initdb_pg_tde_checksums_before_extension(
        self, pg_factory, install_dir: Path, io_method: str
    ):
        """Bash step 3: same PGDATA passes ``pg_tde_checksums -c`` before CREATE EXTENSION."""
        _bin_or_skip(install_dir, "pg_tde_checksums")
        cluster = _make_initdb_only_checksum_cluster(
            pg_factory, install_dir, io_method
        )
        result = _run_checksums(install_dir, "-c", "-D", str(cluster.data_dir))
        assert result.returncode == 0, (
            "pg_tde_checksums failed on a fresh cluster without encryption:\n"
            f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
        )

    def test_verify_encrypted_and_plain_tables_before_corruption(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """Bash step 7: both ``tde_heap`` and ``heap`` relations pass verify before corruption."""
        cluster = _build_tde_cluster_with_checksums(
            pg_factory, tmp_path, io_method=io_method
        )
        try:
            cluster.execute(
                "CREATE TABLE test (id INT, val TEXT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO test VALUES (1, 'before corruption')"
            )
            cluster.execute(
                "CREATE TABLE test1 (id INT, val TEXT) USING heap"
            )
            cluster.execute(
                "INSERT INTO test1 VALUES (1, 'before corruption')"
            )
            cluster.execute("CHECKPOINT")
            cluster.stop()

            result = _run_checksums(
                install_dir, "-c", "-D", str(cluster.data_dir)
            )
            assert result.returncode == 0, (
                "pg_tde_checksums failed before corruption with both table types:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        finally:
            cluster.stop(check=False)

    def test_clean_tde_cluster_passes(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """A freshly populated TDE cluster (no corruption) must pass verify."""
        cluster = _build_tde_cluster_with_checksums(
            pg_factory, tmp_path, io_method=io_method
        )
        try:
            cluster.execute(
                "CREATE TABLE chk_clean (id INT, val TEXT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO chk_clean SELECT g, md5(g::text) "
                "FROM generate_series(1, 1000) g"
            )
            cluster.execute("CHECKPOINT")
            cluster.stop()

            result = _run_checksums(
                install_dir, "-c", "-D", str(cluster.data_dir)
            )
            assert result.returncode == 0, (
                "pg_tde_checksums failed on a clean cluster:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        finally:
            cluster.stop(check=False)

    def test_detects_corruption_on_encrypted_relation(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Corrupting an encrypted ``tde_heap`` page must be reported as a
        checksum failure.

        Since PG-2399 ``pg_tde_checksums`` decrypts encrypted blocks and
        validates the logical page checksum (``pg_tde/t/pg_tde_checksums.pl``
        expects exit 1 here).  Older builds skipped encrypted relations
        entirely; that skip path was removed as unnecessary.
        """
        cluster = _build_tde_cluster_with_checksums(
            pg_factory, tmp_path, io_method=io_method
        )
        try:
            cluster.execute(
                "CREATE TABLE chk_enc (id INT, val TEXT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO chk_enc VALUES (1, 'before corruption')"
            )
            cluster.execute("CHECKPOINT")
            enc_path = _table_path(cluster, "chk_enc")
            cluster.stop()
            _corrupt_first_data_page(enc_path)

            result = _run_checksums(
                install_dir, "-c", "-D", str(cluster.data_dir)
            )
            assert result.returncode != 0, (
                "pg_tde_checksums must DETECT corruption on an encrypted "
                "tde_heap relation but exited 0.\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
            combined = (result.stdout + result.stderr).lower()
            assert "checksum verification failed" in combined or \
                "bad" in combined, (
                "pg_tde_checksums exited non-zero but the message did not "
                "mention checksum failure clearly.\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        finally:
            cluster.stop(check=False)

    def test_detects_corruption_on_plain_heap_relation(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        A plain ``heap`` relation in the same cluster *is* validated
        normally, and corruption to its first data page must cause
        ``pg_tde_checksums -c`` to exit non-zero.
        """
        cluster = _build_tde_cluster_with_checksums(
            pg_factory, tmp_path, io_method=io_method
        )
        try:
            cluster.execute(
                "CREATE TABLE chk_plain (id INT, val TEXT) USING heap"
            )
            cluster.execute(
                "INSERT INTO chk_plain VALUES (1, 'before corruption')"
            )
            cluster.execute("CHECKPOINT")
            plain_path = _table_path(cluster, "chk_plain")
            cluster.stop()
            _corrupt_first_data_page(plain_path)

            result = _run_checksums(
                install_dir, "-c", "-D", str(cluster.data_dir)
            )
            assert result.returncode != 0, (
                "pg_tde_checksums must DETECT corruption on a plain-heap "
                "relation but exited 0.\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
            combined = (result.stdout + result.stderr).lower()
            assert "checksum verification failed" in combined or \
                "bad" in combined or "mismatch" in combined, (
                "pg_tde_checksums exited non-zero but the message did not "
                "mention the failure clearly.\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        finally:
            cluster.stop(check=False)

    def test_passes_with_wal_encryption_disabled(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        ``pg_tde_checksums`` operates on relation files (``base/...``), not
        WAL — it must work the same with or without ``pg_tde.wal_encrypt``.
        Pin that explicitly so a future build doesn't accidentally couple
        the two.
        """
        cluster = _build_tde_cluster_with_checksums(
            pg_factory, tmp_path, io_method=io_method, wal_encrypt=False
        )
        try:
            cluster.execute(
                "CREATE TABLE chk_noWalEnc (id INT) USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO chk_noWalEnc SELECT generate_series(1, 100)"
            )
            cluster.execute("CHECKPOINT")
            cluster.stop()
            result = _run_checksums(
                install_dir, "-c", "-D", str(cluster.data_dir)
            )
            assert result.returncode == 0, (
                "pg_tde_checksums failed on a clean cluster with WAL "
                "encryption off:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        finally:
            cluster.stop(check=False)


# ── pg_tde_resetwal ───────────────────────────────────────────────────────────


def _run_pg_tde_resetwal(
    install_dir: Path, *args: str
) -> subprocess.CompletedProcess:
    bin_path = _bin_or_skip(install_dir, "pg_tde_resetwal")
    return subprocess.run(
        [str(bin_path), *args],
        capture_output=True, text=True, env=_env(install_dir),
    )


def _build_tde_cluster_with_wal_encryption(
    pg_factory, tmp_path: Path, *, name: str = "tde_resetwal"
) -> PgCluster:
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
    tde.add_global_key_provider_file(
        keyfile=str(tmp_path / f"{name}_keyring.per")
    )
    tde.set_global_principal_key(f"{name}_key")
    tde.enable_wal_encryption()
    return cluster


class TestPgTdeResetWal:
    """
    ``pg_tde_resetwal`` wraps ``pg_resetwal`` so that the rewritten
    ``pg_control`` keeps the pg_tde WAL-key metadata consistent — without
    this wrapper, resetting WAL on a cluster with ``pg_tde.wal_encrypt = on``
    would orphan the WAL key and the cluster would refuse to start.

    The contract we pin:
      1. The wrapper ships in the build.
      2. After ``-f``, the cluster restarts cleanly with WAL encryption
         still on, and pre-existing encrypted relations remain readable.
      3. ``--dry-run`` ('``-n``') is a no-op: pg_control is untouched and
         the cluster keeps working without restart.
    """

    def test_binary_exists(self, install_dir: Path):
        bin_path = install_dir / "bin" / "pg_tde_resetwal"
        assert bin_path.is_file(), (
            f"pg_tde_resetwal not found at {bin_path}; this build does not "
            "ship the wrapper."
        )

    def test_resets_wal_and_cluster_restarts(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        cluster = _build_tde_cluster_with_wal_encryption(pg_factory, tmp_path)
        try:
            cluster.execute(
                "CREATE TABLE resetwal_t (id SERIAL PRIMARY KEY, payload TEXT) "
                "USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO resetwal_t (payload) "
                "SELECT md5(g::text) FROM generate_series(1, 5000) g"
            )
            cluster.execute("CHECKPOINT")

            count_before = cluster.fetchone(
                "SELECT COUNT(*) FROM resetwal_t"
            )
            assert count_before == "5000"
            cluster.stop()

            result = _run_pg_tde_resetwal(
                install_dir, "-f", "-D", str(cluster.data_dir)
            )
            assert result.returncode == 0, (
                "pg_tde_resetwal -f failed:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )

            cluster.start()
            cluster.wait_ready(timeout=60)

            # The whole point of the wrapper is that WAL encryption is still
            # on after the reset *and* encrypted data is still readable
            # (the WAL key metadata in pg_control was preserved correctly).
            assert cluster.fetchone("SHOW pg_tde.wal_encrypt") == "on", (
                "WAL encryption was unexpectedly disabled after "
                "pg_tde_resetwal -f."
            )
            count_after = cluster.fetchone("SELECT COUNT(*) FROM resetwal_t")
            assert count_after == "5000", (
                "Encrypted relation became unreadable after "
                f"pg_tde_resetwal -f (count={count_after!r})."
            )

            # New writes after the WAL reset must also work — proves the
            # WAL stream is freshly initialised and still encrypted.
            cluster.execute(
                "INSERT INTO resetwal_t (payload) VALUES ('after-reset')"
            )
            assert cluster.fetchone(
                "SELECT COUNT(*) FROM resetwal_t WHERE payload = 'after-reset'"
            ) == "1"
        finally:
            cluster.stop(check=False)

    def test_dry_run_does_not_modify_pg_control(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        ``-n`` / ``--dry-run`` must print the proposed changes to stdout
        and leave ``global/pg_control`` byte-for-byte identical. Catches
        future regressions where the wrapper invokes the underlying tool
        without forwarding the dry-run flag.
        """
        cluster = _build_tde_cluster_with_wal_encryption(
            pg_factory, tmp_path, name="tde_resetwal_dry"
        )
        try:
            cluster.execute(
                "CREATE TABLE dr_t (id INT) USING tde_heap"
            )
            cluster.execute("INSERT INTO dr_t SELECT generate_series(1, 10)")
            cluster.stop()

            pg_control = cluster.data_dir / "global" / "pg_control"
            before = pg_control.read_bytes()

            result = _run_pg_tde_resetwal(
                install_dir, "-n", "-D", str(cluster.data_dir)
            )
            assert result.returncode == 0, (
                "pg_tde_resetwal -n failed:\n"
                f"  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
            after = pg_control.read_bytes()
            assert before == after, (
                "pg_tde_resetwal -n (dry run) modified global/pg_control — "
                "the wrapper is not forwarding the dry-run flag to "
                "pg_resetwal."
            )

            # And the cluster must still come up cleanly with no changes
            # to commit.
            cluster.start()
            cluster.wait_ready(timeout=30)
            assert cluster.fetchone("SELECT COUNT(*) FROM dr_t") == "10"
        finally:
            cluster.stop(check=False)


# ── pg_tde_archive_decrypt / pg_tde_restore_encrypt ──────────────────────────


def _build_archive_cluster(
    pg_factory, tmp_path: Path, install_dir: Path, *, name: str = "arch_dec"
) -> Tuple[PgCluster, Path]:
    """
    Build a TDE cluster with WAL encryption on, archive_mode on, and
    archive_command wired to ``pg_tde_archive_decrypt``. Returns
    ``(cluster, archive_dir)``.
    """
    archive_dir = tmp_path / f"{name}_archive"
    archive_dir.mkdir()

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
    tde.add_global_key_provider_file(
        keyfile=str(tmp_path / f"{name}_keyring.per")
    )
    tde.set_global_principal_key(f"{name}_key")
    tde.enable_wal_encryption()

    arch_cmd, _ = archive_restore_conf_values(
        install_dir, archive_dir, use_tde_wrappers=True
    )
    cluster.configure({
        "archive_mode": "on",
        "archive_command": arch_cmd,
        "wal_level": "replica",
    })
    cluster.restart()
    return cluster, archive_dir


def _wait_for_segment_archive(
    archive_dir: Path, timeout: int = 30
) -> Optional[Path]:
    """Wait until at least one 24-character WAL segment lands in archive_dir."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        segs = [
            p for p in archive_dir.iterdir()
            if p.is_file() and len(p.name) == 24 and "." not in p.name
        ]
        if segs:
            return sorted(segs)[-1]
        time.sleep(0.5)
    return None


class TestPgTdeArchiveDecryptRestoreEncrypt:
    """
    Round-trip coverage for the archive_command / restore_command wrappers
    used to bridge encrypted WAL with backup tooling that expects plaintext
    WAL on disk.

    The full lifecycle is:

      primary $PGDATA/pg_wal/<seg>        (encrypted)
            │
            │ archive_command:
            │   pg_tde_archive_decrypt %f %p "cp %p $ARCHIVE/%f"
            ▼
      $ARCHIVE/<seg>                       (decrypted plaintext WAL)
            │
            │ restore_command (recovery):
            │   pg_tde_restore_encrypt %f %p "cp $ARCHIVE/%f %p"
            ▼
      recovery $PGDATA/pg_wal/<seg>        (re-encrypted on the way back in)

    All four tests in this class skip cleanly when the wrappers aren't in
    the build (e.g. minimal builds without pg_tde-archive support).
    """

    @pytest.fixture(autouse=True)
    def _skip_if_no_wrappers(self, install_dir: Path):
        if not wrappers_available(install_dir):
            pytest.skip(
                "pg_tde_archive_decrypt / pg_tde_restore_encrypt not in build"
            )

    def test_archive_decrypt_produces_plaintext_segments(
        self, pg_factory, tmp_path: Path, install_dir: Path
    ):
        """
        After ``pg_tde_archive_decrypt`` runs in archive_command:

          - the archive segment must NOT byte-equal the original
            ``$PGDATA/pg_wal/<seg>`` (the wrapper actually decrypted it),
          - a plaintext marker inserted before the segment switch must be
            visible in the archived segment (decrypted), and
          - the same marker must NOT be visible in the source pg_wal/
            segment (still encrypted on the primary).
        """
        cluster, archive_dir = _build_archive_cluster(
            pg_factory, tmp_path, install_dir
        )
        try:
            marker = "MARKER-archive-decrypt-must-decrypt-on-archive-9b3f"
            cluster.execute(
                "CREATE TABLE arch_dec_t (id INT, payload TEXT) "
                "USING tde_heap"
            )
            cluster.execute(
                f"INSERT INTO arch_dec_t VALUES (1, '{marker}')"
            )
            cluster.execute("CHECKPOINT")

            seg_name_before = cluster.fetchone(
                "SELECT pg_walfile_name(pg_current_wal_insert_lsn())"
            )
            src_seg = cluster.data_dir / "pg_wal" / seg_name_before
            assert src_seg.exists(), (
                f"pg_wal does not contain {seg_name_before}"
            )
            src_bytes_pre_switch = src_seg.read_bytes()

            cluster.execute("SELECT pg_switch_wal()")
            archived = _wait_for_segment_archive(archive_dir, timeout=30)
            assert archived is not None, (
                "No WAL segment was archived within 30s — "
                f"check archive_command. archive_dir contents: "
                f"{[p.name for p in archive_dir.iterdir()]}"
            )

            arch_bytes = archived.read_bytes()

            # 1. Archive bytes must differ from the encrypted source segment.
            assert arch_bytes != src_bytes_pre_switch, (
                "Archived segment is byte-identical to the encrypted source — "
                "pg_tde_archive_decrypt did not transform the file."
            )

            # 2. The plaintext marker must appear in the (decrypted) archive.
            marker_b = marker.encode()
            assert marker_b in arch_bytes, (
                f"Plaintext marker {marker!r} not found in archived segment "
                f"{archived.name}; pg_tde_archive_decrypt may not have "
                "produced plaintext output."
            )

            # 3. The same marker must NOT appear in the still-encrypted
            #    source segment we captured before the switch.
            assert marker_b not in src_bytes_pre_switch, (
                f"Plaintext marker {marker!r} unexpectedly found in the "
                "source (encrypted) WAL segment — encryption is not active."
            )
        finally:
            cluster.stop(check=False)

    def test_round_trip_pitr_using_both_wrappers(
        self, pg_factory, tmp_path: Path, install_dir: Path, io_method: str
    ):
        """
        Full archive → restore round-trip. After backup we insert a row,
        capture ``now()`` as the PITR target, do a destructive DROP, then
        PITR-restore using ``pg_tde_restore_encrypt`` in restore_command —
        the restored cluster must replay the encrypted WAL correctly and
        recover the pre-DROP state of the ``tde_heap`` table.

        This is the standalone, asserted version of the scenario the bash
        script ``pg_tde_restore_encrypt_using_archive_decrypt.sh`` walks
        through.
        """
        cluster, archive_dir = _build_archive_cluster(
            pg_factory, tmp_path, install_dir, name="arch_round"
        )
        try:
            cluster.execute(
                "CREATE TABLE rt_t (id SERIAL PRIMARY KEY, val TEXT) "
                "USING tde_heap"
            )
            cluster.execute(
                "INSERT INTO rt_t (val) "
                "SELECT 'pre_backup_' || g FROM generate_series(1, 50) g"
            )
            cluster.execute("CHECKPOINT")
            cluster.execute("SELECT pg_switch_wal()")
            _wait_for_segment_archive(archive_dir, timeout=15)

            # Take a cold copy of $PGDATA as our "base backup".
            cluster.stop()
            backup_dir = tmp_path / "rt_backup"
            shutil.copytree(cluster.data_dir, backup_dir)
            cluster.start()

            # Captured *after* the backup so it survives the DROP and
            # falls inside the WAL we just archived.
            pitr_time = (cluster.fetchone("SELECT now()") or "").strip()
            time.sleep(1)
            cluster.execute("DROP TABLE rt_t")
            cluster.execute("SELECT pg_switch_wal()")
            _wait_for_segment_archive(archive_dir, timeout=30)
            cluster.stop()

            # Restore the backup into a new $PGDATA on a new port; wire
            # recovery to use the pg_tde_restore_encrypt wrapper.
            restore_dir = tmp_path / "rt_restored"
            shutil.copytree(backup_dir, restore_dir)
            restored_port = allocate_port()
            restored = PgCluster(
                restore_dir, restored_port, install_dir,
                socket_dir=tmp_path, io_method=io_method,
            )
            restored.write_default_config(extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            })
            auto_conf = restore_dir / "postgresql.auto.conf"
            with auto_conf.open("w") as f:
                f.write("pg_tde.wal_encrypt = 'on'\n")
                f.write(f"recovery_target_time = '{pitr_time}'\n")
                f.write("recovery_target_action = 'promote'\n")
                f.write(restore_conf_line_raw(
                    archive_dir, install_dir, use_tde_wrappers=True
                ))
            (restore_dir / "recovery.signal").touch()
            restored.add_hba_entry("local all all trust")

            restored.start()
            try:
                restored.wait_ready(timeout=60)
                # Wait for recovery / promotion to finish before querying.
                deadline = time.time() + 60
                while time.time() < deadline:
                    in_recovery = restored.fetchone(
                        "SELECT pg_is_in_recovery()"
                    )
                    if in_recovery and in_recovery.lower() in ("f", "false"):
                        break
                    time.sleep(1)

                count = restored.fetchone("SELECT COUNT(*) FROM rt_t")
                assert count == "50", (
                    "PITR-restored cluster did not recover the encrypted "
                    f"table to its pre-DROP state (count={count!r}). "
                    "pg_tde_restore_encrypt may not have re-encrypted WAL "
                    "correctly on the way back into pg_wal/."
                )
            finally:
                restored.stop(check=False)
        finally:
            cluster.stop(check=False)

    def test_archive_decrypt_fails_with_nonexistent_input(
        self, install_dir: Path, tmp_path: Path
    ):
        """
        Calling ``pg_tde_archive_decrypt`` with an input segment path that
        doesn't exist must exit non-zero — silent success would let
        archive_command "succeed" without producing anything.
        """
        bin_path = _bin_or_skip(install_dir, "pg_tde_archive_decrypt")
        archive = tmp_path / "neg_archive"
        archive.mkdir()
        bogus_seg = "000000010000000000000099"   # never existed
        bogus_path = tmp_path / "nope" / bogus_seg
        result = subprocess.run(
            [
                str(bin_path),
                bogus_seg,
                str(bogus_path),
                f'cp %p {archive}/%f',
            ],
            capture_output=True, text=True, env=_env(install_dir),
        )
        assert result.returncode != 0, (
            "pg_tde_archive_decrypt should fail when the source segment "
            f"doesn't exist; got returncode={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )

    def test_restore_encrypt_fails_with_bad_inner_command(
        self, install_dir: Path, tmp_path: Path
    ):
        """
        If the inner shell command supplied to ``pg_tde_restore_encrypt``
        fails (here: ``false``), the wrapper must propagate the failure to
        the caller. Recovery relies on this: a restore_command that
        silently returned 0 on a missing segment would corrupt the
        recovered cluster.
        """
        bin_path = _bin_or_skip(install_dir, "pg_tde_restore_encrypt")
        seg = "000000010000000000000001"
        out_path = tmp_path / "neg_pg_wal" / seg
        out_path.parent.mkdir(parents=True, exist_ok=True)
        # `false` exits with returncode 1 unconditionally → the wrapper
        # must surface a non-zero exit.
        result = subprocess.run(
            [str(bin_path), seg, str(out_path), "false"],
            capture_output=True, text=True, env=_env(install_dir),
        )
        assert result.returncode != 0, (
            "pg_tde_restore_encrypt should propagate inner-command failure "
            f"(`false`); got returncode={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
