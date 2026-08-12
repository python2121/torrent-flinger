"""Which glyph the tray icon shows.

Pure stdlib — shared between Linux and macOS in spirit: the Swift build
implements the same four states and the same precedence in
`macos/Sources/TorrentFlinger/Core/TrayIcon.swift`. When a rule changes here,
change it there (and in both test suites).

Deliberately only four states: the icon is a 16px monochrome silhouette, and
anything finer-grained is unreadable at that size. Per-torrent detail belongs
in the popup, not the tray.
"""
from __future__ import annotations

IDLE = "idle"
DOWNLOADING = "downloading"
ERROR = "error"
ADDED = "added"

STATES = (IDLE, DOWNLOADING, ERROR, ADDED)

# How long the "added" glyph stays up before falling back to the real state.
ADDED_DURATION_S = 3.0


def asset_name(state: str) -> str:
    """Basename of the shared SVG in flinger/assets/."""
    return f"tray-{state}"


def tray_icon(connected: bool, download_speed: int, recently_added: bool) -> str:
    """Precedence: a fresh add wins for its three seconds (it's the only one
    that's a *notification* rather than a status), then failure to reach the
    server, then transfer activity, then idle.

    "downloading" keys off download speed alone — a seeding-only session shows
    the magnet, because a down arrow would be a lie.
    """
    if recently_added:
        return ADDED
    if not connected:
        return ERROR
    if download_speed > 0:
        return DOWNLOADING
    return IDLE
