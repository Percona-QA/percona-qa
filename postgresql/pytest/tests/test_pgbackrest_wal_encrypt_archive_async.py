"""
pgBackRest ``archive-async`` + ``pg_tde.wal_encrypt`` validation scenarios.

WAL in the pgBackRest repo (the pgstef model), as opposed to the Percona
decrypt-wrapper walkthrough:

  * Simple / primary-only path can work with::

        archive-async=y
        archive-header-check=n
        checksum-page=n

  * WAL keys are **per-node** and **rotate on restart**. Streaming ships
    plaintext; the standby re-encrypts with its own key. An archive of
    primary ciphertext is therefore usable only by a node that still has
    those keys.
  * Standby **archive recovery** from a primary-encrypted archive is not
    reliable.
  * After **promotion**, if the old primary (and its keys) are gone, replaying
    pre-promotion encrypted archive segments is unsafe / expected to fail.

These tests intentionally exercise the encrypted-in-repo path
(``pg_tde_wal_archiving=False`` — no ``pg_tde_archive_decrypt``).
"""
from __future__ import annotations

import hashlib
import re
import shutil
import time
from pathlib import Path
from typing import Dict, List

import pytest

from conftest import allocate_port
from lib import BackupManager, PgCluster, ReplicationManager, TdeManager
from lib.cluster import initdb_args_no_data_checksums

pytestmark = [pytest.mark.backup, pytest.mark.pgbackrest, pytest.mark.slow]

_TDE_PARAMS: Dict[str, str] = {
    "shared_preload_libraries": "'pg_tde'",
    "default_table_access_method": "'tde_heap'",
}

_HA_PARAMS: Dict[str, str] = {
    **_TDE_PARAMS,
    "wal_level": "replica",
    "max_wal_senders": "10",
    "max_replication_slots": "10",
    "hot_standby": "on",
}

_AUTO_CONF_OVERRIDE_KEYS = frozenset(
    {
        "port",
        "unix_socket_directories",
        "listen_addresses",
        "log_directory",
        "archive_mode",
        "archive_command",
        "restore_command",
        "primary_conninfo",
    }
)

_ARCHIVE_FAIL_MARKERS = (
    "invalid magic number",
    "could not",
    "cannot",
    "failed",
    "fatal",
    "corruption",
    "wrong key",
    "decrypt",
)


def _strip_auto_conf_overrides(data_dir: Path) -> None:
    auto = data_dir / "postgresql.auto.conf"
    if not auto.exists():
        return
    out: List[str] = []
    for line in auto.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            out.append(line)
            continue
        key = raw.split("=", 1)[0].strip().lower()
        if key in _AUTO_CONF_OVERRIDE_KEYS:
            continue
        out.append(line)
    auto.write_text("\n".join(out) + ("\n" if out else ""))


