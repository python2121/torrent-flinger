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


def link_display_name(link: str) -> str:
    """Best-effort human name for a magnet URI or .torrent path."""
    if link.startswith("magnet:"):
        qs = parse_qs(urlparse(link).query)
        dn = qs.get("dn", [""])[0]
        return dn or "(magnet link)"
    name = unquote(link.rstrip("/").rsplit("/", 1)[-1])
    return name or link
