"""Human-readable formatting. Pure stdlib — shared between Linux and macOS.

Transmission reports sizes in SI units (1000-based), so we do too.
"""
from __future__ import annotations

from urllib.parse import parse_qs, unquote, urlparse


def fmt_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} PB"


def fmt_speed(n: float) -> str:
    return f"{fmt_size(n)}/s"


def fmt_eta(seconds: int) -> str:
    if seconds is None or seconds < 0:
        return ""
    if seconds >= 86400:
        return f"{seconds // 86400}d {seconds % 86400 // 3600}h"
    if seconds >= 3600:
        return f"{seconds // 3600}h {seconds % 3600 // 60}m"
    if seconds >= 60:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds}s"


STATUS_NAMES = {
    0: "Paused",
    1: "Queued to verify",
    2: "Verifying",
    3: "Queued to download",
    4: "Downloading",
    5: "Queued to seed",
    6: "Seeding",
}


def status_name(code: int) -> str:
    return STATUS_NAMES.get(code, f"Unknown ({code})")


def fmt_date(epoch: int | None) -> str:
    if not epoch or epoch <= 0:
        return "—"
    from datetime import datetime
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M")


def map_remote_path(remote_path: str, remote_prefix: str, local_prefix: str) -> str | None:
    """Translate a path on the server to its location under a local mount.
    Returns None when the mapping isn't configured or doesn't apply."""
    if not (remote_path and remote_prefix and local_prefix):
        return None
    path = remote_path.rstrip("/")
    prefix = remote_prefix.rstrip("/")
    if path == prefix:
        relative = ""
    elif path.startswith(prefix + "/"):
        relative = path[len(prefix) + 1:]
    else:
        return None
    local = local_prefix.rstrip("/")
    return f"{local}/{relative}" if relative else local


def common_remote_root(paths: list[str]) -> str | None:
    """Deepest common ancestor of the server-side download dirs — used to
    infer the share root when no explicit remote prefix is configured."""
    import posixpath
    paths = [p.rstrip("/") for p in paths if p and p.startswith("/")]
    if not paths:
        return None
    try:
        root = posixpath.commonpath(paths)
    except ValueError:
        return None
    return root if root not in ("", "/") else None


def resolve_local_path(remote_dir: str, remote_prefix: str, local_prefix: str,
                       exists) -> str | None:
    """Find where remote_dir lives under the local mount.

    Tries the prefix mapping first, then falls back to suffix probing: walk
    remote_dir's path suffixes (longest first) and take the first one that
    exists under the mount — this self-discovers the alignment even when the
    share is exported at a different depth than the configured/derived prefix.
    Only ever returns a path that exists locally.
    """
    if not (remote_dir and local_prefix):
        return None
    mapped = map_remote_path(remote_dir, remote_prefix, local_prefix)
    if mapped and exists(mapped):
        return mapped
    parts = [p for p in remote_dir.strip("/").split("/") if p]
    local = local_prefix.rstrip("/")
    for i in range(len(parts)):
        candidate = local + "/" + "/".join(parts[i:])
        if exists(candidate):
            return candidate
    return None


def link_display_name(link: str) -> str:
    """Best-effort human name for a magnet URI or .torrent path."""
    if link.startswith("magnet:"):
        qs = parse_qs(urlparse(link).query)
        dn = qs.get("dn", [""])[0]
        return dn or "(magnet link)"
    name = unquote(link.rstrip("/").rsplit("/", 1)[-1])
    return name or link
