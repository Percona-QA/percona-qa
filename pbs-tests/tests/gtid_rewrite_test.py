#!/usr/bin/env python3
"""GTID + rewrite-mode fetch/pull streaming test for percona-binlog-server.

replication.mode=gtid, server gtid_mode=ON, replication.rewrite enabled.
See setup.FetchPullStreamingScenario's docstring for the full scenario
steps; basedir, binlog_server_bin, and storage settings come from
--config (default: config.json in pbs-tests/), not from command-line flags.
"""

from __future__ import annotations

import sys
from pathlib import Path

# util.py/servers.py/setup.py live in pbs-tests/, one level up from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import setup


def build_parser():
    p = setup.build_common_parser(__doc__)
    setup.add_pull_test_args(p)
    p.add_argument(
        "--rewrite-file-size", default="1M",
        help="replication.rewrite.file_size (default: %(default)s)",
    )
    return p


def main() -> int:
    args = build_parser().parse_args()
    ok = setup.FetchPullStreamingScenario(
        args, name="gtid-rewrite", gtid_mode=True, replication_mode="gtid", use_rewrite=True,
    ).run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
