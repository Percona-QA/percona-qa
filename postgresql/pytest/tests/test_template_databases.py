"""
Template-database creation under pg_tde.

PostgreSQL supports two kinds of "template" databases:

* ``template0`` — the immutable, pristine template. ``datallowconn = false`` and
  ``datistemplate = true`` by default. Only used as a base when you want a
  database that does NOT inherit anything from ``template1``.
* ``template1`` — the default source for ``CREATE DATABASE`` when no
  ``TEMPLATE`` clause is specified. Any extension installed in ``template1``
  is automatically present in newly-created databases.

Plus any regular database can be marked ``datistemplate = true`` via
``ALTER DATABASE ... IS_TEMPLATE TRUE`` and used as a custom template.

Until this file existed, pg_tde × template interactions had no dedicated
coverage — only ``test_recovery.py::TestRelfilenodeReuse`` exercised
``CREATE DATABASE ... TEMPLATE template0`` as a side-effect of an HA
relfilenode test. The template lifecycle has several pg_tde-specific
risk points that the present file pins down:

1. **Extension propagation** — pg_tde installed in ``template1`` must
   appear in every new database cloned from it. The cloned database
   must also inherit the database-level principal-key mapping (otherwise
   pre-existing encrypted tables would be unreadable after the clone).

2. **Encrypted-table propagation** — a ``tde_heap`` table that exists in
   the template at clone time must (a) exist in the new database, (b)
   still be on ``tde_heap``, (c) report encrypted via
   ``pg_tde_is_encrypted``, and (d) be readable end-to-end.

3. **Template lifecycle DDL** — ``ALTER DATABASE ... IS_TEMPLATE TRUE``
   marking a regular DB as a template, the ``datistemplate = true``
   block on ``DROP DATABASE``, and the ``datallowconn = false`` block
   on ``template0`` must all behave identically whether or not pg_tde
   is in use.

4. **Clone strategy parity** — PG 15 introduced ``STRATEGY = wal_log``
   (uses WAL records to replicate the source DB) and ``STRATEGY =
   file_copy`` (the legacy ``copydir`` path). Both must preserve
   encryption.

5. **Independent clones** — two databases cloned from the same encrypted
   template must be independent: changes to one must not affect the
   other.

All tests use the ``tde_primary`` fixture so the cluster comes up with
the global key provider, server key, and ``default_table_access_method
= tde_heap`` pre-configured in ``postgres`` only. Each test that needs
``template1`` configured does so explicitly so it is obvious which
template state is being exercised.
"""
from __future__ import annotations

import pytest

from lib import PgCluster, TdeManager


pytestmark = [pytest.mark.encryption]


# ── helpers ───────────────────────────────────────────────────────────────────


def _setup_pg_tde_in_db(tde: TdeManager, dbname: str) -> None:
    """
    Install pg_tde and bind the database-level principal key in ``dbname``.

    The cluster already has the global key provider and server key
    configured (via the ``tde_primary`` fixture); this only does the
    per-database work that pg_tde requires before encrypted tables
    can be created.
    """
    tde.create_extension(dbname=dbname)
    tde.set_global_principal_key(dbname=dbname)


def _create_encrypted_payload(cluster: PgCluster, dbname: str, table: str,
                              rows: int) -> None:
    """Create ``table`` USING tde_heap in ``dbname`` and populate it."""
    cluster.execute(
        f"CREATE TABLE {table} (id INT, payload TEXT) USING tde_heap",
        dbname,
    )
    cluster.execute(
        f"INSERT INTO {table} "
        f"SELECT i, md5(i::text) FROM generate_series(1, {rows}) i",
        dbname,
    )


def _datistemplate(cluster: PgCluster, dbname: str) -> str:
    """Raw 't'/'f' string of pg_database.datistemplate for ``dbname``."""
    return cluster.fetchone(
        "SELECT datistemplate FROM pg_database "
        f"WHERE datname = '{dbname}'"
    )


def _datallowconn(cluster: PgCluster, dbname: str) -> str:
    return cluster.fetchone(
        "SELECT datallowconn FROM pg_database "
        f"WHERE datname = '{dbname}'"
    )


def _extension_present(cluster: PgCluster, extname: str, dbname: str) -> bool:
    return cluster.fetchone(
        f"SELECT extname FROM pg_extension WHERE extname = '{extname}'",
        dbname,
    ) == extname


# ── tests ─────────────────────────────────────────────────────────────────────


