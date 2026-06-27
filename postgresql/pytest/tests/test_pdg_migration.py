"""
Regression tests for Percona Distribution for PostgreSQL migration procedures.

Doc reference (same-server and different-server flows):
  https://docs.percona.com/postgresql/18/migration.html

The published guide covers migrating from PostgreSQL Community to Percona
Distribution: stop the server, replace packages, optionally restore backups and
configuration, then start again (same host) or restore on a target host.

Pytest cannot run ``apt-get remove postgresql`` / ``percona-release setup`` in CI;
these tests simulate the **data and configuration preservation** phases that
must succeed regardless of packaging:

  * Same server — stop → preserve ``postgresql.conf`` / ``pg_hba.conf`` → start
    the same ``$PGDATA`` with the Percona binaries under ``--install-dir``.
  * Different server — logical ``pg_dumpall`` or physical copy/basebackup from
    source → new cluster on another data directory.
  * pg_tde — encrypted ``tde_heap`` data survives the same workflows.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import List, Optional, Set

import pytest

from conftest import allocate_port
from lib import PgCluster, ReplicationManager, TdeManager
from lib.cluster import (
    initdb_args_no_data_checksums,
    libpq_superuser,
    postgres_major_version,
    prepend_install_lib_dirs,
    read_pg_tde_default_version,
)

DOC_URL = "https://docs.percona.com/postgresql/18/migration.html"

pytestmark = [pytest.mark.migration, pytest.mark.slow]


# ── helpers ───────────────────────────────────────────────────────────────────


def _config_files(data_dir: Path) -> List[Path]:
    names = ("postgresql.conf", "postgresql.auto.conf", "pg_hba.conf")
    return [data_dir / n for n in names if (data_dir / n).is_file()]


def _backup_config_files(data_dir: Path, backup_dir: Path) -> None:
    """Mirror doc recommendation: back up configuration before migration."""
    backup_dir.mkdir(parents=True, exist_ok=True)
    for path in _config_files(data_dir):
        shutil.copy2(path, backup_dir / path.name)


def _restore_config_files(backup_dir: Path, data_dir: Path) -> None:
    for name in ("postgresql.conf", "postgresql.auto.conf", "pg_hba.conf"):
        src = backup_dir / name
        if src.is_file():
            shutil.copy2(src, data_dir / name)


def _pg_env(cluster: PgCluster) -> dict:
    env = os.environ.copy()
    prepend_install_lib_dirs(env, cluster.install_dir)
    env.update(
        {
            "PGHOST": str(cluster.socket_dir),
            "PGPORT": str(cluster.port),
            "PGUSER": libpq_superuser(),
            "PGDATABASE": "postgres",
        }
    )
    return env


def _pg_dumpall(cluster: PgCluster, dump_path: Path) -> None:
    subprocess.run(
        [str(cluster.bin / "pg_dumpall"), "-f", str(dump_path)],
        check=True,
        env=_pg_env(cluster),
        capture_output=True,
        text=True,
    )


def _bootstrap_roles_for_restore() -> Set[str]:
    """Roles initdb already created on a fresh target cluster."""
    return {libpq_superuser(), "postgres"}


def _role_name_from_role_ddl(line: str) -> Optional[str]:
    """Extract role name from a one-line CREATE/ALTER ROLE statement."""
    m = re.match(r"^(?:CREATE|ALTER)\s+ROLE\s+([^\s;]+)", line, re.IGNORECASE)
    if not m:
        return None
    return m.group(1).strip('"')


def _should_skip_dumpall_line(
    line: str,
    *,
    skip_roles: Set[str],
    skip_extensions: Set[str],
) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    name = _role_name_from_role_ddl(line)
    if name and name in skip_roles:
        return True
    for ext in skip_extensions:
        if re.match(
            rf"^CREATE EXTENSION\s+(?:IF NOT EXISTS\s+)?{re.escape(ext)}\b",
            stripped,
            re.I,
        ):
            return True
        if re.match(rf"^COMMENT ON EXTENSION\s+{re.escape(ext)}\b", stripped, re.I):
            return True
        if re.match(rf"^ALTER EXTENSION\s+{re.escape(ext)}\b", stripped, re.I):
            return True
    return False


def _filter_dumpall_for_fresh_cluster(
    dump_path: Path,
    *,
    skip_extensions: Optional[Set[str]] = None,
) -> Path:
    """
    ``pg_dumpall`` emits CREATE/ALTER ROLE for the cluster superuser; a target
    cluster from initdb already has that role (typically the OS user, e.g.
    ``ubuntu``).  Drop those lines so ``psql -v ON_ERROR_STOP=1`` can proceed.

    When pg_tde is pre-bootstrapped on the target, skip ``CREATE EXTENSION
    pg_tde`` (and related lines) so restore does not fail with "already exists".
    """
    skip_roles = _bootstrap_roles_for_restore()
    skip_extensions = skip_extensions or set()
    filtered = dump_path.with_name(f"{dump_path.stem}.restore.sql")
    kept: List[str] = []
    for line in dump_path.read_text().splitlines():
        if _should_skip_dumpall_line(
            line, skip_roles=skip_roles, skip_extensions=skip_extensions
        ):
            continue
        kept.append(line)
    filtered.write_text("\n".join(kept) + "\n")
    return filtered


def _restore_pg_dumpall(
    cluster: PgCluster,
    dump_path: Path,
    *,
    skip_extensions: Optional[Set[str]] = None,
) -> None:
    _psql_file(
        cluster,
        _filter_dumpall_for_fresh_cluster(dump_path, skip_extensions=skip_extensions),
    )


def _bootstrap_tde_for_restore(
    cluster: PgCluster,
    keyfile: str,
) -> None:
    """
    Prepare a fresh target cluster before replaying ``pg_dumpall`` that contains
    ``tde_heap`` objects.

    Logical dumps carry decrypted row data but not key-provider configuration;
    the migration doc expects keyring files (and ``pg_tde/`` metadata for physical
    paths) to be copied separately.  Register the same file provider + principal
    key on the target so ``CREATE TABLE ... USING tde_heap`` and subsequent
    ``COPY``/``INSERT`` replay succeed.
    """
    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=keyfile)
    tde.set_global_principal_key()


def _psql_file(cluster: PgCluster, sql_path: Path) -> None:
    result = subprocess.run(
        [
            str(cluster.bin / "psql"),
            "-h",
            str(cluster.socket_dir),
            "-p",
            str(cluster.port),
            "-U",
            libpq_superuser(),
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-f",
            str(sql_path),
        ],
        check=False,
        env=_pg_env(cluster),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"psql restore failed (exit {result.returncode}) "
            f"from {sql_path}:\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def _make_cluster(
    tmp_path: Path,
    install_dir: Path,
    io_method: str,
    *,
    subdir: str,
    extra_params: Optional[dict] = None,
) -> PgCluster:
    port = allocate_port()
    data_dir = tmp_path / subdir
    cluster = PgCluster(
        data_dir,
        port,
        install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    cluster.initdb(extra_args=initdb_args_no_data_checksums(install_dir))
    cluster.write_default_config(extra_params=extra_params)
    cluster.add_hba_entry("local all all trust")
    cluster.add_hba_entry("host  all all 127.0.0.1/32 trust")
    return cluster


def _seed_community_style_data(cluster: PgCluster, table: str = "pdg_migrate_tbl") -> None:
    cluster.execute(f"DROP TABLE IF EXISTS {table}")
    cluster.execute(
        f"CREATE TABLE {table} (id INT PRIMARY KEY, payload TEXT); "
        f"INSERT INTO {table} SELECT i, md5(i::text) "
        f"FROM generate_series(1, 200) i;"
    )


# ── Migrate on the same server (doc § same server) ───────────────────────────


class TestMigrateOnSameServer:
    """
    https://docs.percona.com/postgresql/18/migration.html#migrate-on-the-same-server

    Simulates: stop → (package swap out of scope) → start same ``$PGDATA``.
    """

    def test_config_backup_restore_before_restart(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Backed-up ``postgresql.conf`` / ``pg_hba.conf`` can be reapplied after stop."""
        cluster = _make_cluster(tmp_path, install_dir, io_method, subdir="same_cfg")
        conf_backup = tmp_path / "config_backup"
        cluster.configure({"log_statement": "'ddl'"}, append=True)
        cluster.start()

        _backup_config_files(cluster.data_dir, conf_backup)
        cluster.stop()

        # Simulate accidental config loss during packaging (doc optional restore).
        for path in _config_files(cluster.data_dir):
            path.write_text(f"# wiped for test\n")

        _restore_config_files(conf_backup, cluster.data_dir)
        cluster.start()
        cluster.wait_ready()

        val = cluster.fetchone("SHOW log_statement")
        assert val == "ddl"
        cluster.stop()

    def test_data_intact_after_stop_and_start_same_pgdata(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Rows written before ``systemctl stop`` survive ``systemctl start``."""
        cluster = _make_cluster(tmp_path, install_dir, io_method, subdir="same_data")
        cluster.start()
        _seed_community_style_data(cluster)
        digest = cluster.fetchone(
            "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM pdg_migrate_tbl"
        )

        cluster.stop()
        cluster.start()
        cluster.wait_ready()

        assert cluster.fetchone("SELECT COUNT(*) FROM pdg_migrate_tbl") == "200"
        assert (
            cluster.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM pdg_migrate_tbl"
            )
            == digest
        )
        cluster.stop()

    def test_pg_dumpall_logical_backup_before_stop(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """``pg_dumpall`` backup taken while source is up can reload on same host."""
        cluster = _make_cluster(tmp_path, install_dir, io_method, subdir="same_dump")
        dump_file = tmp_path / "pdg_dumpall.sql"
        cluster.start()
        _seed_community_style_data(cluster)
        _pg_dumpall(cluster, dump_file)
        cluster.stop()

        restored = _make_cluster(
            tmp_path, install_dir, io_method, subdir="same_dump_restored"
        )
        restored.start()
        restored.wait_ready()
        _restore_pg_dumpall(restored, dump_file)

        assert restored.fetchone("SELECT COUNT(*) FROM pdg_migrate_tbl") == "200"
        restored.stop()


# ── Migrate on a different server (doc § different server) ─────────────────


class TestMigrateOnDifferentServer:
    """
    https://docs.percona.com/postgresql/18/migration.html#migrate-on-a-different-server

    Source: backup + stop. Target: install (simulated) + restore + start.
    """

    def test_pg_dumpall_restore_on_target_cluster(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        source = _make_cluster(tmp_path, install_dir, io_method, subdir="remote_src")
        target = _make_cluster(tmp_path, install_dir, io_method, subdir="remote_tgt")
        dump_file = tmp_path / "remote_dumpall.sql"

        source.start()
        _seed_community_style_data(source)
        _pg_dumpall(source, dump_file)
        source.stop()

        target.start()
        target.wait_ready()
        _restore_pg_dumpall(target, dump_file)

        assert target.fetchone("SELECT COUNT(*) FROM pdg_migrate_tbl") == "200"
        target.stop()

    def test_cold_pgdata_copy_to_target_data_directory(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Physical backup style: copy stopped ``$PGDATA`` tree to target host path."""
        source = _make_cluster(tmp_path, install_dir, io_method, subdir="phys_src")
        target_port = allocate_port()
        target_dir = tmp_path / "phys_tgt"

        source.start()
        _seed_community_style_data(source)
        digest = source.fetchone(
            "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM pdg_migrate_tbl"
        )
        source.stop()

        shutil.copytree(source.data_dir, target_dir)
        target = PgCluster(
            target_dir,
            target_port,
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        target.configure({"port": str(target_port)}, append=False)
        target.start()
        target.wait_ready()

        assert target.fetchone("SELECT COUNT(*) FROM pdg_migrate_tbl") == "200"
        assert (
            target.fetchone(
                "SELECT md5(string_agg(payload, ',' ORDER BY id)) FROM pdg_migrate_tbl"
            )
            == digest
        )
        target.stop()

    def test_pg_basebackup_seed_for_target_server(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """``pg_basebackup`` from source primary seeds target ``$PGDATA`` (running source)."""
        source = _make_cluster(tmp_path, install_dir, io_method, subdir="bb_src")
        target = _make_cluster(tmp_path, install_dir, io_method, subdir="bb_tgt")
        shutil.rmtree(target.data_dir)
        target.data_dir.mkdir(parents=True)

        source.start()
        _seed_community_style_data(source)
        repl = ReplicationManager(source, target)
        repl.create_standby_from_backup()

        target.configure(
            {
                "port": str(target.port),
                "hot_standby": "on",
            }
        )
        target.start()
        target.wait_ready(timeout=90)

        count = target.fetchone(
            "SELECT COUNT(*) FROM pdg_migrate_tbl",
            dbname="postgres",
        )
        assert count == "200"
        source.stop()
        target.stop()


# ── pg_tde during migration (extension of doc workflows) ───────────────────


class TestMigrateWithPgTde:
    """
    Migration doc does not cover pg_tde explicitly; these tests ensure the
    documented stop/backup/restore/start flows keep encrypted data usable.
    """

    def test_tde_heap_data_survives_same_server_stop_start(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        keyfile = str(tmp_path / "pdg_tde_same.per")
        cluster = _make_cluster(
            tmp_path,
            install_dir,
            io_method,
            subdir="tde_same",
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        cluster.execute(
            "CREATE TABLE tde_mig (id INT) USING tde_heap; "
            "INSERT INTO tde_mig SELECT generate_series(1, 100);"
        )

        cluster.stop()
        cluster.start()
        cluster.wait_ready()

        assert cluster.fetchone("SELECT COUNT(*) FROM tde_mig") == "100"
        cluster.stop()

    def test_tde_heap_data_survives_pg_dumpall_to_target(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        keyfile = str(tmp_path / "pdg_tde_remote.per")
        tde_params = {"shared_preload_libraries": "'pg_tde'"}
        source = _make_cluster(
            tmp_path, install_dir, io_method, subdir="tde_src", extra_params=tde_params
        )
        target = _make_cluster(
            tmp_path, install_dir, io_method, subdir="tde_tgt", extra_params=tde_params
        )
        dump_file = tmp_path / "tde_dumpall.sql"

        source.start()
        tde = TdeManager(source)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        source.execute(
            "CREATE TABLE tde_remote (id INT) USING tde_heap; "
            "INSERT INTO tde_remote VALUES (1),(2),(3);"
        )
        _pg_dumpall(source, dump_file)
        source.stop()

        target.start()
        target.wait_ready()
        _bootstrap_tde_for_restore(target, keyfile)
        _restore_pg_dumpall(target, dump_file, skip_extensions={"pg_tde"})

        assert target.fetchone("SELECT COUNT(*) FROM tde_remote") == "3"
        target.stop()

    def test_tde_config_files_in_backup_set(
        self, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Doc-listed config files exist and are copyable before migration stop."""
        keyfile = str(tmp_path / "pdg_tde_cfg.per")
        cluster = _make_cluster(
            tmp_path,
            install_dir,
            io_method,
            subdir="tde_cfg",
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "pg_tde.wal_encrypt": "off",
            },
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()

        backup_dir = tmp_path / "tde_conf_backup"
        _backup_config_files(cluster.data_dir, backup_dir)
        cluster.stop()

        for name in ("postgresql.conf", "pg_hba.conf"):
            assert (backup_dir / name).is_file(), f"missing backup of {name}"
        assert "pg_tde" in (backup_dir / "postgresql.conf").read_text()


class TestMigratePgTdeCrossMinorVersion:
    """
    In-place package upgrade pg_tde 2.1.x → 2.2.x (same PG major) after migration
    to Percona Distribution — complements migration.html when only packages change.

    Requires ``--old-install-dir`` with pg_tde ``default_version`` 2.1 and
    ``--install-dir`` with 2.2 (e.g. PG 17.9 → 17.10 testing repos).
    """

    def test_restart_before_alter_extension_after_package_swap(
        self,
        old_install_dir: Optional[Path],
        install_dir: Path,
        tmp_path: Path,
        io_method: str,
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")
        old_ver = read_pg_tde_default_version(old_install_dir)
        new_ver = read_pg_tde_default_version(install_dir)
        if not old_ver or not new_ver or old_ver == new_ver:
            pytest.skip(
                f"needs different pg_tde control versions (got old={old_ver!r} "
                f"new={new_ver!r})"
            )

        old_major = postgres_major_version(old_install_dir)
        new_major = postgres_major_version(install_dir)
        if old_major != new_major:
            pytest.skip(
                "in-place pg_tde minor upgrade requires the same PostgreSQL major "
                f"(old={old_major}, new={new_major}); use test_tde_pg_upgrade for "
                "PG major bumps"
            )

        keyfile = str(tmp_path / "cross_minor.per")
        data_dir = tmp_path / "cross_minor_data"
        port = allocate_port()
        old = PgCluster(
            data_dir,
            port,
            old_install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        old.initdb(extra_args=initdb_args_no_data_checksums(old_install_dir))
        old.write_default_config(
            extra_params={"shared_preload_libraries": "'pg_tde'"}
        )
        old.add_hba_entry("local all all trust")
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE minor_mig (n INT) USING tde_heap; "
            "INSERT INTO minor_mig VALUES (1);"
        )
        old.stop()

        # Simulate package upgrade: same PGDATA, binaries from --install-dir (2.2).
        new = PgCluster(
            data_dir,
            port,
            install_dir,
            socket_dir=tmp_path,
            io_method=io_method,
        )
        new.start()
        new.wait_ready(timeout=90)

        bin_ver = (new.fetchone("SELECT pg_tde_version()") or "").strip()
        ext_ver = new.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_ver == old_ver, "extversion must stay at old until ALTER EXTENSION"
        assert "2.2" in bin_ver or new_ver in bin_ver, (
            f"expected new binary after package swap, got {bin_ver!r}"
        )
        assert new.fetchone("SELECT COUNT(*) FROM minor_mig") == "1"

        new.execute("ALTER EXTENSION pg_tde UPDATE")
        ext_after = new.fetchone(
            "SELECT extversion FROM pg_extension WHERE extname='pg_tde'"
        )
        assert ext_after == new_ver
        assert new.fetchone("SELECT COUNT(*) FROM minor_mig") == "1"
        new.stop()
