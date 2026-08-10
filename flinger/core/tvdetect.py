"""Detect whether a torrent name looks like a TV show.

Pure stdlib, marker-based, precision-first:
1. episode markers (S01E02 / 3x07)   — near-certain, catches any show
2. air-date naming (Show.2026.01.15) — daily shows; movies use bare years
3. season-pack markers (S01, Season 2, Complete Series, Seasons 1-6)

Real-world TV releases essentially always carry one of these markers, so no
title list is needed. Movies default elsewhere, so a missed detection just
means picking the folder manually — same as having no detection.
"""
from __future__ import annotations

import re

EPISODE = re.compile(r"\b[Ss]\d{1,2}[._ ]?[Ee]\d{1,3}\b|\b\d{1,2}x\d{2,3}\b")
AIR_DATE = re.compile(r"\b(?:19|20)\d{2}[._ -]\d{2}[._ -]\d{2}\b")
SEASON_PACK = re.compile(
    r"\b[Ss]\d{1,2}\b"
    r"|\b[Ss]eason[._ -]?\d{1,2}\b"
    r"|\b[Ss]easons?[._ -]?\d{1,2}[-–][._ ]?\d{1,2}\b"
    r"|\b[Cc]omplete[._ -]([Ss]eries|[Ss]eason)\b"
    r"|\b[Mm]ini[._ -]?[Ss]eries\b")


def looks_like_tv(name: str) -> tuple[bool, str]:
    """(is_tv, reason). Reasons: episode | air-date | season."""
    if EPISODE.search(name):
        return True, "episode"
    if AIR_DATE.search(name):
        return True, "air-date"
    if SEASON_PACK.search(name):
        return True, "season"
    return False, ""


def find_tv_dir(custom_dirs: list[dict]) -> str | None:
    """The custom dir flagged as the final TV location, or None.
    At most one entry carries the flag (enforced by the options UI)."""
    for entry in custom_dirs:
        if entry.get("tv"):
            return entry.get("dir")
    return None
