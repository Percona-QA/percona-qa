"""Streaming and logical replication helpers."""
import logging
import time
from typing import Optional

from .cluster import PgCluster

log = logging.getLogger(__name__)


class ReplicationManager:
    """Sets up and verifies streaming replication between a primary and standby."""

    def __init__(self, primary: PgCluster, standby: PgCluster) -> None:
        self.primary = primary
        self.standby = standby

    # ── setup ─────────────────────────────────────────────────────────────

    def configure_primary(self) -> None:
        self.primary.configure(
            {
                "wal_level": "replica",
                "max_wal_senders": "5",
                "hot_standby": "on",
                "wal_log_hints": "on",
            }
        )
        self.primary.add_hba_entry(
            "local   replication   all                   trust"
        )
        self.primary.add_hba_entry(
            "host    replication   all   127.0.0.1/32    trust"
        )

    def create_standby_from_backup(
        self,
        *,
        use_tde_basebackup: bool = False,
        extra_args=None,
    ) -> None:
        """pg_basebackup (or pg_tde_basebackup) from primary into standby.data_dir."""
        if self.standby.data_dir.exists():
            import shutil
            shutil.rmtree(self.standby.data_dir)
        if use_tde_basebackup:
            from .tde import TdeManager
            TdeManager(self.primary).tde_basebackup(
                str(self.standby.data_dir), extra_args
            )
        else:
            self.primary.basebackup(str(self.standby.data_dir), extra_args)
        self._write_standby_signal()
        self._write_primary_conninfo()
        log.info("Standby created at %s", self.standby.data_dir)

    def _write_standby_signal(self) -> None:
        (self.standby.data_dir / "standby.signal").touch()

    def _write_primary_conninfo(self) -> None:
        conninfo = (
            f"host={self.primary.socket_dir} "
            f"port={self.primary.port} "
            f"user=postgres "
            f"application_name=replica"
        )
        auto_conf = self.standby.data_dir / "postgresql.auto.conf"
        with auto_conf.open("a") as f:
            f.write(f"primary_conninfo = '{conninfo}'\n")

    # ── catchup / lag ─────────────────────────────────────────────────────

    def wait_for_catchup(self, timeout: int = 60) -> bool:
        """Wait until standby replay_lsn has reached the primary's LSN at call time."""
        # Snapshot once — primary advances every transaction so exact equality never holds
        target_lsn = self.primary.fetchone("SELECT pg_current_wal_lsn()")
        if not target_lsn:
            return False
        deadline = time.time() + timeout
        while time.time() < deadline:
            replay_lsn = self.standby.fetchone("SELECT pg_last_wal_replay_lsn()")
            if replay_lsn:
                try:
                    diff = self.primary.fetchone(
                        f"SELECT pg_wal_lsn_diff('{replay_lsn}', '{target_lsn}')"
                    )
                    if diff is not None and int(diff) >= 0:
                        log.info("Standby caught up: replay=%s target=%s", replay_lsn, target_lsn)
                        return True
                except Exception:
                    pass
            time.sleep(1)
        log.warning("Standby did not reach %s within %ds", target_lsn, timeout)
        return False

    def assert_catchup(self, timeout: int = 60) -> None:
        """Like wait_for_catchup() but raises AssertionError with full diagnostics on timeout."""
        if self.wait_for_catchup(timeout):
            return
        primary_lsn  = self.primary.fetchone("SELECT pg_current_wal_lsn()") or "unknown"
        receive_lsn  = self.standby.fetchone("SELECT pg_last_wal_receive_lsn()") or "None"
        replay_lsn   = self.standby.fetchone("SELECT pg_last_wal_replay_lsn()") or "None"
        senders      = self.primary.fetchone("SELECT COUNT(*) FROM pg_stat_replication") or "0"
        in_recovery  = self.standby.fetchone("SELECT pg_is_in_recovery()") or "unknown"
        raise AssertionError(
            f"Standby did not catch up within {timeout}s\n"
            f"  Primary LSN     : {primary_lsn}\n"
            f"  Standby receive : {receive_lsn}\n"
            f"  Standby replay  : {replay_lsn}\n"
            f"  WAL senders     : {senders}\n"
            f"  In recovery     : {in_recovery}\n"
            f"\nPrimary log (last 20 lines):\n{self.primary.read_log(20)}"
            f"\nStandby log (last 20 lines):\n{self.standby.read_log(20)}"
        )

    def replication_lag_bytes(self) -> Optional[int]:
        row = self.primary.fetchone(
            "SELECT sent_lsn - replay_lsn FROM pg_stat_replication LIMIT 1"
        )
        return int(row) if row else None

    # ── consistency checks ────────────────────────────────────────────────

    def assert_row_counts_match(self, table: str, dbname: str = "postgres") -> None:
        primary_count = int(self.primary.fetchone(f"SELECT COUNT(*) FROM {table}", dbname))
        standby_count = int(self.standby.fetchone(f"SELECT COUNT(*) FROM {table}", dbname))
        assert primary_count == standby_count, (
            f"Row count mismatch on {table}: primary={primary_count}, standby={standby_count}"
        )
        log.info("Row counts match for %s: %d rows", table, primary_count)

    def assert_checksums_match(self, table: str, dbname: str = "postgres") -> None:
        primary_sum = self.primary.fetchone(
            f"SELECT md5(array_agg(t::text ORDER BY t)::text) FROM {table} t", dbname
        )
        standby_sum = self.standby.fetchone(
            f"SELECT md5(array_agg(t::text ORDER BY t)::text) FROM {table} t", dbname
        )
        assert primary_sum == standby_sum, (
            f"Checksum mismatch on {table}: primary={primary_sum}, standby={standby_sum}"
        )

    # ── logical replication ───────────────────────────────────────────────

    def setup_logical_publication(
        self, pub_name: str = "test_pub", tables: Optional[list] = None, dbname: str = "postgres"
    ) -> None:
        if tables:
            table_list = ", ".join(tables)
            self.primary.execute(
                f"CREATE PUBLICATION {pub_name} FOR TABLE {table_list}", dbname
            )
        else:
            self.primary.execute(
                f"CREATE PUBLICATION {pub_name} FOR ALL TABLES", dbname
            )

    def setup_logical_subscription(
        self,
        sub_name: str = "test_sub",
        pub_name: str = "test_pub",
        dbname: str = "postgres",
    ) -> None:
        conninfo = (
            f"host={self.primary.socket_dir} "
            f"port={self.primary.port} "
            f"user=postgres "
            f"dbname={dbname}"
        )
        self.standby.execute(
            f"CREATE SUBSCRIPTION {sub_name} "
            f"CONNECTION '{conninfo}' "
            f"PUBLICATION {pub_name}",
            dbname,
        )

    def wait_for_subscription_sync(self, sub_name: str = "test_sub", timeout: int = 60) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            status = self.standby.fetchone(
                f"SELECT subenabled FROM pg_subscription WHERE subname = '{sub_name}'"
            )
            if status == "t":
                return True
            time.sleep(1)
        return False