def _configure_hba(cluster: PgCluster) -> None:
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("local replication all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    cluster.add_hba_entry("host  replication all 127.0.0.1/32 trust")


def _start_tde_primary(pg_factory, name: str) -> PgCluster:
    primary = pg_factory(name)
    primary.initdb(extra_args=initdb_args_no_data_checksums(primary.install_dir))
    primary.write_default_config(
        "primary",
        extra_params={**_HA_PARAMS, "wal_keep_size": "'64MB'"},
    )
    _configure_hba(primary)
    primary.start()
    tde = TdeManager(primary)
    tde.create_extension()
    tde.add_global_key_provider_file()
    tde.set_global_principal_key()
    tde.enable_wal_encryption()
    assert primary.fetchone("SHOW pg_tde.wal_encrypt") == "on"
    return primary


def _setup_encrypted_in_repo_pgbackrest(
    primary: PgCluster,
    tmp_path: Path,
    *,
    stanza: str,
    archive_async: bool = True,
) -> BackupManager:
    """
    pgBackRest config for archiving **ciphertext** WAL (no decrypt wrapper).

    Required flags from the encrypted-in-repo walkthrough:
    ``archive-header-check=n``, ``checksum-page=n``.
    """
    bm = BackupManager(stanza=stanza, repo_path=str(tmp_path / "repo"))
    bm.write_config(
        pg_path=str(primary.data_dir),
        pg_port=primary.port,
        pg_socket_path=str(primary.socket_dir),
        pg_bin=str(primary.bin),
        compress_type="none",
        archive_async=archive_async,
        archive_header_check=False,
        checksum_page=False,
    )
    # No pg_tde_archive_decrypt — push encrypted segments as-is.
    bm.configure_postgres(primary, pg_tde_wal_archiving=False)
    primary.configure({"archive_timeout": "'5s'"})
    primary.restart()
    bm.stanza_create()
    return bm


def _seed_encrypted_rows(cluster: PgCluster, marker: str, n: int = 100) -> None:
    cluster.execute(
        "CREATE TABLE IF NOT EXISTS async_enc (id INT PRIMARY KEY, payload TEXT) "
        "USING tde_heap"
    )
    cluster.execute(
        f"INSERT INTO async_enc "
        f"SELECT i, '{marker}' || md5(i::text) FROM generate_series(1, {n}) i "
        f"ON CONFLICT DO NOTHING"
    )


def _start_restored_with_keyring(
    restore_dir: Path,
    install_dir: Path,
    socket_dir: Path,
    io_method: str,
    bm: BackupManager,
    *,
    role: str = "primary",
    promote: bool = True,
    timeout: int = 120,
) -> PgCluster:
    """Boot a restore that keeps encrypted WAL; restore_command is raw archive-get."""
    port = allocate_port()
    cluster = PgCluster(
        restore_dir, port, install_dir,
        socket_dir=socket_dir, io_method=io_method,
    )
    cluster.write_default_config(role, extra_params=_HA_PARAMS)
    _strip_auto_conf_overrides(restore_dir)
    restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
    auto = restore_dir / "postgresql.auto.conf"
    with auto.open("a") as f:
        f.write(f"restore_command = '{restore_cmd}'\n")
    _configure_hba(cluster)
    cluster.start()
    cluster.wait_ready(timeout=timeout)
    if role == "primary" and promote:
        if cluster.fetchone("SELECT pg_is_in_recovery()") == "t":
            cluster.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
        deadline = time.time() + 60
        while time.time() < deadline:
            if cluster.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.3)
        else:
            raise TimeoutError("restored primary did not leave recovery")
    return cluster


def _find_repo_wal_segments(repo_path: Path, stanza: str) -> List[Path]:
    """WAL segment files under ``<repo>/archive/<stanza>/`` (exclude logs/spool)."""
    archive = repo_path / "archive" / stanza
    if not archive.is_dir():
        return []
    pattern = re.compile(r"^[0-9A-F]{24}(-[0-9a-f]+)?$")
    return [
        p for p in archive.rglob("*")
        if p.is_file() and pattern.match(p.name)
    ]


def _assert_marker_absent_from_archived_wal(
    repo_path: Path, stanza: str, marker: str
) -> None:
    segs = _find_repo_wal_segments(repo_path, stanza)
    assert segs, f"No archived WAL segments under {repo_path / 'archive' / stanza}"
    marker_b = marker.encode()
    for seg in segs:
        data = seg.read_bytes()
        assert marker_b not in data, (
            f"Plaintext marker {marker!r} found in archived WAL {seg} — "
            "encrypted-in-repo path unexpectedly stored decrypted WAL"
        )


def _pg_tde_keyring_fingerprint(cluster: PgCluster) -> str:
    """
    Content hash of on-disk WAL key material under ``pg_tde/``.

    Used to show primary vs standby keyrings diverge after ``pg_tde_basebackup -E``.
    """
    pg_tde = cluster.data_dir / "pg_tde"
    if not pg_tde.is_dir():
        return ""
    h = hashlib.sha256()
    for path in sorted(pg_tde.rglob("*")):
        if path.is_file():
            h.update(str(path.relative_to(pg_tde)).encode())
            h.update(path.read_bytes())
    return h.hexdigest()


