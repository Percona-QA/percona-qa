"""
User-selectable pytest **sections** (feature areas) for ``--skip-sections``.

Each section maps to one or more pytest markers. A test is skipped when it
carries **any** marker listed for a skipped section.
"""
from __future__ import annotations

from typing import Dict, FrozenSet, Iterable, List, Set, Tuple

# Section name → markers that identify tests belonging to that section.
TEST_SECTIONS: Dict[str, FrozenSet[str]] = {
    "rewind": frozenset({"rewind"}),
    "upgrade": frozenset({"upgrade"}),
    "minor_upgrade": frozenset({"minor_upgrade"}),
    "migration": frozenset({"migration"}),
    "encryption": frozenset({"encryption"}),
    "replication": frozenset({"replication"}),
    "backup": frozenset({"backup"}),
    "recovery": frozenset({"recovery"}),
    "pgbackrest": frozenset({"pgbackrest"}),
    "vault": frozenset({"vault", "openbao"}),
    "kmip": frozenset({"kmip", "kmip_revalidation"}),
    "waldump": frozenset({"waldump"}),
    "docker": frozenset({"docker"}),
    "bug": frozenset({"bug"}),
    "slow": frozenset({"slow"}),
}

# Alternate names accepted on the CLI / in ``SKIP_SECTIONS``.
SECTION_ALIASES: Dict[str, str] = {
    "pg_rewind": "rewind",
    "pg_tde_rewind": "rewind",
    "pg-upgrade": "upgrade",
    "pg_upgrade": "upgrade",
    "minor-upgrade": "minor_upgrade",
    "pgbackrest": "pgbackrest",
}


def section_names() -> List[str]:
    return sorted(TEST_SECTIONS)


def sections_help_text() -> str:
    return "Sections: " + ", ".join(section_names())


def parse_skip_sections(raw: str) -> List[str]:
    """Parse comma/space-separated section names; apply aliases; preserve order."""
    if not raw or not raw.strip():
        return []
    names: List[str] = []
    for part in raw.replace(",", " ").split():
        key = part.strip().lower()
        if not key:
            continue
        names.append(SECTION_ALIASES.get(key, key))
    return names


def resolve_skip_sections(raw: str) -> Tuple[List[str], List[str]]:
    """
    Return ``(resolved, unknown)`` after parsing ``raw``.

    ``resolved`` is de-duplicated while keeping first occurrence order.
    """
    parsed = parse_skip_sections(raw)
    resolved: List[str] = []
    seen: Set[str] = set()
    unknown: List[str] = []
    for name in parsed:
        if name in TEST_SECTIONS:
            if name not in seen:
                resolved.append(name)
                seen.add(name)
        else:
            unknown.append(name)
    return resolved, unknown


def markers_for_sections(section_names_iter: Iterable[str]) -> FrozenSet[str]:
    out: Set[str] = set()
    for name in section_names_iter:
        out.update(TEST_SECTIONS[name])
    return frozenset(out)


def item_matches_skipped_section(item_keywords: Set[str], skip_markers: FrozenSet[str]) -> bool:
    return bool(skip_markers.intersection(item_keywords))
