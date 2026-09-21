#!/usr/bin/env python3
"""Non-GTID, non-rewrite fetch/pull streaming test for percona-binlog-server.

replication.mode=position, server gtid_mode=OFF, no rewrite. See
setup.FetchPullStreamingScenario's docstring for the full scenario steps;
basedir, binlog_server_bin, and storage settings come from --config
(default: config.json in pbs-tests/), not from command-line flags.
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
    return p


def main() -> int:
    args = build_parser().parse_args()
    ok = setup.FetchPullStreamingScenario(
        args, name="position-no-rewrite", gtid_mode=False, replication_mode="position", use_rewrite=False,
    ).run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