class TestArchiveAsyncEncryptedWalPrimaryOnly:
    """
    Simple scenario (Ege / pgstef): archive-async + encrypted WAL works when
    only the primary archives and restore keeps that primary's keyring.
    """

    def test_archive_async_primary_backup_restore_round_trip(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        primary = _start_tde_primary(pg_factory, "async_pri")
        bm = _setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="async_ok", archive_async=True,
        )
        marker = "async_primary_ok"
        _seed_encrypted_rows(primary, marker, n=150)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Prove archived WAL is ciphertext (do not scan repo logs — they may
        # contain SQL text when log_statement=all).
        _assert_marker_absent_from_archived_wal(tmp_path / "repo", "async_ok", marker)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_primary"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _start_restored_with_keyring(
            restore_dir, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker}%'"
            ) == "150"
            assert restored.fetchone("SHOW pg_tde.wal_encrypt") == "on"
        finally:
            restored.stop(check=False)


class TestEncryptedArchiveMultiNodeConcerns:
    """
    multi-node concerns: different WAL keys per node, archive recovery
    on standbys, and promotion without the old primary's keys.
    """

    def test_standby_wal_keyring_differs_from_primary(
        self, pg_factory, tmp_path: Path,
    ):
        """Streaming re-encrypts on the standby — keyrings must not be identical."""
        primary = _start_tde_primary(pg_factory, "keys_pri")
        _setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="keys", archive_async=True,
        )
        primary_fp = _pg_tde_keyring_fingerprint(primary)
        assert primary_fp, "primary missing pg_tde/ keyring"

        standby = pg_factory("keys_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)

        primary.execute("CREATE TABLE kdiff (id INT PRIMARY KEY) USING tde_heap")
        primary.execute("INSERT INTO kdiff VALUES (1)")
        repl.assert_catchup(timeout=60)
        # Restart forces a new WAL key generation on the standby.
        standby.restart()
        standby.wait_ready(timeout=60)
        repl.assert_streaming_connected(timeout=60)
        standby_fp = _pg_tde_keyring_fingerprint(standby)
        assert standby_fp, "standby missing pg_tde/ keyring"
        assert primary_fp != standby_fp, (
            "Expected distinct WAL keyring fingerprints after "
            "pg_tde_basebackup -E + streaming; identical keyrings would "
            "undermine the multi-node archive-key concern.\n"
            f"primary={primary_fp}\nstandby={standby_fp}"
        )

    def test_standby_archive_recovery_from_primary_encrypted_archive_fails(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Standby archive recovery cannot reliably consume primary ciphertext.

        Force archive-only recovery (no primary_conninfo): the standby must
        fetch primary-encrypted WAL via restore_command and is expected to
        fail (invalid magic / decrypt / recovery error).
        """
        primary = _start_tde_primary(pg_factory, "arc_pri")
        bm = _setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="arc_std", archive_async=True,
        )
        _seed_encrypted_rows(primary, "pre_std", n=50)
        bm.wait_for_wal_archive(primary, timeout=60)

        standby = pg_factory("arc_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)
        repl.assert_catchup(timeout=60)

        # Advance primary WAL into the archive, then recycle local segments.
        primary.execute("CHECKPOINT")
        for i in range(4):
            primary.execute(
                f"INSERT INTO async_enc VALUES (1000 + {i}, 'need_archive_{i}')"
            )
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        bm.wait_for_wal_archive(primary, timeout=60)
        primary.configure({"wal_keep_size": "'0'"})
        primary.restart()
        primary.wait_ready(timeout=60)
        for _ in range(3):
            primary.execute("CHECKPOINT")
            primary.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)

        # Rebuild standby into archive-only recovery against the primary archive.
        standby.stop(check=False)
        # Drop local WAL so recovery must call restore_command.
        pg_wal = standby.data_dir / "pg_wal"
        for seg in pg_wal.iterdir():
            if seg.is_file() and len(seg.name) == 24 and seg.name.isalnum():
                seg.unlink()

        standby.write_default_config("replica", extra_params=_HA_PARAMS)
        _strip_auto_conf_overrides(standby.data_dir)
        (standby.data_dir / "standby.signal").touch(exist_ok=True)
        # Intentionally NO primary_conninfo — archive-only.
        restore_cmd = bm.archive_get_command(str(standby.data_dir.resolve()))
        with (standby.data_dir / "postgresql.auto.conf").open("a") as f:
            f.write(f"restore_command = '{restore_cmd}'\n")

        log_path = standby.data_dir / "server.log"
        if log_path.exists():
            log_path.write_text("")

        start_failed = False
        try:
            standby.start(timeout=45)
        except RuntimeError:
            start_failed = True

        time.sleep(5)
        log_text = standby.read_log(150).lower()
        standby.stop(check=False)

        hit = any(m in log_text for m in _ARCHIVE_FAIL_MARKERS) or start_failed
        assert hit, (
            "Standby archive-only recovery was expected to fail when fetching "
            "primary-encrypted WAL segments (different WAL keys).\n"
            f"start_failed={start_failed}\nlog:\n{standby.read_log(150)}"
        )

    def test_promote_without_old_primary_keys_breaks_pre_failover_archive_replay(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        After promote, losing the old primary keys makes pre-failover encrypted
        archive segments unusable for a restore that only has the new primary
        keyring — the k8s "delete old primary pod" concern.
        """
        primary = _start_tde_primary(pg_factory, "fail_pri")
        bm = _setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="failovr", archive_async=True,
        )
        marker_old = "pre_failover_secret"
        _seed_encrypted_rows(primary, marker_old, n=80)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")
        bm.wait_for_wal_archive(primary, timeout=60)

        # Capture old-primary keyring separately (simulates "keys were on that pod").
        old_keys = tmp_path / "old_primary_pg_tde"
        shutil.copytree(primary.data_dir / "pg_tde", old_keys)

        standby = pg_factory("fail_std")
        repl = ReplicationManager(primary, standby)
        repl.create_standby_from_backup(use_tde_basebackup=True)
        standby.write_default_config("replica", extra_params=_HA_PARAMS)
        standby.start()
        repl.assert_streaming_connected(timeout=60)
        repl.assert_catchup(timeout=60)

        # Fail over: stop primary (keys discarded), promote standby.
        primary.stop(check=False)
        # Wipe old primary keyring from disk to model pod deletion.
        shutil.rmtree(primary.data_dir / "pg_tde", ignore_errors=True)

        standby.execute("SELECT pg_promote(wait := true, wait_seconds := 60)")
        deadline = time.time() + 60
        while time.time() < deadline:
            if standby.fetchone("SELECT pg_is_in_recovery()") == "f":
                break
            time.sleep(0.3)
        else:
            raise TimeoutError("standby did not promote")

        # New primary writes + archives under *its* WAL keys.
        standby.execute(
            "INSERT INTO async_enc VALUES (9001, 'post_failover_on_new_primary')"
        )
        for _ in range(3):
            standby.execute("CHECKPOINT")
            standby.execute("SELECT pg_switch_wal()")
            time.sleep(0.5)
        # Point pgBackRest pg1-* at the promoted node for further archive-push.
        bm.write_config(
            pg_path=str(standby.data_dir),
            pg_port=standby.port,
            pg_socket_path=str(standby.socket_dir),
            pg_bin=str(standby.bin),
            compress_type="none",
            archive_async=True,
            archive_header_check=False,
            checksum_page=False,
        )
        bm.configure_postgres(standby, pg_tde_wal_archiving=False)
        standby.restart()
        standby.wait_ready(timeout=60)
        bm.wait_for_wal_archive(standby, timeout=90)

        # Restore the *pre-failover* full backup. Replace restored keyring with
        # the promoted node's keyring only (old primary keys lost).
        standby.stop(check=False)
        restore_dir = tmp_path / "restore_after_failover"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)

        restored_keys = restore_dir / "pg_tde"
        if restored_keys.exists():
            shutil.rmtree(restored_keys)
        # Use the promoted node's keyring (surviving pod), not old_keys.
        shutil.copytree(standby.data_dir / "pg_tde", restored_keys)

        port = allocate_port()
        restored = PgCluster(
            restore_dir, port, install_dir,
            socket_dir=tmp_path, io_method=io_method,
        )
        restored.write_default_config("primary", extra_params=_HA_PARAMS)
        _strip_auto_conf_overrides(restore_dir)
        restore_cmd = bm.archive_get_command(str(restore_dir.resolve()))
        with (restore_dir / "postgresql.auto.conf").open("a") as f:
            f.write(f"restore_command = '{restore_cmd}'\n")
        _configure_hba(restored)

        log_path = restore_dir / "server.log"
        if log_path.exists():
            log_path.write_text("")

        start_failed = False
        try:
            restored.start(timeout=60)
            # If it somehow starts, recovery that needs old encrypted WAL should
            # still leave us unable to read pre-failover rows cleanly, or log errors.
            time.sleep(5)
            log_text = restored.read_log(200).lower()
            try:
                count = restored.fetchone(
                    f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker_old}%'"
                )
            except RuntimeError:
                count = None
            restored.stop(check=False)
        except RuntimeError:
            start_failed = True
            log_text = restored.read_log(200).lower()
            count = None

        # Success criteria for the concern: either startup/recovery fails, or
        # pre-failover encrypted data is not cleanly available under the new keys.
        recovery_broke = start_failed or any(
            m in log_text for m in _ARCHIVE_FAIL_MARKERS
        )
        data_unreadable = count not in (str(80), "80")
        assert recovery_broke or data_unreadable, (
            "Expected restore without old-primary WAL keys to fail or lose "
            f"pre-failover rows; count={count!r} start_failed={start_failed}\n"
            f"log:\n{restored.read_log(200)}"
        )

        # Control: with old keys restored, the same backup should be recoverable.
        restore_ok = tmp_path / "restore_with_old_keys"
        bm.restore(str(restore_ok), pg_tde_wal_restore=False)
        if (restore_ok / "pg_tde").exists():
            shutil.rmtree(restore_ok / "pg_tde")
        shutil.copytree(old_keys, restore_ok / "pg_tde")
        ok = _start_restored_with_keyring(
            restore_ok, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert ok.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker_old}%'"
            ) == "80", (
                "Control restore with preserved old-primary keys must succeed; "
                "otherwise the negative assertion is inconclusive."
            )
        finally:
            ok.stop(check=False)

    def test_primary_restart_retains_keys_so_own_archive_still_works(
        self,
        pg_factory,
        tmp_path: Path,
        install_dir: Path,
        io_method: str,
    ):
        """
        Contrast to multi-node: restarting the *same* primary rotates the
        active WAL key but keeps historical keys in PGDATA, so its own
        encrypted archive remains usable.
        """
        primary = _start_tde_primary(pg_factory, "restart_pri")
        bm = _setup_encrypted_in_repo_pgbackrest(
            primary, tmp_path, stanza="restart", archive_async=True,
        )
        marker = "before_restart"
        _seed_encrypted_rows(primary, marker, n=60)
        bm.wait_for_wal_archive(primary, timeout=60)
        bm.backup(backup_type="full")

        fp_before = _pg_tde_keyring_fingerprint(primary)
        primary.restart()  # new active WAL key generation
        primary.wait_ready(timeout=60)
        fp_after = _pg_tde_keyring_fingerprint(primary)
        # Keyring directory content should still exist; fingerprint may grow.
        assert fp_after, "keyring missing after restart"
        assert fp_before, "keyring missing before restart"

        primary.execute(
            "INSERT INTO async_enc VALUES (7001, 'after_restart_row')"
        )
        bm.wait_for_wal_archive(primary, timeout=60)

        primary.stop(check=False)
        restore_dir = tmp_path / "restore_same_primary"
        bm.restore(str(restore_dir), pg_tde_wal_restore=False)
        restored = _start_restored_with_keyring(
            restore_dir, install_dir, tmp_path, io_method, bm,
        )
        try:
            assert restored.fetchone(
                f"SELECT COUNT(*) FROM async_enc WHERE payload LIKE '{marker}%'"
            ) == "60"
            assert restored.fetchone(
                "SELECT COUNT(*) FROM async_enc WHERE id = 7001"
            ) == "1"
        finally:
            restored.stop(check=False)
