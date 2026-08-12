"""How often to poll, given what the user asked for and what the server is doing.

Pure stdlib, so the rule is tested without a Qt app or a server. Linux-only for
now: the macOS build makes the same open/closed distinction inline in
`TorrentStore`, but has no idle slow-down — there's no shared rule here to keep
in step, unlike the rest of `core/`.
"""
from __future__ import annotations

from .transmission import (
    STATUS_CHECK_WAIT,
    STATUS_CHECKING,
    STATUS_DOWNLOAD_WAIT,
    STATUS_DOWNLOADING,
)

# Nobody is looking at the popup, so polling only keeps the tray glyph and its
# tooltip honest.
HIDDEN_POLL_MS = 30000
# Nothing is moving, so nothing the popup shows can change much.
IDLE_POLL_MS = 10000

# Verifying counts: the progress bar moves, and it's the state a torrent passes
# through on its way to downloading. Seeding doesn't — a seed box would
# otherwise never go idle.
ACTIVE_STATUSES = frozenset({STATUS_CHECK_WAIT, STATUS_CHECKING,
                             STATUS_DOWNLOAD_WAIT, STATUS_DOWNLOADING})


def any_active(torrents: list[dict]) -> bool:
    """Whether the server is working on something, queued or running."""
    return any(t.get("status", 0) in ACTIVE_STATUSES for t in torrents)


def poll_interval_ms(configured: int, visible: bool, active: bool,
                     slow_when_idle: bool) -> int:
    """The gap until the next poll.

    A hidden popup is always the lazy case. A visible one with nothing active
    falls back to `IDLE_POLL_MS` — but never to something *faster* than the
    user asked for, because picking 30s and then being polled every 10s would
    be a surprise in the wrong direction.
    """
    if not visible:
        return HIDDEN_POLL_MS
    if slow_when_idle and not active:
        return max(configured, IDLE_POLL_MS)
    return configured
