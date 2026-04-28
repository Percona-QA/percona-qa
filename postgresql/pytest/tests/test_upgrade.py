"""
pg_upgrade major-version upgrade tests.

Covers scenarios from:
  - pg_upgrade_custom_image.sh
  - pg_tde_upgrade_test.sh

All tests require --old-install-dir to be provided.
"""
import shutil
import subprocess
from pathlib import Path
from typing import Optional

import pytest

from lib import PgCluster, TdeManager
from conftest import allocate_port


pytestmark = [pytest.mark.upgrade, pytest.mark.slow]


# ── helpers ───────────────────────────────────────────────────────────────────


def _run_pg_upgrade(
    old_cluster: PgCluster,
    new_install_dir: Path,
    new_data_dir: Path,
    new_port: int,
    tmp_path: Path,
    check_only: bool = False,
) -> subprocess.CompletedProcess:
    new_bin = new_install_dir / "bin"
    cmd = [
        str(new_bin / "pg_upgrade"),
        "-b", str(old_cluster.bin),
        "-B", str(new_bin),
        "-d", str(old_cluster.data_dir),
        "-D", str(new_data_dir),
        "-p", str(old_cluster.port),
        "-P", str(new_port),
    ]
    if check_only:
        cmd.append("--check")
    return subprocess.run(cmd, capture_output=True, text=True, cwd=str(tmp_path))


# ── fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def old_cluster(old_install_dir: Optional[Path], tmp_path: Path, io_method: str):
    """A stopped old-version cluster with sample data, ready for pg_upgrade."""
    if not old_install_dir:
        pytest.skip("--old-install-dir not provided")
    port = allocate_port()
    cluster = PgCluster(tmp_path / "old_data", port, old_install_dir,
                        socket_dir=tmp_path, io_method=io_method)
    cluster.initdb()
    cluster.write_default_config()
    cluster.add_hba_entry("local all all trust")
    cluster.start()
    cluster.execute("CREATE TABLE upgrade_smoke (id INT, data TEXT)")
    cluster.execute(
        "INSERT INTO upgrade_smoke SELECT i, md5(i::text) FROM generate_series(1,1000) i"
    )
    cluster.stop()
    yield cluster


# ── smoke ─────────────────────────────────────────────────────────────────────


class TestPgUpgradeSmoke:
    def test_upgrade_check_passes(self, old_cluster: PgCluster, install_dir: Path, tmp_path: Path):
        new_port = allocate_port()
        new_data = tmp_path / "new_data_check"
        new_data.mkdir()
        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path, check_only=True)
        assert result.returncode == 0, f"pg_upgrade --check failed:\n{result.stdout}\n{result.stderr}"

    def test_upgrade_succeeds(self, old_cluster: PgCluster, install_dir: Path, tmp_path: Path, io_method: str):
        new_port = allocate_port()
        new_data = tmp_path / "new_data"
        # initdb the new cluster first
        new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
        new_cluster.initdb()
        new_cluster.stop(check=False)

        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path)
        assert result.returncode == 0, f"pg_upgrade failed:\n{result.stdout}\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM upgrade_smoke")
        assert count == "1000"
        new_cluster.stop()

    def test_post_upgrade_vacuum_analyze(self, old_cluster: PgCluster, install_dir: Path, tmp_path: Path, io_method: str):
        new_port = allocate_port()
        new_data = tmp_path / "new_data_vacuumdb"
        new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
        new_cluster.initdb()
        new_cluster.stop(check=False)

        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path)
        assert result.returncode == 0

        new_cluster.start()
        new_cluster.wait_ready()
        subprocess.run(
            [str(install_dir / "bin" / "vacuumdb"),
             "-h", str(tmp_path), "-p", str(new_port),
             "--all", "--analyze-in-stages"],
            check=True,
        )
        new_cluster.stop()


# ── data checksums ────────────────────────────────────────────────────────────


