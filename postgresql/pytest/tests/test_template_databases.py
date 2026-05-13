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
   appear in every new database cloned from it.

2. **Per-DB key state propagation** — on pg_tde 2.2.0 the per-database
   principal-key mapping under ``$PGDATA/pg_tde/<oid>`` is **not**
   propagated to the new database by ``CREATE DATABASE``. The new DB
   needs its own ``pg_tde_set_key_using_global_key_provider()`` call.
   A consequence is that ``CREATE DATABASE`` from a template that
   contains encrypted objects fails with ``principal key not
   configured`` referring to the new DB — under BOTH ``STRATEGY =
   file_copy`` (correctly rejected by design) and ``STRATEGY =
   wal_log`` (looks like a bug — see the ``xfail`` test below).
   Until pg_tde adds per-DB key-state propagation, the supported
   workflow is **schema-only templates** plus per-tenant key setup
   after the clone.

3. **Template lifecycle DDL** — ``ALTER DATABASE ... IS_TEMPLATE TRUE``
   marking a regular DB as a template, the ``datistemplate = true``
   block on ``DROP DATABASE``, and the ``datallowconn = false`` block
   on ``template0`` must all behave identically whether or not pg_tde
   is in use.

4. **Clone strategies (PG 15+)** — ``STRATEGY = wal_log`` and
   ``STRATEGY = file_copy`` against a schema-only template must both
   yield a clone that can later host encrypted tables of its own.
   ``STRATEGY = file_copy`` against a template containing encrypted
   objects is explicitly rejected by pg_tde with a helpful hint —
   that contract is pinned as a positive negative test here.

