"""OS / PostgreSQL install-dir discovery for Ubuntu/Debian and RHEL/OL."""
from __future__ import annotations

import os
import platform
from pathlib import Path
from typing import List, Optional


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


def default_install_dir(major: int | str = 18) -> Path:
    """Documented default path for this OS (may not exist yet)."""
    m = str(major)
    if os_family() == "rhel":
        return Path(f"/usr/pgsql-{m}")
    return Path(f"/usr/lib/postgresql/{m}")


def detect_install_dir(
    major: int | str = 18,
    *,
    env_var: str = "INSTALL_DIR",
) -> Optional[Path]:
    """
    Resolve a usable PostgreSQL install root (must contain ``bin/initdb``).

    Order: ``env_var`` / CLI already set → candidates for ``major`` → other majors.
    """
    env = (os.environ.get(env_var) or "").strip()
    if env:
        p = Path(env)
        if (p / "bin" / "initdb").is_file():
            return p

    majors = [str(major)] + [m for m in ("18", "17", "16") if m != str(major)]
    for maj in majors:
        for candidate in install_dir_candidates(maj):
            if (candidate / "bin" / "initdb").is_file():
                return candidate
    return None


def resolve_install_dir_default(major: int | str = 18) -> str:
    """Value for pytest ``--install-dir`` default (existing path or OS default)."""
    found = detect_install_dir(major)
    if found is not None:
        return str(found)
    return str(default_install_dir(major))


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
