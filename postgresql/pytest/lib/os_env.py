"""OS / PostgreSQL install-dir discovery for Ubuntu/Debian and RHEL/OL."""
from __future__ import annotations

import os
import platform
from pathlib import Path
from typing import List, Optional, Tuple

# Majors the pytest suite is validated against with pg_tde (newest first for
# auto-detect fallback when the requested major is not installed).
SUPPORTED_PG_MAJORS: Tuple[str, ...] = ("18", "17", "16")


def normalize_pg_major(value: Optional[str], default: str = "18") -> str:
    """Return integer major as a string (``16.15`` / ``ppg-16`` → ``16``)."""
    raw = (value or "").strip()
    if not raw:
        return default
    # Strip optional ppg- prefix from repo-style values.
    if raw.lower().startswith("ppg-"):
        raw = raw[4:]
    if raw.isdigit():
        return raw
    # X.Y or X.Y.Z → X
    head = raw.split(".", 1)[0]
    return head if head.isdigit() else default


def env_pg_major(default: str = "18") -> str:
    """``PG_MAJOR`` from the environment, normalized to an integer major."""
    return normalize_pg_major(os.environ.get("PG_MAJOR"), default=default)


def os_family() -> str:
    """Return ``debian``, ``rhel``, or ``unknown`` from /etc/os-release or PATH."""
    path = Path("/etc/os-release")
    if path.is_file():
        data: dict[str, str] = {}
        for line in path.read_text().splitlines():
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, _, v = line.partition("=")
            data[k.strip()] = v.strip().strip('"')
        os_id = data.get("ID", "")
        like = data.get("ID_LIKE", "")
        blob = f"{like} {os_id}"
        if any(x in blob for x in ("debian", "ubuntu")):
            return "debian"
        if any(x in blob for x in ("rhel", "fedora", "centos", "rocky", "alma")):
            return "rhel"
        if os_id in {"ubuntu", "debian"}:
            return "debian"
        if os_id in {"rhel", "centos", "rocky", "almalinux", "ol", "oracle"}:
            return "rhel"
    # Fallbacks when os-release is missing/incomplete.
    if any(Path(p).is_file() for p in ("/usr/bin/apt-get", "/bin/apt-get")):
        return "debian"
    if any(Path(p).is_file() for p in ("/usr/bin/dnf", "/usr/bin/yum")):
        return "rhel"
    return "unknown"


def install_dir_candidates(major: int | str) -> List[Path]:
    """Ordered install roots to try for a PostgreSQL major version."""
    m = str(major)
    family = os_family()
    rhel_first = [
        Path(f"/usr/pgsql-{m}"),
        Path(f"/usr/lib/postgresql/{m}"),
        Path(f"/opt/postgresql/{m}"),
        Path(f"/opt/percona/pg{m}"),
    ]
    deb_first = [
        Path(f"/usr/lib/postgresql/{m}"),
        Path(f"/usr/pgsql-{m}"),
        Path(f"/opt/postgresql/{m}"),
        Path(f"/opt/percona/pg{m}"),
    ]
    return rhel_first if family == "rhel" else deb_first


def default_install_dir(major: int | str | None = None) -> Path:
    """Documented default path for this OS (may not exist yet)."""
    m = str(major) if major is not None else env_pg_major()
    m = normalize_pg_major(m)
    if os_family() == "rhel":
        return Path(f"/usr/pgsql-{m}")
    return Path(f"/usr/lib/postgresql/{m}")


def detect_install_dir(
    major: int | str | None = None,
    *,
    env_var: str = "INSTALL_DIR",
) -> Optional[Path]:
    """
    Resolve a usable PostgreSQL install root (must contain ``bin/initdb``).

    Order: ``env_var`` / CLI already set → candidates for ``major`` → other
    supported majors (18, 17, 16).
    """
    env = (os.environ.get(env_var) or "").strip()
    if env:
        p = Path(env)
        if (p / "bin" / "initdb").is_file():
            return p

    maj = normalize_pg_major(
        str(major) if major is not None else env_pg_major(),
    )
    majors = [maj] + [m for m in SUPPORTED_PG_MAJORS if m != maj]
    for m in majors:
        for candidate in install_dir_candidates(m):
            if (candidate / "bin" / "initdb").is_file():
                return candidate
    return None


def resolve_install_dir_default(major: int | str | None = None) -> str:
    """Value for pytest ``--install-dir`` default (existing path or OS default)."""
    maj = major if major is not None else env_pg_major()
    found = detect_install_dir(maj)
    if found is not None:
        return str(found)
    return str(default_install_dir(maj))


def cpu_arch_deb() -> str:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "amd64"
    if machine in {"aarch64", "arm64"}:
        return "arm64"
    return machine


def cpu_arch_rpm() -> str:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    if machine in {"aarch64", "arm64"}:
        return "aarch64"
    return machine
