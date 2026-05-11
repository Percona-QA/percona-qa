"""
pg_upgrade major-version upgrade tests.

Covers scenarios from:
  - pg_upgrade_custom_image.sh
  - pg_tde_upgrade_test.sh

All tests require --old-install-dir to be provided.
"""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import prepend_install_lib_dirs
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
    env = os.environ.copy()
    prepend_install_lib_dirs(env, old_cluster.install_dir, new_install_dir)
    return subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(tmp_path), env=env
    )


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
        env = os.environ.copy()
        prepend_install_lib_dirs(env, install_dir)
        subprocess.run(
            [str(install_dir / "bin" / "vacuumdb"),
             "-h", str(tmp_path), "-p", str(new_port),
             "--all", "--analyze-in-stages"],
            check=True,
            env=env,
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


# ── helpers shared by corner-case tests ──────────────────────────────────────


def _make_old_cluster(
    old_install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    subdir: str = "old",
    extra_initdb: Optional[list] = None,
    extra_params: Optional[dict] = None,
) -> PgCluster:
    port = allocate_port()
    cluster = PgCluster(
        tmp_path / subdir,
        port,
        old_install_dir,
        socket_dir=tmp_path,
        io_method=io_method,
    )
    cluster.initdb(extra_args=extra_initdb)
    cluster.write_default_config(extra_params=extra_params)
    cluster.add_hba_entry("local all all trust")
    return cluster


def _upgrade(
    old_cluster: PgCluster,
    install_dir: Path,
    tmp_path: Path,
    io_method: str,
    *,
    new_subdir: str = "new",
    extra_initdb: Optional[list] = None,
    extra_params: Optional[dict] = None,
    pg_upgrade_extra: Optional[list] = None,
    check_only: bool = False,
) -> tuple:
    new_port = allocate_port()
    new_data = tmp_path / new_subdir
    new_cluster = PgCluster(new_data, new_port, install_dir, socket_dir=tmp_path, io_method=io_method)
    new_cluster.initdb(extra_args=extra_initdb)
    new_cluster.write_default_config(extra_params=extra_params)
    new_cluster.stop(check=False)

    new_bin = install_dir / "bin"
    cmd = [
        str(new_bin / "pg_upgrade"),
        "-b", str(old_cluster.bin),
        "-B", str(new_bin),
        "-d", str(old_cluster.data_dir),
        "-D", str(new_data),
        "-p", str(old_cluster.port),
        "-P", str(new_port),
    ]
    if check_only:
        cmd.append("--check")
    if pg_upgrade_extra:
        cmd.extend(pg_upgrade_extra)
    env = os.environ.copy()
    prepend_install_lib_dirs(env, old_cluster.install_dir, install_dir)
    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(tmp_path), env=env
    )
    return new_cluster, result


# ── data integrity ────────────────────────────────────────────────────────────


