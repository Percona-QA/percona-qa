"""
Bug reproduction tests.

Covers:
  - PG-1805: Invalid page in unlogged table with IDENTITY column after recovery
  - PG-1806: Invalid page after tablespace move + index create with pg_tde and
             wal_level=minimal, wal_skip_threshold=0
"""
import os
import subprocess
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from conftest import allocate_port


pytestmark = pytest.mark.bug


# ── PG-1805 helpers ───────────────────────────────────────────────────────────


def _remove_relation_forks(cluster: PgCluster, table: str, dbname: str = "postgres") -> None:
    """
    Delete the main fork file for *table*, mimicking what PostgreSQL does when
    restarting after a crash for an UNLOGGED relation (it re-initialises from
    the init fork).  This exercises the recovery path that PG-1805 tickles.
    """
    rel_path = cluster.fetchone(
        f"SELECT pg_relation_filepath('{table}'::regclass)", dbname
    )
    if rel_path:
        full_path = cluster.data_dir / rel_path
        for suffix in ("", "_vm", "_fsm"):
            candidate = Path(str(full_path) + suffix)
            candidate.unlink(missing_ok=True)


# ── PG-1805 ───────────────────────────────────────────────────────────────────


class TestPG1805:
    """
    PG-1805: pg_tde — unlogged table with IDENTITY column triggers
    "invalid page in block 0" on the first INSERT after recovery.

    Three variants are tested:
      - unlogged + identity (the failing case the bug targets)
      - logged + identity  (should always work)
      - unlogged, no identity (should always work)
    """

    def _setup_tde_cluster(self, pg_factory):
        cluster = pg_factory("pg1805")
        cluster.initdb(extra_args=["--no-data-checksums"])
        cluster.write_default_config()
        cluster.add_hba_entry("local all all trust")
        tde = TdeManager(cluster)
        tde.enable_preload()
        tde.enable_tde_heap()
        cluster.start()
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_1805.per")
        tde.set_global_principal_key()
        return cluster

    def test_unlogged_with_identity_survives_recovery(self, pg_factory):
        """
        Regression: after PG-1805 fix, an UNLOGGED table with an IDENTITY column
        must be queryable after recovery (not return 'invalid page in block 0').
        """
        cluster = self._setup_tde_cluster(pg_factory)
        cluster.execute(
            "CREATE UNLOGGED TABLE unlogged_identity ("
            "  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,"
            "  val TEXT"
            ")"
        )
        cluster.execute("INSERT INTO unlogged_identity (val) VALUES ('before_crash')")
        cluster.execute("CHECKPOINT")

        _remove_relation_forks(cluster, "unlogged_identity")
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()

        # After recovery the UNLOGGED table is re-initialised from its init fork.
        # PG-1805 fix: the identity sequence block must also be re-initialised cleanly.
        try:
            cluster.execute("INSERT INTO unlogged_identity (val) VALUES ('after_recovery')")
        except RuntimeError as e:
            pytest.fail(
                f"PG-1805 NOT FIXED: INSERT failed after crash recovery on unlogged "
                f"table with IDENTITY column.\n{e}\nServer log:\n{cluster.read_log()}"
            )
        count = cluster.fetchone("SELECT COUNT(*) FROM unlogged_identity")
        assert count == "1", (
            "Expected exactly one row after recovery — if 0 rows or an error, PG-1805 is not fixed"
        )

    def test_logged_table_with_identity_unaffected(self, pg_factory):
        """Logged tables with IDENTITY must never be affected by the PG-1805 code path."""
        cluster = self._setup_tde_cluster(pg_factory)
        cluster.execute(
            "CREATE TABLE logged_identity ("
            "  id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,"
            "  val TEXT"
            ")"
        )
        cluster.execute("INSERT INTO logged_identity (val) VALUES ('before_crash')")
        cluster.execute("CHECKPOINT")
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        cluster.execute("INSERT INTO logged_identity (val) VALUES ('after_recovery')")
        count = cluster.fetchone("SELECT COUNT(*) FROM logged_identity")
        assert count == "2"

    def test_unlogged_without_identity_unaffected(self, pg_factory):
        """Unlogged tables WITHOUT an IDENTITY column must also be unaffected."""
        cluster = self._setup_tde_cluster(pg_factory)
        cluster.execute(
            "CREATE UNLOGGED TABLE unlogged_no_identity (id INT, val TEXT)"
        )
        cluster.execute("INSERT INTO unlogged_no_identity VALUES (1, 'before_crash')")
        cluster.execute("CHECKPOINT")
        _remove_relation_forks(cluster, "unlogged_no_identity")
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        # Table is re-initialised empty; new inserts must succeed
        cluster.execute("INSERT INTO unlogged_no_identity VALUES (2, 'after_recovery')")
        count = cluster.fetchone("SELECT COUNT(*) FROM unlogged_no_identity")
        assert count == "1"


# ── PG-1806 ───────────────────────────────────────────────────────────────────