class TestPgTdeTemplateDatabases:
    """
    Template-database × pg_tde end-to-end contract.

    The tests cover the three reasonable cloning workflows operators
    actually use:

    * default-template propagation: install pg_tde in ``template1`` so
      every newly created database is TDE-ready from minute one;
    * custom-template propagation: build a one-off template database
      with a curated schema and use it as the ``TEMPLATE`` argument;
    * ``IS_TEMPLATE`` round-trip: promote a regular DB to a template,
      clone it, and demote it again.
    """

    # ── extension propagation via template1 ───────────────────────────────

    def test_pg_tde_extension_installable_in_template1(
        self, tde_primary: PgCluster
    ):
        """
        Sanity check: ``CREATE EXTENSION pg_tde`` in ``template1`` must
        succeed when the global key provider and server key are already
        configured. A regression where pg_tde required a database-name
        whitelist or refused to bind to a template database would fail
        here.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        assert _extension_present(tde_primary, "pg_tde", "template1"), (
            "pg_tde extension is not visible in template1 after "
            "CREATE EXTENSION; template1's pg_extension catalog was not "
            "updated"
        )

    def test_new_db_from_template1_inherits_pg_tde_extension(
        self, tde_primary: PgCluster
    ):
        """
        With pg_tde installed in ``template1``, every new database
        created without an explicit ``TEMPLATE`` clause defaults to
        ``template1`` and must inherit the extension. A regression
        could see the new database created without ``pg_extension``
        rows for pg_tde — silently leaving encrypted tables unreadable.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute("CREATE DATABASE inherit_ext_db")

        assert _extension_present(
            tde_primary, "pg_tde", "inherit_ext_db"
        ), (
            "pg_tde was not inherited by the new database despite being "
            "installed in template1 — extension propagation broken"
        )
        tde_primary.execute("DROP DATABASE inherit_ext_db")

    def test_new_db_inherits_encrypted_tables_from_template1(
        self, tde_primary: PgCluster
    ):
        """
        End-to-end: tables created USING tde_heap inside ``template1``
        must clone into every new database with their encryption status
        intact AND their data readable. This is the strongest assertion
        in the file — a successful read proves the cloned DB has access
        to whatever key state pg_tde needs to decrypt the inherited
        pages.

        If this test fails because reading the inherited table errors
        out (or returns garbage), the regression is in the per-database
        principal-key mapping or in pg_tde's $PGDATA/pg_tde/ state
        directory not being cloned alongside the database — that's the
        PG-2240 family of bugs.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "tpl1_enc", rows=200
        )

        tde_primary.execute("CREATE DATABASE child_db")

        # Catalog states.
        assert _extension_present(tde_primary, "pg_tde", "child_db")
        assert tde.get_access_method(
            "tpl1_enc", dbname="child_db"
        ) == "tde_heap", (
            "cloned table is no longer on tde_heap in the new database"
        )
        assert tde.is_table_encrypted("tpl1_enc", dbname="child_db"), (
            "cloned table is not encrypted in the new database — "
            "pg_tde state likely was not propagated by CREATE DATABASE"
        )

        # End-to-end read (this is the regression-catching assertion).
        rows = tde_primary.fetchone(
            "SELECT COUNT(*) FROM tpl1_enc", "child_db"
        )
        assert rows == "200", (
            "cloned encrypted table contains "
            f"{rows} rows, expected 200 — clone may have copied pages "
            "but lost access to the key needed to decrypt them"
        )
        tde_primary.execute("DROP DATABASE child_db")

    # ── custom template ──────────────────────────────────────────────────

    def test_custom_template_database_clones_encrypted_tables(
        self, tde_primary: PgCluster
    ):
        """
        Operators commonly build a one-off template database with a
        curated schema and use it as ``TEMPLATE`` for tenant
        provisioning. The whole point is to clone an already-populated
        schema. The cloned tenant database must end up with encrypted
        tables that round-trip identically to the template.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE tenant_tpl")
        _setup_pg_tde_in_db(tde, "tenant_tpl")
        _create_encrypted_payload(
            tde_primary, "tenant_tpl", "schema_tbl", rows=150
        )
        # Promote to template.
        tde_primary.execute(
            "ALTER DATABASE tenant_tpl IS_TEMPLATE TRUE"
        )
        assert _datistemplate(tde_primary, "tenant_tpl") == "t"

        tde_primary.execute(
            "CREATE DATABASE tenant_a TEMPLATE tenant_tpl"
        )
        try:
            assert _extension_present(tde_primary, "pg_tde", "tenant_a")
            assert tde.is_table_encrypted(
                "schema_tbl", dbname="tenant_a"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM schema_tbl", "tenant_a"
            ) == "150"
        finally:
            tde_primary.execute("DROP DATABASE tenant_a")
            tde_primary.execute(
                "ALTER DATABASE tenant_tpl IS_TEMPLATE FALSE"
            )
            tde_primary.execute("DROP DATABASE tenant_tpl")

    def test_two_independent_clones_from_encrypted_template_diverge(
        self, tde_primary: PgCluster
    ):
        """
        Two databases created from the same encrypted template must be
        independent. A write into one must not be observable from the
        other. Catches accidental shared-state regressions in pg_tde's
        per-database key mapping or relfilenode bookkeeping.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE shared_tpl")
        _setup_pg_tde_in_db(tde, "shared_tpl")
        _create_encrypted_payload(
            tde_primary, "shared_tpl", "common_tbl", rows=50
        )
        tde_primary.execute(
            "ALTER DATABASE shared_tpl IS_TEMPLATE TRUE"
        )
        try:
            tde_primary.execute(
                "CREATE DATABASE clone_a TEMPLATE shared_tpl"
            )
            tde_primary.execute(
                "CREATE DATABASE clone_b TEMPLATE shared_tpl"
            )

            # Mutate only clone_a.
            tde_primary.execute(
                "INSERT INTO common_tbl VALUES "
                "(9999, 'a-only')", "clone_a"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM common_tbl WHERE id = 9999",
                "clone_a",
            ) == "1"
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM common_tbl WHERE id = 9999",
                "clone_b",
            ) == "0", (
                "clone_b saw a row that was only inserted into clone_a — "
                "the two clones share storage, which is a critical bug"
            )

            # Both clones remain encrypted independently.
            assert tde.is_table_encrypted(
                "common_tbl", dbname="clone_a"
            )
            assert tde.is_table_encrypted(
                "common_tbl", dbname="clone_b"
            )
        finally:
            for db in ("clone_a", "clone_b"):
                try:
                    tde_primary.execute(f"DROP DATABASE {db}")
                except Exception:
                    pass
            tde_primary.execute(
                "ALTER DATABASE shared_tpl IS_TEMPLATE FALSE"
            )
            tde_primary.execute("DROP DATABASE shared_tpl")

    # ── lifecycle DDL ────────────────────────────────────────────────────

    def test_alter_database_is_template_round_trip_preserves_data(
        self, tde_primary: PgCluster
    ):
        """
        Marking a populated database as a template and then unmarking
        it must not touch any of the encrypted tables. Verifies
        ``ALTER DATABASE ... IS_TEMPLATE`` is purely a catalog-flag
        change, not a storage operation.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE flip_db")
        _setup_pg_tde_in_db(tde, "flip_db")
        _create_encrypted_payload(
            tde_primary, "flip_db", "flip_tbl", rows=75
        )

        # Promote
        tde_primary.execute("ALTER DATABASE flip_db IS_TEMPLATE TRUE")
        assert _datistemplate(tde_primary, "flip_db") == "t"

        # Demote
        tde_primary.execute("ALTER DATABASE flip_db IS_TEMPLATE FALSE")
        assert _datistemplate(tde_primary, "flip_db") == "f"

        # Data intact and still encrypted.
        assert tde.is_table_encrypted("flip_tbl", dbname="flip_db")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM flip_tbl", "flip_db"
        ) == "75"
        tde_primary.execute("DROP DATABASE flip_db")

    def test_cannot_drop_database_marked_as_template(
        self, tde_primary: PgCluster
    ):
        """
        ``DROP DATABASE`` on a template (``datistemplate = true``)
        must be rejected by PostgreSQL itself — pg_tde must not change
        that semantics. After unmarking the DB the drop succeeds, and
        no orphan pg_tde state should remain.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE template_lock")
        _setup_pg_tde_in_db(tde, "template_lock")
        _create_encrypted_payload(
            tde_primary, "template_lock", "lock_tbl", rows=10
        )
        tde_primary.execute(
            "ALTER DATABASE template_lock IS_TEMPLATE TRUE"
        )

        with pytest.raises(RuntimeError):
            tde_primary.execute("DROP DATABASE template_lock")

        # Underlying data still readable while still a template.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM lock_tbl", "template_lock"
        ) == "10"

        # Unmark + drop — now succeeds.
        tde_primary.execute(
            "ALTER DATABASE template_lock IS_TEMPLATE FALSE"
        )
        tde_primary.execute("DROP DATABASE template_lock")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM pg_database "
            "WHERE datname = 'template_lock'"
        ) == "0"

    def test_template0_clone_has_no_pg_tde_extension(
        self, tde_primary: PgCluster
    ):
        """
        ``template0`` is the pristine template; nothing should ever
        leak into it from ``template1`` or ``postgres``. Even after
        the fixture has set up pg_tde in ``postgres``, a database
        cloned from ``template0`` must come up extension-free. A
        regression where pg_tde wrote into template0 (or where its
        ``shared_preload_libraries`` hook silently created the
        extension) would surface here.
        """
        tde = TdeManager(tde_primary)
        # Also install pg_tde in template1 to harden the test: if pg_tde
        # accidentally falls back to template1 instead of template0,
        # the new DB would gain the extension. With the explicit
        # TEMPLATE template0 clause that fallback should be impossible.
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute(
            "CREATE DATABASE clean_db TEMPLATE template0"
        )
        try:
            assert not _extension_present(
                tde_primary, "pg_tde", "clean_db"
            ), (
                "pg_tde extension appeared in a database cloned from "
                "template0 — template0 must remain pristine"
            )
        finally:
            tde_primary.execute("DROP DATABASE clean_db")

    def test_template0_remains_unconnectable_with_pg_tde(
        self, tde_primary: PgCluster
    ):
        """
        ``template0`` has ``datallowconn = false`` by default. pg_tde
        must not silently flip that to enable connections — it would
        be a serious safety regression (template0 must remain a
        pristine reference). Verify the flag is still ``f`` after
        the TDE setup and that a connection attempt is rejected.
        """
        assert _datallowconn(tde_primary, "template0") == "f", (
            "template0.datallowconn is true after pg_tde setup — "
            "template0 should remain unconnectable"
        )
        # Connection attempt rejects.
        with pytest.raises(RuntimeError):
            tde_primary.execute("SELECT 1", "template0")

    # ── PG 15+ clone strategies ──────────────────────────────────────────

    def test_create_database_strategy_wal_log_preserves_encryption(
        self, tde_primary: PgCluster
    ):
        """
        PostgreSQL 15 introduced ``CREATE DATABASE ... STRATEGY =
        wal_log``, where the source DB is reproduced by emitting WAL
        records instead of copying files (``STRATEGY = file_copy``,
        the pre-15 default). pg_tde must preserve encryption under
        both strategies. With ``wal_encrypt = on`` (set in the
        fixture's _TDE_PARAMS), the wal_log path is exercising the
        encrypted-WAL writer too.

        Skipped on PG 14 and earlier where the syntax doesn't exist.
        """
        if tde_primary.major_version < 15:
            pytest.skip("CREATE DATABASE STRATEGY requires PG 15+")

        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "wal_log_tpl", rows=100
        )

        tde_primary.execute(
            "CREATE DATABASE wal_log_child STRATEGY = wal_log"
        )
        try:
            assert tde.is_table_encrypted(
                "wal_log_tpl", dbname="wal_log_child"
            ), (
                "STRATEGY = wal_log produced an unencrypted clone of "
                "an encrypted source table"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM wal_log_tpl", "wal_log_child"
            ) == "100"
        finally:
            tde_primary.execute("DROP DATABASE wal_log_child")

    def test_create_database_strategy_file_copy_preserves_encryption(
        self, tde_primary: PgCluster
    ):
        """
        Companion to the wal_log test: explicit ``STRATEGY =
        file_copy`` must produce the same encrypted-clone result.
        The two strategies use different internals and historically
        had different bug profiles around extensions and on-disk
        state.

        Skipped on PG 14 and earlier where the syntax doesn't exist.
        """
        if tde_primary.major_version < 15:
            pytest.skip("CREATE DATABASE STRATEGY requires PG 15+")

        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "file_copy_tpl", rows=100
        )

        tde_primary.execute(
            "CREATE DATABASE file_copy_child STRATEGY = file_copy"
        )
        try:
            assert tde.is_table_encrypted(
                "file_copy_tpl", dbname="file_copy_child"
            ), (
                "STRATEGY = file_copy produced an unencrypted clone "
                "of an encrypted source table"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM file_copy_tpl",
                "file_copy_child",
            ) == "100"
        finally:
            tde_primary.execute("DROP DATABASE file_copy_child")

    # ── restart durability ───────────────────────────────────────────────

    def test_cloned_encrypted_db_data_survives_restart(
        self, tde_primary: PgCluster
    ):
        """
        After cloning, the new database's encrypted tables must remain
        readable across a server restart. Catches regressions where
        the clone was readable in-session (key still in memory) but
        the on-disk pg_tde state wasn't durable, so a restart left
        the new DB with unrecoverable pages.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "durable_tpl", rows=300
        )

        tde_primary.execute("CREATE DATABASE durable_child")
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM durable_tpl", "durable_child"
        ) == "300"

        tde_primary.restart()

        assert tde.is_table_encrypted(
            "durable_tpl", dbname="durable_child"
        ), (
            "cloned encrypted table lost its encryption flag across a "
            "restart"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM durable_tpl", "durable_child"
        ) == "300", (
            "cloned encrypted table is unreadable after restart — "
            "pg_tde state for the cloned database was not durable"
        )
        tde_primary.execute("DROP DATABASE durable_child")