5. **Independent clones** — two databases cloned from the same
   schema-only template must be independent: changes to one must not
   affect the other.

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

    def test_new_db_from_empty_template1_then_setup_supports_encrypted_data(
        self, tde_primary: PgCluster
    ):
        """
        Supported workflow: install pg_tde in ``template1`` (no
        encrypted tables yet) → ``CREATE DATABASE`` clones the
        extension state → configure the per-database principal key in
        the new DB → create encrypted tables. End-to-end round-trip
        proves the new DB can both write and decrypt its own pages.

        This is the pattern that actually works on pg_tde 2.2.0 today.
        The "encrypted-template clone" pattern is exercised separately
        below as an ``xfail`` documenting a likely bug (per-DB key
        state not propagated during CREATE DATABASE).
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute("CREATE DATABASE child_db")
        try:
            # Extension propagated.
            assert _extension_present(tde_primary, "pg_tde", "child_db")
            # Per-DB key for the new database (not auto-inherited).
            tde.set_global_principal_key(dbname="child_db")

            # Now the new DB can carry encrypted tables of its own.
            _create_encrypted_payload(
                tde_primary, "child_db", "child_enc", rows=200
            )
            assert tde.is_table_encrypted(
                "child_enc", dbname="child_db"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM child_enc", "child_db"
            ) == "200"
        finally:
            tde_primary.execute("DROP DATABASE child_db")

    @pytest.mark.xfail(
        reason=(
            "Suspected pg_tde bug (PG-2240 family): per-database "
            "principal-key state under $PGDATA/pg_tde/<oid> is not "
            "propagated to the new database during CREATE DATABASE. "
            "Even STRATEGY = wal_log fails with 'principal key not "
            "configured' on the new DB. Documented contract today is "
            "that the source template must NOT contain encrypted "
            "objects; this test pins the operator-facing scenario "
            "that should work."
        ),
        strict=False,
    )
    def test_new_db_inherits_encrypted_tables_from_template1_xfail(
        self, tde_primary: PgCluster
    ):
        """
        Marked ``xfail`` to track a likely pg_tde regression.

        ``template1`` has encrypted objects → ``CREATE DATABASE`` from
        it should produce a new DB whose cloned encrypted tables are
        readable end-to-end. Currently pg_tde rejects this with
        ``principal key not configured`` referring to the new DB —
        analogous to PG-2240 where pg_upgrade did not propagate
        ``$PGDATA/pg_tde/``.

        Flip to a passing assertion once pg_tde adds per-DB key-state
        propagation during CREATE DATABASE.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "tpl1_enc", rows=200
        )

        tde_primary.execute("CREATE DATABASE child_db")
        try:
            assert _extension_present(tde_primary, "pg_tde", "child_db")
            assert tde.is_table_encrypted(
                "tpl1_enc", dbname="child_db"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM tpl1_enc", "child_db"
            ) == "200"
        finally:
            try:
                tde_primary.execute("DROP DATABASE child_db")
            except Exception:
                pass

    def test_create_database_with_encrypted_template_rejects_file_copy(
        self, tde_primary: PgCluster
    ):
        """
        Documented contract: pg_tde explicitly rejects ``STRATEGY =
        file_copy`` when the source template contains encrypted
        objects, and the error hint points the operator at
        ``STRATEGY = wal_log``. The rejection is correct by design —
        FILE_COPY is a page-byte copy that cannot safely materialize
        encrypted pages against a different per-database key.

        This test pins that contract so a regression that silently
        allows FILE_COPY (leaving an encrypted-but-undecryptable
        clone on disk) would be caught.

        Skipped on PG 14 and earlier where the STRATEGY clause does
        not exist.
        """
        if tde_primary.major_version < 15:
            pytest.skip("CREATE DATABASE STRATEGY requires PG 15+")

        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")
        _create_encrypted_payload(
            tde_primary, "template1", "rej_tpl", rows=50
        )

        with pytest.raises(RuntimeError, match="FILE_COPY"):
            tde_primary.execute(
                "CREATE DATABASE rej_child STRATEGY = file_copy"
            )

        # No half-created database left behind.
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM pg_database WHERE datname = 'rej_child'"
        ) == "0"

    # ── custom template ──────────────────────────────────────────────────

    def test_custom_template_database_provisioning_workflow(
        self, tde_primary: PgCluster
    ):
        """
        Supported tenant-provisioning workflow on pg_tde 2.2.0:

        1. Build a one-off template DB with ``CREATE DATABASE`` →
           install pg_tde in it (NO encrypted tables yet).
        2. ``ALTER DATABASE ... IS_TEMPLATE TRUE`` to mark it.
        3. ``CREATE DATABASE tenant_a TEMPLATE <tpl>`` — extension
           state clones; new DB has no per-DB key yet.
        4. Configure the per-DB principal key in ``tenant_a``.
        5. Create encrypted tables in ``tenant_a``; round-trip them.

        Encrypted-table propagation through CREATE DATABASE is
        currently unsupported by pg_tde (see the xfail test above);
        the recommended approach today is to seed the template with
        schema-only DDL and let each tenant DB populate its own
        encrypted state.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE tenant_tpl")
        _setup_pg_tde_in_db(tde, "tenant_tpl")
        # Note: NO encrypted tables in the template — that's the
        # workflow pg_tde 2.2.0 supports.
        tde_primary.execute(
            "ALTER DATABASE tenant_tpl IS_TEMPLATE TRUE"
        )
        assert _datistemplate(tde_primary, "tenant_tpl") == "t"

        tde_primary.execute(
            "CREATE DATABASE tenant_a TEMPLATE tenant_tpl"
        )
        try:
            assert _extension_present(tde_primary, "pg_tde", "tenant_a")
            # New DB needs its own per-DB principal-key mapping.
            tde.set_global_principal_key(dbname="tenant_a")
            _create_encrypted_payload(
                tde_primary, "tenant_a", "tenant_enc", rows=150
            )
            assert tde.is_table_encrypted(
                "tenant_enc", dbname="tenant_a"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM tenant_enc", "tenant_a"
            ) == "150"
        finally:
            tde_primary.execute("DROP DATABASE tenant_a")
            tde_primary.execute(
                "ALTER DATABASE tenant_tpl IS_TEMPLATE FALSE"
            )
            tde_primary.execute("DROP DATABASE tenant_tpl")

    def test_two_independent_clones_from_schema_only_template_diverge(
        self, tde_primary: PgCluster
    ):
        """
        Two databases cloned from the same schema-only template must
        be independent: writes into one must not appear in the other.
        Each clone gets its own per-DB principal key, populates its
        own encrypted state, and the two are observably distinct.

        Variant of the encrypted-template clone scenario that uses
        the workflow pg_tde 2.2.0 actually supports.
        """
        tde = TdeManager(tde_primary)
        tde_primary.execute("CREATE DATABASE shared_tpl")
        _setup_pg_tde_in_db(tde, "shared_tpl")
        tde_primary.execute(
            "ALTER DATABASE shared_tpl IS_TEMPLATE TRUE"
        )
        try:
            for clone in ("clone_a", "clone_b"):
                tde_primary.execute(
                    f"CREATE DATABASE {clone} TEMPLATE shared_tpl"
                )
                tde.set_global_principal_key(dbname=clone)
                _create_encrypted_payload(
                    tde_primary, clone, "common_tbl", rows=50
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

            for clone in ("clone_a", "clone_b"):
                assert tde.is_table_encrypted("common_tbl", dbname=clone)
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

    def test_create_database_strategy_wal_log_with_schema_only_template(
        self, tde_primary: PgCluster
    ):
        """
        ``STRATEGY = wal_log`` (PG 15+) clones a template by emitting
        WAL records. The supported workflow is to use a schema-only
        template (pg_tde installed, no encrypted objects yet), then
        configure the per-DB key in the new database and populate
        encrypted tables there. End-to-end this exercises the WAL
        writer with ``wal_encrypt = on`` (set in the fixture's
        _TDE_PARAMS) — every INSERT we make ends up in encrypted WAL.

        Skipped on PG 14 and earlier where the syntax doesn't exist.
        """
        if tde_primary.major_version < 15:
            pytest.skip("CREATE DATABASE STRATEGY requires PG 15+")

        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute(
            "CREATE DATABASE wal_log_child STRATEGY = wal_log"
        )
        try:
            tde.set_global_principal_key(dbname="wal_log_child")
            _create_encrypted_payload(
                tde_primary, "wal_log_child", "wal_log_tbl", rows=100
            )
            assert tde.is_table_encrypted(
                "wal_log_tbl", dbname="wal_log_child"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM wal_log_tbl", "wal_log_child"
            ) == "100"
        finally:
            tde_primary.execute("DROP DATABASE wal_log_child")

    def test_create_database_strategy_file_copy_with_schema_only_template(
        self, tde_primary: PgCluster
    ):
        """
        ``STRATEGY = file_copy`` companion to the wal_log test. With a
        schema-only template (no encrypted objects), file_copy is the
        cheaper choice and must produce a clone that can later carry
        encrypted tables of its own once its per-DB key is configured.

        Encrypted-template clones via FILE_COPY are explicitly
        rejected by pg_tde — that contract is pinned separately in
        ``test_create_database_with_encrypted_template_rejects_file_copy``.

        Skipped on PG 14 and earlier where the syntax doesn't exist.
        """
        if tde_primary.major_version < 15:
            pytest.skip("CREATE DATABASE STRATEGY requires PG 15+")

        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute(
            "CREATE DATABASE file_copy_child STRATEGY = file_copy"
        )
        try:
            tde.set_global_principal_key(dbname="file_copy_child")
            _create_encrypted_payload(
                tde_primary, "file_copy_child", "file_copy_tbl", rows=100
            )
            assert tde.is_table_encrypted(
                "file_copy_tbl", dbname="file_copy_child"
            )
            assert tde_primary.fetchone(
                "SELECT COUNT(*) FROM file_copy_tbl",
                "file_copy_child",
            ) == "100"
        finally:
            tde_primary.execute("DROP DATABASE file_copy_child")

    # ── restart durability ───────────────────────────────────────────────

    def test_cloned_db_encrypted_data_survives_restart(
        self, tde_primary: PgCluster
    ):
        """
        Encrypted tables created inside a database that was cloned
        from a schema-only template must remain readable across a
        server restart. Catches regressions where the new DB's per-DB
        principal-key state was set in shared memory but not durably
        persisted to ``$PGDATA/pg_tde/<oid>`` — a restart would then
        leave the new DB's pages unreadable.
        """
        tde = TdeManager(tde_primary)
        _setup_pg_tde_in_db(tde, "template1")

        tde_primary.execute("CREATE DATABASE durable_child")
        tde.set_global_principal_key(dbname="durable_child")
        _create_encrypted_payload(
            tde_primary, "durable_child", "durable_tbl", rows=300
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM durable_tbl", "durable_child"
        ) == "300"

        tde_primary.restart()

        assert tde.is_table_encrypted(
            "durable_tbl", dbname="durable_child"
        ), (
            "cloned-db encrypted table lost its encryption flag "
            "across a restart"
        )
        assert tde_primary.fetchone(
            "SELECT COUNT(*) FROM durable_tbl", "durable_child"
        ) == "300", (
            "cloned-db encrypted table is unreadable after restart — "
            "pg_tde state for the cloned database was not durable"
        )
        tde_primary.execute("DROP DATABASE durable_child")
