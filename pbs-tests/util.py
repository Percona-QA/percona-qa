"""Stateless helpers shared across the test framework.

Nothing here holds scenario or server-process state -- these are safe to
import and call directly from anywhere: servers.py, setup.py, and the
test scripts themselves. This is the leaf module of the framework (it
imports nothing else from this project), which servers.py and setup.py
both build on top of.
"""

from __future__ import annotations

import json
import logging
import re
import socket
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple

LOG = logging.getLogger("pbs_streaming_test")


class TestFailure(Exception):
    """Raised when a scenario step fails an assertion or a subprocess call."""


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
    )


# CLI flags whose value is a credential, across every command run() is
# actually called with in this project (generate_binsrv_config()'s
# --password/--s3-secret-access-key, Sysbench's --mysql-password=...).
# Covers both "--flag value" (two argv elements) and "--flag=value" (one
# combined element, e.g. sysbench's own style). Deliberately does NOT
# include --s3-secret-access-key-env: that flag's value is an environment
# variable *name*, not the secret itself, so it's safe to display as-is.
_SENSITIVE_FLAGS = ("--password", "--s3-secret-access-key", "--mysql-password")


def redact_command(cmd: list) -> List[str]:
    """Returns cmd as a list of display-safe strings, with any value that
    follows (or is combined via "=" with) a flag in _SENSITIVE_FLAGS
    replaced by a placeholder. For logging/error messages only -- never
    pass this to subprocess.run(); the caller must keep the original,
    unredacted cmd for that."""
    redacted: List[str] = []
    mask_next = False
    for arg in cmd:
        text = str(arg)
        if mask_next:
            redacted.append("***")
            mask_next = False
            continue
        if text in _SENSITIVE_FLAGS:
            redacted.append(text)
            mask_next = True
            continue
        combined_flag = next((f for f in _SENSITIVE_FLAGS if text.startswith(f + "=")), None)
        redacted.append(f"{combined_flag}=***" if combined_flag else text)
    return redacted