class TestPG1806:
    """
    PG-1806: pg_tde WAL optimisation — "invalid page in block 0" after a
    tablespace move combined with an index creation in the same transaction
    when wal_level=minimal and wal_skip_threshold=0.

    The fix must ensure that the WAL for such operations is always written
    correctly so that crash recovery does not produce a corrupt page.
    """

    def _setup_cluster(self, pg_factory, tmp_path: Path) -> tuple:
        tsp_dir = tmp_path / "extra_tablespace"
        tsp_dir.mkdir()

        cluster = pg_factory("pg1806")
        cluster.initdb(extra_args=["--no-data-checksums"])
        cluster.write_default_config()
        cluster.add_hba_entry("local all all trust")

        tde = TdeManager(cluster)
        tde.enable_preload()
        tde.enable_tde_heap()
        # These two GUCs together are the trigger condition for PG-1806
        cluster.configure(
            {
                "wal_level": "minimal",
                "wal_skip_threshold": "0",
            }
        )
        cluster.start()
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_1806.per")
        tde.set_global_principal_key()
        return cluster, tsp_dir

    def test_tablespace_move_and_index_survives_crash(self, pg_factory, tmp_path: Path):
        """
        The single-transaction combination of ALTER TABLE SET TABLESPACE +
        CREATE UNIQUE INDEX must not produce invalid pages after recovery.
        """
        cluster, tsp_dir = self._setup_cluster(pg_factory, tmp_path)

        cluster.execute(f"CREATE TABLESPACE extra_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE tbl_a (id INT, data TEXT)")
        cluster.execute("INSERT INTO tbl_a SELECT i, md5(i::text) FROM generate_series(1,1000) i")
        cluster.execute("CREATE TABLE tbl_b (id INT PRIMARY KEY, val TEXT)")
        cluster.execute("INSERT INTO tbl_b SELECT i, md5(i::text) FROM generate_series(1,500) i")

        # The bug trigger: both operations in one transaction
        cluster.execute(
            "BEGIN;"
            "ALTER TABLE tbl_a SET TABLESPACE extra_tsp;"
            "CREATE UNIQUE INDEX tbl_b_val_idx ON tbl_b (val);"
            "COMMIT;"
        )

        # Immediate shutdown simulates a dirty crash
        cluster.stop(mode="immediate")
        try:
            cluster.start()
            cluster.wait_ready()
        except Exception as e:
            pytest.fail(
                f"PG-1806 NOT FIXED: cluster failed to start after crash recovery.\n"
                f"{e}\nServer log:\n{cluster.read_log()}"
            )

        # Both tables must be fully accessible after recovery
        try:
            count_a = cluster.fetchone("SELECT COUNT(*) FROM tbl_a")
            count_b = cluster.fetchone("SELECT COUNT(*) FROM tbl_b")
        except RuntimeError as e:
            pytest.fail(
                f"PG-1806 NOT FIXED: query failed after crash recovery.\n"
                f"{e}\nServer log:\n{cluster.read_log()}"
            )
        assert count_a == "1000", f"tbl_a corrupted after crash: {count_a} rows"
        assert count_b == "500", f"tbl_b corrupted after crash: {count_b} rows"
        # Index must be usable
        cluster.execute("INSERT INTO tbl_b VALUES (9999, md5('9999'))")

    def test_wal_level_replica_not_affected(self, pg_factory, tmp_path: Path):
        """With wal_level=replica the bug must never trigger (baseline sanity check)."""
        tsp_dir = tmp_path / "replica_tsp"
        tsp_dir.mkdir()

        cluster = pg_factory("pg1806_replica_wal")
        cluster.initdb(extra_args=["--no-data-checksums"])
        cluster.write_default_config()
        cluster.add_hba_entry("local all all trust")
        tde = TdeManager(cluster)
        tde.enable_preload()
        tde.enable_tde_heap()
        cluster.configure(
            {
                "wal_level": "replica",
                "wal_skip_threshold": "0",
            }
        )
        cluster.start()
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_1806b.per")
        tde.set_global_principal_key()

        cluster.execute(f"CREATE TABLESPACE rep_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE rep_tbl (id INT, data TEXT)")
        cluster.execute("INSERT INTO rep_tbl SELECT i, md5(i::text) FROM generate_series(1,500) i")
        cluster.execute("CREATE TABLE rep_idx_tbl (id INT PRIMARY KEY, val TEXT)")
        cluster.execute("INSERT INTO rep_idx_tbl SELECT i, md5(i::text) FROM generate_series(1,200) i")
        cluster.execute(
            "BEGIN;"
            "ALTER TABLE rep_tbl SET TABLESPACE rep_tsp;"
            "CREATE UNIQUE INDEX rep_idx_tbl_val_idx ON rep_idx_tbl (val);"
            "COMMIT;"
        )
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        count = cluster.fetchone("SELECT COUNT(*) FROM rep_tbl")
        assert count == "500"

    def test_normal_wal_threshold_not_affected(self, pg_factory, tmp_path: Path):
        """With wal_skip_threshold at its default (non-zero) the bug must not trigger."""
        tsp_dir = tmp_path / "default_tsp"
        tsp_dir.mkdir()

        cluster = pg_factory("pg1806_default_threshold")
        cluster.initdb(extra_args=["--no-data-checksums"])
        cluster.write_default_config()
        cluster.add_hba_entry("local all all trust")
        tde = TdeManager(cluster)
        tde.enable_preload()
        tde.enable_tde_heap()
        cluster.configure({"wal_level": "minimal"})  # wal_skip_threshold left at default
        cluster.start()
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile="/tmp/pg_tde_1806c.per")
        tde.set_global_principal_key()

        cluster.execute(f"CREATE TABLESPACE def_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE def_tbl (id INT, data TEXT)")
        cluster.execute("INSERT INTO def_tbl SELECT i, md5(i::text) FROM generate_series(1,500) i")
        cluster.execute("CREATE TABLE def_idx_tbl (id INT PRIMARY KEY, val TEXT)")
        cluster.execute("INSERT INTO def_idx_tbl SELECT i, md5(i::text) FROM generate_series(1,200) i")
        cluster.execute(
            "BEGIN;"
            "ALTER TABLE def_tbl SET TABLESPACE def_tsp;"
            "CREATE UNIQUE INDEX def_idx_tbl_val_idx ON def_idx_tbl (val);"
            "COMMIT;"
        )
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        count = cluster.fetchone("SELECT COUNT(*) FROM def_tbl")
        assert count == "500"
