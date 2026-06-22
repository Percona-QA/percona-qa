"""
Shared file keyring tests — no external KMS; always runs locally.

Server-specific file tests remain in ``tests/test_encryption.py`` and bash parity.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from lib.file_keyring_common_matrix import run_file_global_smoke, run_file_rotation

pytestmark = [pytest.mark.encryption, pytest.mark.file_keyring]


class TestFileKeyringCommonMatrix:
    def test_global_smoke_restart(self, pg_factory, tmp_path: Path):
        run_file_global_smoke(pg_factory, tmp_path)

    def test_key_rotation(self, pg_factory, tmp_path: Path):
        run_file_rotation(pg_factory, tmp_path)