def run(cmd: list, *, check: bool = True, capture: bool = False, timeout: Optional[float] = None):
    display_cmd = " ".join(redact_command(cmd))
    LOG.debug("+ %s", display_cmd)
    kwargs: dict = {}
    if capture:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        result = subprocess.run(cmd, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as exc:
        raise TestFailure(f"command timed out after {timeout}s: {display_cmd}") from exc
    if check and result.returncode != 0:
        stderr = getattr(result, "stderr", "") or ""
        raise TestFailure(
            f"command failed (exit {result.returncode}): {display_cmd}\n{stderr[-4000:]}"
        )
    return result


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def load_key_value_config(path: Path) -> Dict[str, str]:
    """Parses a simple flat `key=value` config file: one assignment per
    line, blank lines and lines starting with '#' ignored, whitespace
    around the key/value stripped. Returns {} if the file doesn't exist --
    callers treat an absent file the same as every key being unset, never
    as an error, so a test with no such file just keeps its own defaults."""
    if not path.is_file():
        return {}
    values: Dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def assert_response_ok(payload: dict, context: str) -> None:
    status = payload.get("status")
    if status not in ("success", "warning"):
        raise TestFailure(f"{context} failed: {payload}")
    if status == "warning":
        LOG.warning("%s returned a warning: %s", context, payload.get("message"))


def total_bytes(payload: dict) -> int:
    return sum(r.get("size", 0) for r in payload.get("result", []))


def tail_log_file(path: Path, lines: int = 20) -> str:
    """Best-effort tail of a log file, for enriching a bare 'process exited
    with code N' failure with the actual binlog_server-reported reason --
    e.g. a storage-consistency error from a SIGKILL landing mid-rotation,
    which is otherwise only visible by manually opening binsrv.log."""
    try:
        content = path.read_text(errors="replace")
    except OSError as exc:
        return f"<could not read {path}: {exc}>"
    tail_lines = content.splitlines()[-lines:]
    return "\n".join(tail_lines) if tail_lines else f"<{path} is empty>"


# The message binlog_server's storage constructor raises (validate_binlog_index()
# in storage.cpp) when a binlog payload+metadata pair exists on disk but the
# index doesn't reference it yet -- the signature of a hard kill (SIGKILL)
# landing between save_binlog_metadata() and save_binlog_index() during a
# rotation: the new file and its metadata are already written, but the index
# rewrite that would add them was interrupted mid-write.
ORPHAN_INDEX_ERROR_MARKER = "storage contains an object that is not referenced in the binlog index"

# Objects that live at the storage root but are never a binlog payload file
# themselves (see filesystem_storage_backend.cpp / storage.hpp): the index,
# the overall storage metadata, and per-binlog metadata/temp companions,
# recognized by name or suffix.
_STORAGE_RESERVED_OBJECT_NAMES = {"binlog.index", "metadata.json"}
_STORAGE_NON_PAYLOAD_SUFFIXES = (".json", ".tmp")

# Every binlog_server naming scheme (plain "mysql-bin.000001" or a
# rewrite-mode custom base name like "bnlg.000001") is "<base>.<digits>".
_BINLOG_NAME_PATTERN = re.compile(r"^(?P<base>.+)\.(?P<seq>\d+)$")


def _parse_binlog_name(name: str) -> Optional[Tuple[str, int]]:
    """Splits a binlog file name into (base_name, sequence_number) via the
    "<base>.<digits>" pattern, or None if it doesn't match."""
    m = _BINLOG_NAME_PATTERN.match(name)
    if not m:
        return None
    return m.group("base"), int(m.group("seq"))


def find_and_repair_orphaned_binlog(storage_dir: Path) -> Optional[str]:
    """File backend only: repairs the one specific post-hard-kill
    inconsistency binlog_server's own validate_binlog_index() can't recover
    from itself -- the newest rotated binlog file's metadata was written but
    the index commit that would reference it was interrupted (see
    ORPHAN_INDEX_ERROR_MARKER's comment above). Removes that file and its
    .json metadata companion and returns its name, but only when ALL of the
    following hold, so this stays a narrow repair for exactly that one crash
    signature rather than a blind "delete anything unreferenced" pass:

      * There is exactly one binlog payload file not referenced by
        binlog.index (a count of zero means something else is wrong, and
        more than one is a bigger inconsistency not to guess at).
      * Its name follows the "<base>.<digits>" pattern every binlog_server
        naming scheme uses.
      * It is also the highest-sequence file *on disk* among files sharing
        its base name -- i.e. it really is the newest rotation attempt, not
        some older, unrelated gap sitting alongside a more recent file.
      * Its sequence number is exactly one more than the highest sequence
        number among same-base files binlog.index DOES reference --
        confirming it is the very next rotation, with no gap.
      * That last-referenced file is itself present on disk and has a
        valid, parseable .json metadata file -- i.e. the index's own last
        entry is intact and trustworthy before anything is deleted on the
        strength of it.

    A no-op (returns None) if storage_dir isn't a real storage directory
    (e.g. the S3 backend, which never populates it), the index can't be
    read, or any of the checks above fails.
    """
    index_path = storage_dir / "binlog.index"
    if not storage_dir.is_dir() or not index_path.is_file():
        return None

    try:
        referenced = {Path(line.strip()).name for line in index_path.read_text().splitlines() if line.strip()}
        payload_names = {
            p.name for p in storage_dir.iterdir()
            if p.is_file() and p.name not in _STORAGE_RESERVED_OBJECT_NAMES
            and not p.name.endswith(_STORAGE_NON_PAYLOAD_SUFFIXES)
        }
    except OSError as exc:
        LOG.warning("could not inspect %s for an orphaned binlog file: %s", storage_dir, exc)
        return None

    orphans = payload_names - referenced
    if len(orphans) != 1:
        return None
    orphan_name = next(iter(orphans))

    orphan_parsed = _parse_binlog_name(orphan_name)
    if orphan_parsed is None:
        return None
    orphan_base, orphan_seq = orphan_parsed

    # Every other file sharing the orphan's base name, on disk, must be
    # older -- otherwise this isn't "the newest rotation wasn't indexed
    # yet", it's some other, less-understood gap.
    same_base_on_disk_seqs = []
    for name in payload_names:
        if name == orphan_name:
            continue
        parsed = _parse_binlog_name(name)
        if parsed is not None and parsed[0] == orphan_base:
            same_base_on_disk_seqs.append(parsed[1])
    if any(seq > orphan_seq for seq in same_base_on_disk_seqs):
        return None

    # The highest-sequence same-base file binlog.index actually references
    # must be exactly one behind the orphan, present on disk, and have
    # metadata that's actually valid JSON.
    same_base_referenced = []
    for name in referenced:
        parsed = _parse_binlog_name(name)
        if parsed is not None and parsed[0] == orphan_base:
            same_base_referenced.append((name, parsed[1]))
    if not same_base_referenced:
        return None
    last_indexed_name, last_indexed_seq = max(same_base_referenced, key=lambda t: t[1])

    if orphan_seq != last_indexed_seq + 1:
        return None
    if last_indexed_name not in payload_names:
        return None
    try:
        json.loads((storage_dir / f"{last_indexed_name}.json").read_text())
    except (OSError, json.JSONDecodeError):
        return None

    orphan_payload = storage_dir / orphan_name
    orphan_metadata = storage_dir / f"{orphan_name}.json"
    has_metadata = orphan_metadata.is_file()

    LOG.warning(
        "found binlog file %r not referenced by binlog.index -- confirmed as the signature of "
        "a hard kill landing mid-rotation (it is the newest same-named file on disk, and its "
        "sequence number immediately follows the last properly indexed file %r, which itself "
        "has valid metadata); removing it%s",
        orphan_name, last_indexed_name, " and its .json metadata" if has_metadata else "",
    )
    for path in (orphan_payload, orphan_metadata if has_metadata else None):
        if path is None:
            continue
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    return orphan_name
