"""
Unlogged-relation reinitialisation contract under pg_tde.

Port of ``postgresql/automation/tests/pg_tde_unlogged_test.sh``, which is
itself a bash port of upstream ``src/test/recovery/014_unlogged_reinit.pl``.

The crash-recovery contract for UNLOGGED relations is:

1. The ``_init`` fork must be kept across a crash.
2. The main (``''``) fork is **recreated from the init fork** during
   recovery. Whatever was there before is thrown away.
3. The ``_vm`` and ``_fsm`` forks are **removed** during recovery (they
   are rebuilt lazily on demand).

This must hold whether the relation is in the default tablespace or in
a user-created tablespace, and it must hold for both UNLOGGED tables and
UNLOGGED sequences (sequences are tested separately because they have
their own reset semantics).

The narrower PG-1805 reproduction in ``test_bug_reproduction.py`` only
covers the IDENTITY-column trigger — this module covers the broader
contract that 014_unlogged_reinit.pl validates upstream.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib import PgCluster, TdeManager
from lib.cluster import initdb_args_no_data_checksums


pytestmark = [pytest.mark.recovery]


# ── helpers ───────────────────────────────────────────────────────────────────


def _build_tde_cluster_with_default_key(pg_factory, tmp_path: Path, name: str) -> PgCluster:
    """
    Build a TDE cluster with ``default_table_access_method=tde_heap`` and
    a configured DEFAULT global key (required so that DDL — including
    CREATE UNLOGGED — succeeds without per-database key setup).
    """
    keyfile = str(tmp_path / f"{name}.keyring.per")
    cluster = pg_factory(name)
    cluster.initdb(extra_args=initdb_args_no_data_checksums(cluster.install_dir))
    cluster.write_default_config(
        extra_params={
            "shared_preload_libraries": "'pg_tde'",
            "default_table_access_method": "'tde_heap'",
        }
    )
    cluster.add_hba_entry("local all all trust")
    cluster.start()

    tde = TdeManager(cluster)
    tde.create_extension()
    tde.add_global_key_provider_file(keyfile=keyfile)
    tde.set_global_principal_key()
    # Set the server-wide default key so newly-created relations in the
    # postgres database can encrypt without explicit per-DB setup.
    cluster.execute(
        "SELECT pg_tde_set_default_key_using_global_key_provider("
        "'test_key'::text, 'file_provider'::text)"
    )
    # Settings before/after pg_tde initialisation must be in sync.
    cluster.restart()
    cluster.wait_ready()
    return cluster


def _rel_main_path(cluster: PgCluster, relname: str) -> Path:
    """Absolute path to the main fork file for *relname* (relative to PGDATA)."""
    relpath = cluster.fetchone(f"SELECT pg_relation_filepath('{relname}')")
    assert relpath, f"pg_relation_filepath returned empty for {relname!r}"
    return cluster.data_dir / relpath


def _exists(p: Path) -> bool:
    return p.exists()


# ── tests ─────────────────────────────────────────────────────────────────────


class TestUnloggedReinitDefaultTablespace:
    """
    Default-tablespace UNLOGGED table + sequence: fork lifecycle after a
    crash must match the upstream 014_unlogged_reinit.pl contract.
    """

    def test_unlogged_table_forks_present_before_crash(self, pg_factory, tmp_path: Path):
        """Both ``_init`` and main forks exist immediately after CREATE UNLOGGED."""
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_pre")
        cluster.execute("CREATE UNLOGGED TABLE base_unlogged (id INT)")
        main = _rel_main_path(cluster, "base_unlogged")
        init = Path(str(main) + "_init")
        assert _exists(init), f"init fork missing immediately after CREATE: {init}"
        assert _exists(main), f"main fork missing immediately after CREATE: {main}"

    def test_unlogged_sequence_nextval_before_crash(self, pg_factory, tmp_path: Path):
        """``nextval`` on a freshly created UNLOGGED sequence returns 1 then 2."""
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_seq")
        cluster.execute("CREATE UNLOGGED SEQUENCE seq_u")
        assert cluster.fetchone("SELECT nextval('seq_u')") == "1"
        assert cluster.fetchone("SELECT nextval('seq_u')") == "2"

    def test_unlogged_main_fork_recopied_vm_fsm_removed_after_crash(
        self, pg_factory, tmp_path: Path
    ):
        """
        After an immediate stop:
          * Delete the main fork (simulates corruption)
          * Touch fake ``_vm`` and ``_fsm`` files
          * Start the cluster

        Recovery must:
          * Keep the ``_init`` fork
          * Re-create the main fork from the init fork
          * Remove the ``_vm`` and ``_fsm`` files
        """
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_crash")
        cluster.execute("CREATE UNLOGGED TABLE base_unlogged (id INT)")
        main = _rel_main_path(cluster, "base_unlogged")
        init = Path(str(main) + "_init")
        vm = Path(str(main) + "_vm")
        fsm = Path(str(main) + "_fsm")

        cluster.stop(mode="immediate")

        # Plant garbage VM/FSM forks and remove the main fork.
        vm.write_bytes(b"TEST_VM\n")
        fsm.write_bytes(b"TEST_FSM\n")
        main.unlink(missing_ok=True)

        cluster.start()
        cluster.wait_ready()

        assert _exists(init), "init fork in base must still exist after recovery"
        assert _exists(main), "main fork in base must be re-created from init fork"
        assert not _exists(vm), "vm fork must be removed during recovery"
        assert not _exists(fsm), "fsm fork must be removed during recovery"

        # Re-initialised main fork is empty; INSERT must succeed and produce one row.
        cluster.execute("INSERT INTO base_unlogged VALUES (42)")
        assert cluster.fetchone("SELECT count(*) FROM base_unlogged") == "1"

    def test_unlogged_sequence_resets_to_one_after_crash_reinit(
        self, pg_factory, tmp_path: Path
    ):
        """
        UNLOGGED sequences are also reinitialised on crash recovery: any
        ``nextval`` advances made before the immediate stop are lost, so
        the post-crash ``nextval`` again returns 1.
        """
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_seqcrash")
        cluster.execute("CREATE UNLOGGED SEQUENCE seq_u")
        # Advance before the crash so we can prove the reset.
        cluster.execute("SELECT nextval('seq_u')")
        cluster.execute("SELECT nextval('seq_u')")
        assert cluster.fetchone("SELECT last_value FROM seq_u") == "2"

        main = _rel_main_path(cluster, "seq_u")
        cluster.stop(mode="immediate")
        main.unlink(missing_ok=True)
        cluster.start()
        cluster.wait_ready()

        # Sequence state must be reset to its initial value.
        assert cluster.fetchone("SELECT nextval('seq_u')") == "1"
        assert cluster.fetchone("SELECT nextval('seq_u')") == "2"


class TestUnloggedReinitCustomTablespace:
    """Same contract, but for an UNLOGGED table that lives in a custom tablespace."""

    def test_unlogged_table_in_custom_tablespace_reinitialised_after_crash(
        self, pg_factory, tmp_path: Path
    ):
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_tsp")
        tsp_dir = tmp_path / "ts1"
        tsp_dir.mkdir(mode=0o700)
        cluster.execute(f"CREATE TABLESPACE ts1 LOCATION '{tsp_dir}'")
        cluster.execute("CREATE UNLOGGED TABLE ts1_unlogged (id INT) TABLESPACE ts1")
        cluster.execute("INSERT INTO ts1_unlogged VALUES (1), (2), (3)")

        main = _rel_main_path(cluster, "ts1_unlogged")
        init = Path(str(main) + "_init")
        vm = Path(str(main) + "_vm")
        fsm = Path(str(main) + "_fsm")

        assert _exists(init), "init fork must exist on freshly-created tablespace relation"
        assert _exists(main), "main fork must exist on freshly-created tablespace relation"

        cluster.stop(mode="immediate")
        vm.write_bytes(b"TEST_VM\n")
        fsm.write_bytes(b"TEST_FSM\n")
        main.unlink(missing_ok=True)
        cluster.start()
        cluster.wait_ready()

        assert _exists(init), "init fork in tablespace must survive recovery"
        assert _exists(main), "main fork in tablespace must be re-created from init fork"
        assert not _exists(vm), "vm fork in tablespace must be removed during recovery"
        assert not _exists(fsm), "fsm fork in tablespace must be removed during recovery"

        # Reinitialised table is empty.
        assert cluster.fetchone("SELECT count(*) FROM ts1_unlogged") == "0"


class TestUnloggedReinitSequencesAndIdentity:
    """
    Composite test mirroring the tail end of pg_tde_unlogged_test.sh:
    customised sequence INCREMENT + IDENTITY column survive the same
    crash + reinitialisation cycle.
    """

    def test_altered_sequence_and_identity_table_after_recovery(
        self, pg_factory, tmp_path: Path
    ):
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_ident")
        cluster.execute("CREATE UNLOGGED SEQUENCE seq2")
        cluster.execute("ALTER SEQUENCE seq2 INCREMENT 2")
        cluster.execute("SELECT nextval('seq2')")  # advance once

        cluster.execute(
            "CREATE UNLOGGED TABLE tab_ident (a INT GENERATED ALWAYS AS IDENTITY)"
        )
        cluster.execute("TRUNCATE tab_ident RESTART IDENTITY")
        cluster.execute("INSERT INTO tab_ident DEFAULT VALUES")
        assert cluster.fetchone("SELECT count(*) FROM tab_ident") == "1"

        # Crash, then bring it back. UNLOGGED relations get a fresh main fork.
        cluster.stop(mode="immediate")
        cluster.start()
        cluster.wait_ready()

        # Custom INCREMENT setting must survive the reinit (it lives in
        # pg_sequence, not on the heap), but the *value* is reset.
        assert cluster.fetchone("SELECT nextval('seq2')") == "1"
        assert cluster.fetchone("SELECT nextval('seq2')") == "3"

        # The identity table is empty after reinit; new inserts succeed
        # and the identity counter starts from 1 again (per spec).
        cluster.execute("INSERT INTO tab_ident VALUES (DEFAULT), (DEFAULT)")
        rows = cluster.fetchall("SELECT a FROM tab_ident ORDER BY a")
        assert rows == ["1", "2"], f"expected [1,2], got {rows!r}"


class TestUnloggedReinitEndToEnd:
    """
    End-to-end mirror of the bash script's narrative: build a cluster
    with one unlogged table + one unlogged sequence in the default
    location plus one in a custom tablespace, crash, then verify every
    expected fork lifecycle transition on the same cluster in one go.

    The purpose is to catch any cross-relation interaction bugs that a
    per-test isolated setup would miss.
    """

    def test_full_unlogged_reinit_lifecycle_one_cluster(self, pg_factory, tmp_path: Path):
        cluster = _build_tde_cluster_with_default_key(pg_factory, tmp_path, "ureinit_e2e")
        tsp_dir = tmp_path / "ts_e2e"
        tsp_dir.mkdir(mode=0o700)

        cluster.execute("CREATE UNLOGGED TABLE u_table (id INT)")
        cluster.execute("CREATE UNLOGGED SEQUENCE u_seq")
        cluster.execute(f"CREATE TABLESPACE ts_e2e LOCATION '{tsp_dir}'")
        cluster.execute("CREATE UNLOGGED TABLE u_table_tsp (id INT) TABLESPACE ts_e2e")

        cluster.execute("INSERT INTO u_table VALUES (1)")
        cluster.execute("INSERT INTO u_table_tsp VALUES (10), (20)")
        cluster.execute("SELECT nextval('u_seq')")
        cluster.execute("SELECT nextval('u_seq')")

        paths = {}
        for rel in ("u_table", "u_seq", "u_table_tsp"):
            main = _rel_main_path(cluster, rel)
            paths[rel] = {
                "main": main,
                "init": Path(str(main) + "_init"),
                "vm": Path(str(main) + "_vm"),
                "fsm": Path(str(main) + "_fsm"),
            }
            assert _exists(paths[rel]["init"]), f"init fork missing for {rel}"
            assert _exists(paths[rel]["main"]), f"main fork missing for {rel}"

        cluster.stop(mode="immediate")

        # Plant garbage VM/FSM, delete main forks for both tables.
        for rel in ("u_table", "u_table_tsp"):
            paths[rel]["vm"].write_bytes(b"X")
            paths[rel]["fsm"].write_bytes(b"X")
            paths[rel]["main"].unlink(missing_ok=True)
        # Also delete the sequence's main fork (it must be re-created from init).
        paths["u_seq"]["main"].unlink(missing_ok=True)

        cluster.start()
        cluster.wait_ready()

        for rel in ("u_table", "u_seq", "u_table_tsp"):
            assert _exists(paths[rel]["init"]), f"init fork lost for {rel}"
            assert _exists(paths[rel]["main"]), f"main fork not re-created for {rel}"
        for rel in ("u_table", "u_table_tsp"):
            assert not _exists(paths[rel]["vm"]), f"vm fork not removed for {rel}"
            assert not _exists(paths[rel]["fsm"]), f"fsm fork not removed for {rel}"

        # All unlogged tables are empty after reinit; sequences restart at 1.
        assert cluster.fetchone("SELECT count(*) FROM u_table") == "0"
        assert cluster.fetchone("SELECT count(*) FROM u_table_tsp") == "0"
        assert cluster.fetchone("SELECT nextval('u_seq')") == "1"

        # And the post-recovery cluster is usable: writes succeed, encryption
        # is still active for the default-AM = tde_heap UNLOGGED tables.
        cluster.execute("INSERT INTO u_table VALUES (99)")
        cluster.execute("INSERT INTO u_table_tsp VALUES (99)")
        assert cluster.fetchone("SELECT count(*) FROM u_table") == "1"
        assert cluster.fetchone("SELECT count(*) FROM u_table_tsp") == "1"
        assert TdeManager(cluster).is_table_encrypted("u_table")
        assert TdeManager(cluster).is_table_encrypted("u_table_tsp")