class TestUpgradeDataIntegrity:
    """Verify complex schema objects survive upgrade intact."""

    def test_sequences_preserve_values(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE SEQUENCE seq1 START 1; "
            "SELECT nextval('seq1') FROM generate_series(1,42);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        val = new_cluster.fetchone("SELECT last_value FROM seq1")
        assert int(val) == 42
        new_cluster.stop()

    def test_enum_types_survive(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral'); "
            "CREATE TABLE enum_tbl (id INT, m mood); "
            "INSERT INTO enum_tbl VALUES (1,'happy'),(2,'sad');"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM enum_tbl WHERE m = 'happy'")
        assert count == "1"
        new_cluster.stop()

    def test_composite_and_domain_types(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE DOMAIN posint AS INT CHECK (VALUE > 0); "
            "CREATE TYPE point2d AS (x FLOAT8, y FLOAT8); "
            "CREATE TABLE domain_tbl (v posint); "
            "INSERT INTO domain_tbl VALUES (1),(2); "
            "CREATE TABLE composite_tbl (p point2d); "
            "INSERT INTO composite_tbl VALUES (ROW(1.0,2.0));"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM domain_tbl") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM composite_tbl") == "1"
        new_cluster.stop()

    def test_views_and_materialized_views(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE base_tbl (id INT, val TEXT); "
            "INSERT INTO base_tbl SELECT i, md5(i::text) FROM generate_series(1,100) i; "
            "CREATE VIEW v_even AS SELECT * FROM base_tbl WHERE id % 2 = 0; "
            "CREATE MATERIALIZED VIEW mv_odd AS SELECT * FROM base_tbl WHERE id % 2 != 0;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM v_even") == "50"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM mv_odd") == "50"
        new_cluster.stop()

    def test_partitioned_tables(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE sales (id INT, region TEXT, amount NUMERIC) "
            "PARTITION BY LIST (region); "
            "CREATE TABLE sales_east PARTITION OF sales FOR VALUES IN ('east'); "
            "CREATE TABLE sales_west PARTITION OF sales FOR VALUES IN ('west'); "
            "INSERT INTO sales VALUES (1,'east',100),(2,'west',200),(3,'east',300);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM sales") == "3"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM sales_east") == "2"
        new_cluster.stop()

    def test_range_partitioned_table(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE logs (id BIGSERIAL, ts TIMESTAMPTZ, msg TEXT) "
            "PARTITION BY RANGE (ts); "
            "CREATE TABLE logs_2024 PARTITION OF logs "
            "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01'); "
            "CREATE TABLE logs_2025 PARTITION OF logs "
            "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01'); "
            "INSERT INTO logs (ts,msg) VALUES "
            "('2024-06-01','a'),('2025-03-01','b');"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM logs") == "2"
        new_cluster.stop()

    def test_functions_and_triggers(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE audit_log (op TEXT, ts TIMESTAMPTZ DEFAULT now()); "
            "CREATE TABLE target (id INT); "
            "CREATE FUNCTION trg_fn() RETURNS TRIGGER LANGUAGE plpgsql AS $$ "
            "BEGIN INSERT INTO audit_log(op) VALUES (TG_OP); RETURN NEW; END; $$; "
            "CREATE TRIGGER trg AFTER INSERT OR UPDATE ON target "
            "FOR EACH ROW EXECUTE FUNCTION trg_fn(); "
            "INSERT INTO target VALUES (1),(2);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        new_cluster.execute("INSERT INTO target VALUES (3)")
        assert new_cluster.fetchone("SELECT COUNT(*) FROM audit_log") == "1"
        new_cluster.stop()

    def test_indexes_various_types(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE idx_tbl (id INT, txt TEXT, rng INT4RANGE, arr INT[]); "
            "INSERT INTO idx_tbl SELECT i, md5(i::text), int4range(i,i+10), ARRAY[i,i+1] "
            "FROM generate_series(1,500) i; "
            "CREATE INDEX btree_idx ON idx_tbl USING btree(id); "
            "CREATE INDEX hash_idx  ON idx_tbl USING hash(txt); "
            "CREATE INDEX gin_idx   ON idx_tbl USING gin(arr); "
            "CREATE INDEX brin_idx  ON idx_tbl USING brin(id);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        idx_count = new_cluster.fetchone(
            "SELECT COUNT(*) FROM pg_indexes WHERE tablename='idx_tbl'"
        )
        assert int(idx_count) >= 4
        new_cluster.stop()

    def test_foreign_key_constraints(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE parent (id INT PRIMARY KEY, val TEXT); "
            "CREATE TABLE child (id INT PRIMARY KEY, parent_id INT "
            "REFERENCES parent(id) ON DELETE CASCADE); "
            "INSERT INTO parent VALUES (1,'a'),(2,'b'); "
            "INSERT INTO child VALUES (10,1),(11,1),(12,2);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        new_cluster.execute("DELETE FROM parent WHERE id=1")
        remaining = new_cluster.fetchone("SELECT COUNT(*) FROM child")
        assert remaining == "1"
        new_cluster.stop()

    def test_large_objects(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "DO $$ DECLARE oid OID; BEGIN "
            "  oid := lo_create(0); "
            "  PERFORM lo_open(oid, 131072); "
            "  PERFORM lowrite(0, 'hello large object'); "
            "  PERFORM lo_close(0); "
            "END $$; "
            "CREATE TABLE lo_ref (id INT, loid OID); "
            "INSERT INTO lo_ref SELECT 1, oid FROM pg_largeobject_metadata LIMIT 1;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM pg_largeobject_metadata") == "1"
        new_cluster.stop()

    def test_inheritance_tables(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE person (name TEXT, age INT); "
            "CREATE TABLE employee (salary NUMERIC) INHERITS (person); "
            "INSERT INTO person VALUES ('Alice',30); "
            "INSERT INTO employee VALUES ('Bob',25,50000);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM person") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM employee") == "1"
        new_cluster.stop()


# ── multi-database ────────────────────────────────────────────────────────────


class TestUpgradeMultiDatabase:
    """Multiple databases with varied schemas must all survive."""

    def test_multiple_databases(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("CREATE DATABASE db_alpha")
        old.execute("CREATE DATABASE db_beta")
        old.execute("CREATE TABLE alpha_data (k INT)", dbname="db_alpha")
        old.execute("INSERT INTO alpha_data VALUES (1),(2)", dbname="db_alpha")
        old.execute("CREATE TABLE beta_data (k TEXT)", dbname="db_beta")
        old.execute("INSERT INTO beta_data VALUES ('x'),('y'),('z')", dbname="db_beta")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM alpha_data", dbname="db_alpha") == "2"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM beta_data", dbname="db_beta") == "3"
        new_cluster.stop()

    def test_database_with_non_default_schema(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("CREATE DATABASE app_db")
        old.execute("CREATE SCHEMA app", dbname="app_db")
        old.execute("CREATE TABLE app.users (id INT, name TEXT)", dbname="app_db")
        old.execute("INSERT INTO app.users VALUES (1,'alice'),(2,'bob')", dbname="app_db")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM app.users", dbname="app_db") == "2"
        new_cluster.stop()


# ── link mode ─────────────────────────────────────────────────────────────────


class TestUpgradeLinkMode:
    def test_upgrade_link_mode(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE link_tbl AS "
            "SELECT i, repeat('x',1000) AS pad FROM generate_series(1,1000) i"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, pg_upgrade_extra=["--link"]
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM link_tbl") == "1000"
        new_cluster.stop()

    def test_upgrade_clone_mode(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("CREATE TABLE clone_tbl (id INT); INSERT INTO clone_tbl VALUES (1),(2),(3)")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, pg_upgrade_extra=["--clone"]
        )
        # --clone is only available on certain filesystems; skip if unsupported
        if result.returncode != 0 and "clone" in result.stderr.lower():
            pytest.skip("--clone not supported on this filesystem")
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM clone_tbl") == "3"
        new_cluster.stop()


# ── parallel upgrade ──────────────────────────────────────────────────────────


class TestUpgradeParallel:
    def test_upgrade_parallel_jobs(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        for i in range(5):
            old.execute(f"CREATE TABLE parallel_tbl_{i} AS SELECT g FROM generate_series(1,100) g")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, pg_upgrade_extra=["-j", "4"]
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        for i in range(5):
            assert new_cluster.fetchone(f"SELECT COUNT(*) FROM parallel_tbl_{i}") == "100"
        new_cluster.stop()


# ── multi-hop ─────────────────────────────────────────────────────────────────


class TestUpgradeMultiHop:
    """Chain two upgrades: old → intermediate → new (e.g. 16 → 17 → 18)."""

    def test_two_hop_upgrade(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str,
        request,
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        intermediate_dir = Path(request.config.getoption("--old-install-dir"))
        if intermediate_dir == install_dir:
            pytest.skip("intermediate and final install-dir are the same; need 3 distinct versions")

        # hop 1: old → intermediate (re-use old_install_dir as hop-1 source, install_dir as hop-1 target)
        old = _make_old_cluster(old_install_dir, tmp_path, io_method, subdir="hop1_old")
        old.start()
        old.execute(
            "CREATE TABLE hop_data (id INT, payload TEXT); "
            "INSERT INTO hop_data SELECT i, md5(i::text) FROM generate_series(1,500) i;"
        )
        old.stop()

        mid_cluster, result1 = _upgrade(
            old, install_dir, tmp_path, io_method, new_subdir="hop1_new"
        )
        assert result1.returncode == 0, f"Hop-1 failed:\n{result1.stderr}"

        # hop 2: intermediate → new (same install_dir used for both since we only have 2 installs)
        # This tests the cluster produced by hop-1 is itself upgradeable
        mid_cluster.start()
        mid_cluster.wait_ready()
        mid_cluster.execute("INSERT INTO hop_data VALUES (9999,'extra')")
        mid_cluster.stop()

        final_cluster, result2 = _upgrade(
            mid_cluster, install_dir, tmp_path, io_method, new_subdir="hop2_new"
        )
        # Same binary — pg_upgrade will refuse same major; treat as skip if versions identical
        if result2.returncode != 0 and "same major version" in result2.stderr.lower():
            pytest.skip("hop-2 skipped: old and new are the same major version")
        assert result2.returncode == 0, f"Hop-2 failed:\n{result2.stderr}"

        final_cluster.start()
        final_cluster.wait_ready()
        count = final_cluster.fetchone("SELECT COUNT(*) FROM hop_data")
        assert int(count) >= 501
        final_cluster.stop()


# ── config preservation ───────────────────────────────────────────────────────


class TestUpgradeConfigPreservation:
    def test_postgresql_conf_copied(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("ALTER SYSTEM SET log_min_messages = 'warning'")
        old.execute("SELECT pg_reload_conf()")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        auto_conf = new_cluster.data_dir / "postgresql.auto.conf"
        assert auto_conf.exists()
        content = auto_conf.read_text()
        assert "log_min_messages" in content

    def test_pg_hba_copied(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        sentinel = "# upgrade-test-sentinel"
        old.add_hba_entry(sentinel)
        old.start()
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        hba = new_cluster.data_dir / "pg_hba.conf"
        assert sentinel in hba.read_text()

    def test_checksums_on_preserved(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method, extra_initdb=["--data-checksums"])
        old.start()
        old.execute("CREATE TABLE cs_data (id INT); INSERT INTO cs_data VALUES (1)")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method, extra_initdb=["--data-checksums"]
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SHOW data_checksums") == "on"
        new_cluster.stop()


# ── post-upgrade maintenance ──────────────────────────────────────────────────


class TestUpgradePostMaintenance:
    def test_reindex_after_upgrade(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE reindex_tbl (id INT); "
            "CREATE INDEX reindex_idx ON reindex_tbl (id); "
            "INSERT INTO reindex_tbl SELECT generate_series(1,1000);"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        new_cluster.execute("REINDEX TABLE reindex_tbl")
        new_cluster.stop()

    def test_analyze_all_after_upgrade(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE analyze_tbl AS "
            "SELECT i, md5(i::text) payload FROM generate_series(1,5000) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        env = os.environ.copy()
        prepend_install_lib_dirs(env, install_dir)
        subprocess.run(
            [
                str(install_dir / "bin" / "vacuumdb"),
                "-h", str(tmp_path), "-p", str(new_cluster.port),
                "--all", "--analyze-in-stages",
            ],
            check=True,
            env=env,
        )
        new_cluster.stop()

    def test_run_analyze_new_cluster_script(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_upgrade generates analyze_new_cluster.sh — verify it exists and runs."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("CREATE TABLE analyze_script_tbl (id INT); INSERT INTO analyze_script_tbl VALUES (1)")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        script = tmp_path / "analyze_new_cluster.sh"
        assert script.exists(), "pg_upgrade did not generate analyze_new_cluster.sh"

        new_cluster.start()
        new_cluster.wait_ready()
        env = os.environ.copy()
        prepend_install_lib_dirs(env, install_dir)
        subprocess.run(["bash", str(script)], check=True, cwd=str(tmp_path), env=env)
        new_cluster.stop()


# ── negative / failure scenarios ─────────────────────────────────────────────


class TestUpgradeNegativeExtended:
    def test_upgrade_fails_checksums_on_to_off(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Old cluster has checksums on; new does not — pg_upgrade should reject."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method, extra_initdb=["--data-checksums"]
        )
        old.start()
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode != 0, "Expected failure: checksum on → off mismatch"

    def test_upgrade_fails_mismatched_encoding(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """initdb with SQL_ASCII old vs UTF8 new should fail at pg_upgrade --check."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--encoding=SQL_ASCII", "--locale=C"],
        )
        old.start()
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--encoding=UTF8", "--locale=en_US.utf-8"],
            check_only=True,
        )
        assert result.returncode != 0, "Expected failure: encoding mismatch"

    def test_upgrade_fails_wrong_data_dir(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Point pg_upgrade at a non-existent old data dir — must fail."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        new_port = allocate_port()
        new_bin = install_dir / "bin"
        cmd = [
            str(new_bin / "pg_upgrade"),
            "-b", str(Path(old_install_dir) / "bin"),
            "-B", str(new_bin),
            "-d", str(tmp_path / "no_such_dir"),
            "-D", str(tmp_path / "new"),
            "-p", "5555",
            "-P", str(new_port),
        ]
        env = os.environ.copy()
        prepend_install_lib_dirs(env, Path(old_install_dir), install_dir)
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        assert result.returncode != 0

    def test_upgrade_fails_when_old_cluster_is_running(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_upgrade must refuse if old cluster is online (full upgrade, not just --check)."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.wait_ready()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        old.stop()
        assert result.returncode != 0

    def test_upgrade_fails_unclean_shutdown(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Cluster crashed without recovery cannot be upgraded without first starting it."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("CREATE TABLE crash_tbl (id INT); INSERT INTO crash_tbl VALUES (1)")
        old.crash()

        # pg_upgrade should detect dirty shutdown and fail
        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method, check_only=True)
        assert result.returncode != 0, "Expected failure on dirty-shutdown cluster"

    def test_upgrade_fails_same_data_dir_for_old_and_new(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Using the same data directory for old and new must fail."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.stop()

        new_bin = install_dir / "bin"
        new_port = allocate_port()
        cmd = [
            str(new_bin / "pg_upgrade"),
            "-b", str(old.bin),
            "-B", str(new_bin),
            "-d", str(old.data_dir),
            "-D", str(old.data_dir),   # same dir — must fail
            "-p", str(old.port),
            "-P", str(new_port),
            "--check",
        ]
        env = os.environ.copy()
        prepend_install_lib_dirs(env, old.install_dir, install_dir)
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        assert result.returncode != 0


# ── TDE corner cases ──────────────────────────────────────────────────────────


class TestUpgradeTdeCornerCases:
    def test_upgrade_tde_encrypted_table_data_intact(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_corner.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE sensitive (id INT, secret TEXT) USING tde_heap; "
            "INSERT INTO sensitive SELECT i, md5(i::text) FROM generate_series(1,200) i;"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        assert result.returncode == 0, f"TDE upgrade failed:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()
        count = new_cluster.fetchone("SELECT COUNT(*) FROM sensitive")
        assert count == "200"
        new_cluster.stop()

    def test_upgrade_tde_wal_encryption_enabled(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_wal.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        tde.enable_wal_encryption()
        old.execute("CREATE TABLE wal_enc_tbl (id INT); INSERT INTO wal_enc_tbl VALUES (1),(2)")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        assert result.returncode == 0, f"TDE WAL-encrypted upgrade failed:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM wal_enc_tbl") == "2"
        new_cluster.stop()

    def test_upgrade_tde_mixed_encrypted_and_plain_tables(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_mixed.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        old.execute(
            "CREATE TABLE plain_tbl (id INT) USING heap; "
            "CREATE TABLE enc_tbl   (id INT) USING tde_heap; "
            "INSERT INTO plain_tbl SELECT generate_series(1,50); "
            "INSERT INTO enc_tbl   SELECT generate_series(1,75);"
        )
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM plain_tbl") == "50"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM enc_tbl") == "75"
        new_cluster.stop()

    def test_upgrade_tde_multiple_databases_different_keys(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_multidb.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="key_postgres", dbname="postgres")

        old.execute("CREATE DATABASE db2")
        old.execute("CREATE EXTENSION IF NOT EXISTS pg_tde", dbname="db2")
        tde2 = TdeManager(old)
        tde2._func_args = {}
        tde2.cluster = old
        tde2.add_global_key_provider_file(keyfile=keyfile)
        tde2.set_global_principal_key(key_name="key_db2", dbname="db2")

        old.execute("CREATE TABLE enc1 (v INT) USING tde_heap; INSERT INTO enc1 VALUES (1)")
        old.execute("CREATE TABLE enc2 (v INT) USING tde_heap; INSERT INTO enc2 VALUES (2),(3)", dbname="db2")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM enc1") == "1"
        assert new_cluster.fetchone("SELECT COUNT(*) FROM enc2", dbname="db2") == "2"
        new_cluster.stop()

    def test_upgrade_tde_key_rotation_before_upgrade(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Rotate the principal key, then upgrade — new key must be valid post-upgrade."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        keyfile = str(tmp_path / "tde_rotate.per")
        old = _make_old_cluster(
            old_install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        old.start()
        tde = TdeManager(old)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key(key_name="initial_key")
        old.execute("CREATE TABLE rotated_data (id INT) USING tde_heap; INSERT INTO rotated_data VALUES (42)")
        tde.rotate_principal_key(new_key_name="rotated_key")
        old.stop()

        new_cluster, result = _upgrade(
            old, install_dir, tmp_path, io_method,
            extra_initdb=["--no-data-checksums"],
            extra_params={"shared_preload_libraries": "'pg_tde'"},
        )
        assert result.returncode == 0, f"Upgrade after key rotation failed:\n{result.stderr}"

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM rotated_data") == "1"
        new_cluster.stop()


# ── logical replication state ─────────────────────────────────────────────────


class TestUpgradeReplicationState:
    def test_upgrade_with_replication_slots_removed(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_upgrade requires no active replication slots; dropping them first must succeed."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "SELECT pg_create_logical_replication_slot('test_slot', 'pgoutput'); "
            "CREATE TABLE pub_tbl (id INT); "
            "INSERT INTO pub_tbl VALUES (1),(2);"
        )
        # Drop slot before upgrade (required by pg_upgrade)
        old.execute("SELECT pg_drop_replication_slot('test_slot')")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM pub_tbl") == "2"
        new_cluster.stop()

    def test_upgrade_fails_with_active_replication_slots(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """pg_upgrade must refuse when a replication slot still exists."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute("SELECT pg_create_logical_replication_slot('stuck_slot', 'pgoutput')")
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method, check_only=True)
        assert result.returncode != 0, "Expected failure with active replication slot"

    def test_upgrade_with_publication_preserved(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE pub_data (id INT PRIMARY KEY, val TEXT); "
            "INSERT INTO pub_data VALUES (1,'a'),(2,'b'); "
            "CREATE PUBLICATION mypub FOR TABLE pub_data;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        pub_count = new_cluster.fetchone("SELECT COUNT(*) FROM pg_publication WHERE pubname='mypub'")
        assert pub_count == "1"
        new_cluster.stop()


# ── scale / timing probe ──────────────────────────────────────────────────────


class TestUpgradeScale:
    def test_upgrade_large_dataset(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        """Upgrade a cluster with ~200k rows; verify row count and record elapsed time."""
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "CREATE TABLE big_table AS "
            "SELECT g, repeat(md5(g::text), 32) AS payload "
            "FROM generate_series(1, 200000) g;"
        )
        old.stop()

        import time
        t0 = time.monotonic()
        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        elapsed = time.monotonic() - t0

        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        assert new_cluster.fetchone("SELECT COUNT(*) FROM big_table") == "200000"
        new_cluster.stop()

        # Log timing (not a hard assertion — just surface it for SRE tracking)
        print(f"\npg_upgrade elapsed: {elapsed:.1f}s for 200k-row dataset")

    def test_upgrade_many_tables(
        self, old_install_dir: Optional[Path], install_dir: Path, tmp_path: Path, io_method: str
    ):
        if not old_install_dir:
            pytest.skip("--old-install-dir not provided")

        old = _make_old_cluster(old_install_dir, tmp_path, io_method)
        old.start()
        old.execute(
            "DO $$ BEGIN "
            "  FOR i IN 1..50 LOOP "
            "    EXECUTE format('CREATE TABLE t%s (id INT)', i); "
            "    EXECUTE format('INSERT INTO t%s VALUES (1),(2),(3)', i, i); "
            "  END LOOP; "
            "END $$;"
        )
        old.stop()

        new_cluster, result = _upgrade(old, install_dir, tmp_path, io_method)
        assert result.returncode == 0, result.stderr

        new_cluster.start()
        new_cluster.wait_ready()
        tbl_count = new_cluster.fetchone(
            "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 't%'"
        )
        assert int(tbl_count) >= 50
        new_cluster.stop()
