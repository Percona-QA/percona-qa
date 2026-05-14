"""
Bug reproduction tests.

Covers:
  - PG-1805: Invalid page in unlogged table with IDENTITY column after recovery
  - PG-1806: Invalid page after tablespace move + index create with pg_tde and
             wal_level=minimal, wal_skip_threshold=0
"""
import os
import time
from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums
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
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.start()
        tde = TdeManager(cluster)
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
        keyfile = str(tmp_path / "pg1806_key.per")

        cluster = pg_factory("pg1806")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        # Match steps_to_reproduce_pg-1806_wal_optimise.sh / 018_wal_optimize.pl GUCs.
        cluster.configure(
            {
                "wal_level": "minimal",
                "wal_skip_threshold": "0",
                # write_default_config() sets max_wal_senders=5; with wal_level=minimal
                # postgres refuses to start unless replication senders are disabled.
                "max_wal_senders": "0",
                "max_prepared_transactions": "1",
                "wal_log_hints": "on",
            }
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        # Bash/Perl repro restarts after key materialisation so defaults apply cleanly.
        cluster.restart()
        cluster.wait_ready()
        return cluster, tsp_dir

    def test_tablespace_move_and_index_survives_crash(self, pg_factory, tmp_path: Path):
        """
        Exact PG-1806 trigger from steps_to_reproduce_pg-1806_wal_optimise.sh: in one
        transaction, move ``moved`` to the new tablespace and create a unique index on
        ``originated`` in that same tablespace. After immediate stop/start, both
        relations must be readable and the index must enforce uniqueness.
        """
        cluster, tsp_dir = self._setup_cluster(pg_factory, tmp_path)

        cluster.execute(f"CREATE TABLESPACE extra_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE moved (id INT)")
        cluster.execute("INSERT INTO moved VALUES (1)")

        cluster.execute(
            "BEGIN;"
            "ALTER TABLE moved SET TABLESPACE extra_tsp;"
            "CREATE TABLE originated (id INT);"
            "INSERT INTO originated VALUES (1);"
            "CREATE UNIQUE INDEX ON originated(id) TABLESPACE extra_tsp;"
            "COMMIT;"
        )

        cluster.stop(mode="immediate")
        try:
            cluster.start()
            cluster.wait_ready()
        except Exception as e:
            pytest.fail(
                f"PG-1806 NOT FIXED: cluster failed to start after crash recovery.\n"
                f"{e}\nServer log:\n{cluster.read_log()}"
            )

        try:
            moved_n = cluster.fetchone("SELECT COUNT(*) FROM moved")
        except RuntimeError as e:
            pytest.fail(
                f"PG-1806 NOT FIXED: SELECT from moved failed after recovery.\n"
                f"{e}\nServer log:\n{cluster.read_log()}"
            )
        assert moved_n == "1", f"expected 1 row in moved, got {moved_n}"

        conflict_id = cluster.fetchone(
            "INSERT INTO originated VALUES (1) ON CONFLICT (id) DO UPDATE "
            "SET id = originated.id + 1 RETURNING id"
        )
        assert conflict_id == "2", (
            f"originated unique index not usable after recovery (got {conflict_id!r})"
        )

    def test_wal_level_replica_not_affected(self, pg_factory, tmp_path: Path):
        """With wal_level=replica the bug must never trigger (baseline sanity check)."""
        tsp_dir = tmp_path / "replica_tsp"
        tsp_dir.mkdir()
        keyfile = str(tmp_path / "pg1806_replica_key.per")

        cluster = pg_factory("pg1806_replica_wal")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.configure(
            {
                "wal_level": "replica",
                "wal_skip_threshold": "0",
                "max_wal_senders": "5",
                "max_prepared_transactions": "1",
                "wal_log_hints": "on",
            }
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        cluster.restart()
        cluster.wait_ready()

        cluster.execute(f"CREATE TABLESPACE rep_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE moved (id INT)")
        cluster.execute("INSERT INTO moved VALUES (1)")
        cluster.execute(
            "BEGIN;"
            "ALTER TABLE moved SET TABLESPACE rep_tsp;"
            "CREATE TABLE originated (id INT);"
            "INSERT INTO originated VALUES (1);"
            "CREATE UNIQUE INDEX ON originated(id) TABLESPACE rep_tsp;"
            "COMMIT;"
        )
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        assert cluster.fetchone("SELECT COUNT(*) FROM moved") == "1"
        assert (
            cluster.fetchone(
                "INSERT INTO originated VALUES (1) ON CONFLICT (id) DO UPDATE "
                "SET id = originated.id + 1 RETURNING id"
            )
            == "2"
        )

    def test_max_wal_senders_zero_rejected_then_five_recovers(self, pg_factory, tmp_path: Path):
        """
        Coverage for max_wal_senders values in this bug scenario:
          1) max_wal_senders=0 starts and works with wal_level=replica
          2) switching to max_wal_senders=5 also starts and remains usable
        """
        keyfile = str(tmp_path / "pg1806_sender_toggle_key.per")
        cluster = pg_factory("pg1806_sender_toggle")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            }
        )
        cluster.add_hba_entry("local all all trust")
        cluster.configure(
            {
                "wal_level": "replica",
                "wal_skip_threshold": "0",
                "max_wal_senders": "0",
                "max_prepared_transactions": "1",
                "wal_log_hints": "on",
            }
        )
        cluster.start()
        cluster.wait_ready()

        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        cluster.restart()
        cluster.wait_ready()

        cluster.execute("CREATE TABLE sender_toggle_tbl (id INT PRIMARY KEY, val TEXT)")
        cluster.execute("INSERT INTO sender_toggle_tbl VALUES (1, 'ok_with_zero')")
        assert cluster.fetchone("SELECT COUNT(*) FROM sender_toggle_tbl") == "1"
        assert cluster.fetchone("SHOW max_wal_senders") == "0"

        # Rewrite with sender=5 and validate startup + data access again.
        cluster.configure({"max_wal_senders": "5"})
        cluster.restart()
        cluster.wait_ready()
        assert cluster.fetchone("SHOW max_wal_senders") == "5"
        cluster.execute("INSERT INTO sender_toggle_tbl VALUES (2, 'ok_with_five')")
        assert cluster.fetchone("SELECT COUNT(*) FROM sender_toggle_tbl") == "2"

    def test_normal_wal_threshold_not_affected(self, pg_factory, tmp_path: Path):
        """With wal_skip_threshold at its default (non-zero) the bug must not trigger."""
        tsp_dir = tmp_path / "default_tsp"
        tsp_dir.mkdir()

        keyfile = str(tmp_path / "pg1806_default_threshold_key.per")
        cluster = pg_factory("pg1806_default_threshold")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(extra_params={"shared_preload_libraries": "'pg_tde'", "default_table_access_method": "'tde_heap'"})
        cluster.add_hba_entry("local all all trust")
        cluster.configure(
            {
                "wal_level": "minimal",  # wal_skip_threshold left at default
                # Keep minimal-wal startup valid with framework defaults.
                "max_wal_senders": "0",
                "max_prepared_transactions": "1",
                "wal_log_hints": "on",
            }
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        cluster.restart()
        cluster.wait_ready()

        cluster.execute(f"CREATE TABLESPACE def_tsp LOCATION '{tsp_dir}'")
        cluster.execute("CREATE TABLE moved (id INT)")
        cluster.execute("INSERT INTO moved VALUES (1)")
        cluster.execute(
            "BEGIN;"
            "ALTER TABLE moved SET TABLESPACE def_tsp;"
            "CREATE TABLE originated (id INT);"
            "INSERT INTO originated VALUES (1);"
            "CREATE UNIQUE INDEX ON originated(id) TABLESPACE def_tsp;"
            "COMMIT;"
        )
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()
        assert cluster.fetchone("SELECT COUNT(*) FROM moved") == "1"
        assert (
            cluster.fetchone(
                "INSERT INTO originated VALUES (1) ON CONFLICT (id) DO UPDATE "
                "SET id = originated.id + 1 RETURNING id"
            )
            == "2"
        )


class TestPG1806WalOptimiseSubScenarios:
    """
    Port of the remaining sub-scenarios in ``pg_tde_wal_optimise_test.sh``
    (itself a port of upstream ``recovery/018_wal_optimize.pl``) that the
    PG-1806 trigger above does not cover.

    Every test runs the same crash-recovery contract:
      1. wal_level=minimal, wal_skip_threshold=0
      2. Run a DDL+DML pattern that historically skipped WAL on
         encrypted heap
      3. Immediate stop, restart
      4. Verify data and (where applicable) index/constraint state.

    A regression in pg_tde's WAL optimisation code path would manifest
    as "invalid page in block N", a missing row, or a violated unique
    constraint after recovery.
    """

    def _build_cluster(self, pg_factory, tmp_path: Path) -> tuple:
        """Mirror the bash ``run_wal_optimize`` setup with TDE + extra tablespace."""
        tsp_dir = tmp_path / "extra_tsp"
        tsp_dir.mkdir()
        keyfile = str(tmp_path / "wal_opt_key.per")
        cluster = pg_factory("pg1806_walopt")
        cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
        cluster.write_default_config(
            extra_params={
                "shared_preload_libraries": "'pg_tde'",
                "default_table_access_method": "'tde_heap'",
            }
        )
        cluster.add_hba_entry("local all all trust")
        cluster.configure(
            {
                "wal_level": "minimal",
                "wal_skip_threshold": "0",
                "max_wal_senders": "0",
                "max_prepared_transactions": "1",
                "wal_log_hints": "on",
            }
        )
        cluster.start()
        tde = TdeManager(cluster)
        tde.create_extension()
        tde.add_global_key_provider_file(keyfile=keyfile)
        tde.set_global_principal_key()
        cluster.restart()
        cluster.wait_ready()
        cluster.execute(f"CREATE TABLESPACE extra_tsp LOCATION '{tsp_dir}'")
        return cluster, tsp_dir

    @staticmethod
    def _write_copy_payload(tmp_path: Path) -> Path:
        """3-row CSV file used by several scenarios (matches the bash COPYEOF)."""
        f = tmp_path / "copy_data.txt"
        f.write_text("20000,30000\n20001,30001\n20002,30002\n")
        return f

    @staticmethod
    def _crash_restart(cluster: PgCluster) -> None:
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()

    # ── 1. Truncation optimisation on an empty table ───────────────────────
    def test_truncate_empty_table_survives_crash(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute(
            "BEGIN; CREATE TABLE trunc (id SERIAL PRIMARY KEY); TRUNCATE trunc; COMMIT"
        )
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM trunc") == "0"

    # ── 2. TRUNCATE + INSERT in the same transaction ───────────────────────
    def test_truncate_then_insert_same_xact_survives_crash(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE ti (id SERIAL PRIMARY KEY);"
            "INSERT INTO ti VALUES (DEFAULT);"
            "TRUNCATE ti;"
            "INSERT INTO ti VALUES (DEFAULT);"
            "COMMIT"
        )
        self._crash_restart(cluster)
        # bash expects count=1 min(id)=2 (sequence kept incrementing through TRUNCATE).
        assert cluster.fetchone("SELECT count(*) FROM ti") == "1"
        assert cluster.fetchone("SELECT min(id) FROM ti") == "2"

    # ── 3. TRUNCATE + INSERT + PREPARE TRANSACTION ─────────────────────────
    def test_truncate_insert_prepared_transaction_survives_crash(
        self, pg_factory, tmp_path: Path
    ):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE tp (id SERIAL PRIMARY KEY);"
            "INSERT INTO tp VALUES (DEFAULT);"
            "TRUNCATE tp;"
            "INSERT INTO tp VALUES (DEFAULT);"
            "PREPARE TRANSACTION 't'"
        )
        cluster.execute("COMMIT PREPARED 't'")
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM tp") == "1"
        assert cluster.fetchone("SELECT min(id) FROM tp") == "2"

    # ── 4. End-of-xact WAL when wal_skip_threshold is huge (noskip) ────────
    def test_noskip_wal_threshold_large_insert_survives(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute(
            "SET wal_skip_threshold = '1GB';"
            "BEGIN;"
            "CREATE TABLE noskip (id SERIAL PRIMARY KEY);"
            "INSERT INTO noskip SELECT generate_series(1, 20000);"
            "COMMIT"
        )
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM noskip") == "20000"

    # ── 5. TRUNCATE then COPY (bulk write after truncate) ──────────────────
    def test_truncate_then_copy_survives_crash(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        copy_file = self._write_copy_payload(tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE tc (id SERIAL PRIMARY KEY, id2 INT);"
            "INSERT INTO tc VALUES (DEFAULT, generate_series(1, 3000));"
            "TRUNCATE tc;"
            f"COPY tc FROM '{copy_file}' DELIMITER ',';"
            "COMMIT"
        )
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM tc") == "3"

    # ── 6. SET TABLESPACE rolled back via SAVEPOINT ────────────────────────
    def test_set_tablespace_aborted_in_subtransaction_survives_crash(
        self, pg_factory, tmp_path: Path
    ):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        copy_file = self._write_copy_payload(tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE spc_abort (id SERIAL PRIMARY KEY, id2 INT);"
            "INSERT INTO spc_abort VALUES (DEFAULT, generate_series(1, 3000));"
            "TRUNCATE spc_abort;"
            "SAVEPOINT s;"
            "ALTER TABLE spc_abort SET TABLESPACE extra_tsp; ROLLBACK TO s;"
            f"COPY spc_abort FROM '{copy_file}' DELIMITER ',';"
            "COMMIT"
        )
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM spc_abort") == "3"

    # ── 7. SET TABLESPACE deeply nested savepoints ─────────────────────────
    def test_set_tablespace_nested_subtransactions_survives_crash(
        self, pg_factory, tmp_path: Path
    ):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        copy_file = self._write_copy_payload(tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE spc_nest (id SERIAL PRIMARY KEY, id2 INT);"
            "INSERT INTO spc_nest VALUES (DEFAULT, generate_series(1, 3000));"
            "TRUNCATE spc_nest;"
            "SAVEPOINT s;"
            "  ALTER TABLE spc_nest SET TABLESPACE extra_tsp;"
            "  SAVEPOINT s2;"
            "    ALTER TABLE spc_nest SET TABLESPACE pg_default;"
            "  ROLLBACK TO s2;"
            "  SAVEPOINT s2;"
            "    ALTER TABLE spc_nest SET TABLESPACE pg_default;"
            "  RELEASE s2;"
            "ROLLBACK TO s;"
            f"COPY spc_nest FROM '{copy_file}' DELIMITER ',';"
            "COMMIT"
        )
        self._crash_restart(cluster)
        assert cluster.fetchone("SELECT count(*) FROM spc_nest") == "3"

    # ── 8. Unique index hint bits (LP_DEAD) after recovery ─────────────────
    def test_unique_index_lp_dead_violation_after_crash(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE idx_hint (c INT PRIMARY KEY);"
            "SAVEPOINT q; INSERT INTO idx_hint VALUES (1); ROLLBACK TO q;"
            "CHECKPOINT;"
            "INSERT INTO idx_hint VALUES (1);"
            "INSERT INTO idx_hint VALUES (2);"
            "COMMIT"
        )
        self._crash_restart(cluster)
        # Reinserting an existing value must hit the unique constraint
        # — proves the btree leaf was decrypted and read correctly after recovery.
        with pytest.raises(RuntimeError) as exc:
            cluster.execute("INSERT INTO idx_hint VALUES (2)")
        assert "violates unique" in str(exc.value).lower(), (
            f"Expected unique-violation error, got: {exc.value}"
        )

    # ── 9. COPY + INSERT triggers in a single transaction ──────────────────
    def test_copy_with_insert_triggers_survives_crash(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        copy_file = self._write_copy_payload(tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE ins_trig (id SERIAL PRIMARY KEY, id2 TEXT);"
            "CREATE FUNCTION ins_trig_before_row_trig() RETURNS trigger LANGUAGE plpgsql AS $$ "
            "BEGIN "
            "  IF NEW.id2 NOT LIKE 'triggered%' THEN "
            "    INSERT INTO ins_trig VALUES (DEFAULT, 'triggered row before' || NEW.id2); "
            "  END IF; "
            "  RETURN NEW; "
            "END; $$;"
            "CREATE FUNCTION ins_trig_after_row_trig() RETURNS trigger LANGUAGE plpgsql AS $$ "
            "BEGIN "
            "  IF NEW.id2 NOT LIKE 'triggered%' THEN "
            "    INSERT INTO ins_trig VALUES (DEFAULT, 'triggered row after' || NEW.id2); "
            "  END IF; "
            "  RETURN NEW; "
            "END; $$;"
            "CREATE TRIGGER t_before BEFORE INSERT ON ins_trig FOR EACH ROW "
            "  EXECUTE PROCEDURE ins_trig_before_row_trig();"
            "CREATE TRIGGER t_after AFTER INSERT ON ins_trig FOR EACH ROW "
            "  EXECUTE PROCEDURE ins_trig_after_row_trig();"
            f"COPY ins_trig FROM '{copy_file}' DELIMITER ',';"
            "COMMIT"
        )
        self._crash_restart(cluster)
        # 3 COPY rows × (1 self + 1 before-trigger + 1 after-trigger) = 9 rows.
        assert cluster.fetchone("SELECT count(*) FROM ins_trig") == "9"

    # ── 10. TRUNCATE + statement-level triggers + COPY ─────────────────────
    def test_truncate_with_statement_triggers_survives_crash(
        self, pg_factory, tmp_path: Path
    ):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        copy_file = self._write_copy_payload(tmp_path)
        cluster.execute(
            "BEGIN;"
            "CREATE TABLE trunc_trig (id SERIAL PRIMARY KEY, id2 TEXT);"
            "CREATE FUNCTION tt_before() RETURNS trigger LANGUAGE plpgsql AS $$ "
            "BEGIN INSERT INTO trunc_trig VALUES (DEFAULT, 'triggered stat before'); "
            "RETURN NULL; END; $$;"
            "CREATE FUNCTION tt_after() RETURNS trigger LANGUAGE plpgsql AS $$ "
            "BEGIN INSERT INTO trunc_trig VALUES (DEFAULT, 'triggered stat before'); "
            "RETURN NULL; END; $$;"
            "CREATE TRIGGER tt_before_stat BEFORE TRUNCATE ON trunc_trig "
            "  FOR EACH STATEMENT EXECUTE PROCEDURE tt_before();"
            "CREATE TRIGGER tt_after_stat AFTER TRUNCATE ON trunc_trig "
            "  FOR EACH STATEMENT EXECUTE PROCEDURE tt_after();"
            "INSERT INTO trunc_trig VALUES (DEFAULT, 1);"
            "TRUNCATE trunc_trig;"
            f"COPY trunc_trig FROM '{copy_file}' DELIMITER ',';"
            "COMMIT"
        )
        self._crash_restart(cluster)
        # 1 before-trigger row + 1 after-trigger row + 3 COPY rows = 5? bash expects 4.
        # The before-stmt trigger fires before TRUNCATE deletes; the after-stmt trigger
        # runs once after TRUNCATE has cleared the table. So:
        #   1 INSERT      → 1 row
        #   TRUNCATE      → BEFORE trigger inserts 1 row (which survives the TRUNCATE
        #                   because trigger executes BEFORE the truncation),
        #                   then TRUNCATE wipes all rows (= 0),
        #                   then AFTER trigger inserts 1 row.
        #   COPY 3 rows   → +3 rows.
        # Final = 1 (after-trigger) + 3 (COPY) = 4 rows.
        assert cluster.fetchone("SELECT count(*) FROM trunc_trig") == "4"

    # ── 11. Temp table cleaned up — no orphan relfilenodes after restart ───
    def test_temp_table_leaves_no_orphan_relfilenodes(self, pg_factory, tmp_path: Path):
        cluster, _ = self._build_cluster(pg_factory, tmp_path)
        cluster.execute("CREATE TEMP TABLE temp_t (id SERIAL PRIMARY KEY, id2 TEXT)")
        self._crash_restart(cluster)

        # Build the two sets the bash check_orphan_relfilenodes uses:
        #   files_on_disk      = numeric files in base/<db_oid>/
        #   files_referenced   = pg_relation_filepath(oid) of every catalog row
        db_oid = cluster.fetchone(
            "SELECT oid FROM pg_database WHERE datname = 'postgres'"
        )
        db_dir = cluster.data_dir / "base" / db_oid
        on_disk = sorted(
            p.name for p in db_dir.iterdir() if p.is_file() and p.name.isdigit()
        )
        referenced_raw = cluster.execute(
            "SELECT pg_relation_filepath(oid) "
            "FROM pg_class "
            "WHERE reltablespace = 0 AND relpersistence <> 't' "
            "  AND pg_relation_filepath(oid) IS NOT NULL"
        )
        referenced = sorted(
            line.rsplit("/", 1)[-1]
            for line in referenced_raw.splitlines()
            if line.strip()
        )
        # Every on-disk numeric file in base/<db_oid>/ must have a catalog row
        # that points at it.  Allow numeric files that exist on disk but are
        # not yet referenced ONLY if they look like a relfilenode that pg_class
        # hasn't materialised yet (none expected after a clean restart).
        orphans = sorted(set(on_disk) - set(referenced))
        assert orphans == [], (
            f"orphan relfilenodes found after temp-table crash recovery:\n"
            f"  on_disk    : {on_disk}\n"
            f"  referenced : {referenced}\n"
            f"  orphans    : {orphans}"
        )