class TestUpgradeWithChecksums:
    def test_upgrade_checksums_on_to_on(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")
        old_port = allocate_port()
        old_cluster = PgCluster(tmp_path / "cs_old", old_port, old_install_dir,
                                socket_dir=tmp_path, io_method=io_method)
        old_cluster.initdb(extra_args=["--data-checksums"])
        old_cluster.write_default_config()
        old_cluster.add_hba_entry("local all all trust")
        old_cluster.start()
        old_cluster.execute("CREATE TABLE cs_tbl (id INT)")
        old_cluster.execute("INSERT INTO cs_tbl SELECT generate_series(1,100)")
        old_cluster.stop()

        new_port = allocate_port()
        new_data = tmp_path / "cs_new"
        new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
        new_cluster.initdb(extra_args=["--data-checksums"])
        new_cluster.stop(check=False)

        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path)
        assert result.returncode == 0
        new_cluster.start()
        checksum_status = new_cluster.fetchone("SHOW data_checksums")
        assert checksum_status == "on"
        new_cluster.stop()

    def test_upgrade_checksums_off_to_on(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")
        old_port = allocate_port()
        old_cluster = PgCluster(tmp_path / "ncs_old", old_port, old_install_dir,
                                socket_dir=tmp_path, io_method=io_method)
        old_cluster.initdb()
        old_cluster.write_default_config()
        old_cluster.add_hba_entry("local all all trust")
        old_cluster.start()
        old_cluster.execute("CREATE TABLE ncs_tbl (id INT)")
        old_cluster.execute("INSERT INTO ncs_tbl SELECT generate_series(1,100)")
        old_cluster.stop()

        new_port = allocate_port()
        new_data = tmp_path / "ncs_new"
        new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
        new_cluster.initdb(extra_args=["--data-checksums"])
        new_cluster.stop(check=False)

        # pg_upgrade should reject mismatched checksum settings
        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path)
        assert result.returncode != 0, "Expected failure when checksum settings differ"


# ── extension compatibility ───────────────────────────────────────────────────


class TestUpgradeExtensions:
    def test_upgrade_with_pg_tde_extension(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old_port = allocate_port()
        old_cluster = PgCluster(tmp_path / "tde_old", old_port, old_install_dir,
                                socket_dir=tmp_path, io_method=io_method)
        old_cluster.initdb(extra_args=["--no-data-checksums"])
        old_cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'"})
        old_cluster.add_hba_entry("local all all trust")
        old_cluster.start()
        tde = TdeManager(old_cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_upgrade.per")
        tde.set_global_principal_key()
        old_cluster.execute("CREATE TABLE tde_upgrade_data (id INT)")
        old_cluster.execute("INSERT INTO tde_upgrade_data SELECT generate_series(1,500)")
        old_cluster.stop()

        new_port = allocate_port()
        new_data = tmp_path / "tde_new"
        new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
        new_cluster.initdb(extra_args=["--no-data-checksums"])
        new_cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'"})
        new_cluster.stop(check=False)

        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path)
        assert result.returncode == 0, f"pg_upgrade with TDE failed:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM tde_upgrade_data")
        assert count == "500"
        new_cluster.stop()


# ── negative tests ────────────────────────────────────────────────────────────


class TestUpgradeNegative:
    def test_upgrade_fails_wrong_binaries(
        self, old_cluster: PgCluster, tmp_path: Path
    ):
        new_port = allocate_port()
        # Intentionally pass old binaries as new — pg_upgrade should catch version mismatch
        result = _run_pg_upgrade(
            old_cluster, old_cluster.install_dir, tmp_path / "wrong_new", new_port, tmp_path
        )
        assert result.returncode != 0

    def test_upgrade_check_on_running_cluster_fails(
        self, old_cluster: PgCluster, install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_upgrade should fail if old cluster is still running."""
        old_cluster.start()
        old_cluster.wait_ready()
        new_port = allocate_port()
        new_data = tmp_path / "running_new"
        result = _run_pg_upgrade(old_cluster, install_dir, new_data, new_port, tmp_path, check_only=True)
        old_cluster.stop()
        assert result.returncode != 0
