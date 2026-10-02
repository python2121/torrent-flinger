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


# File extensions worth keeping visible when a name is shortened. An allowlist
# rather than "whatever follows the last period", so ``filename.otherinfo``
# isn't mistaken for a file and ``[YTS.MX]`` isn't an extension ``MX]``.
# Lower-case; matching is case-insensitive. Mirrored in the Swift core
# (``Format.knownExtensions``) — keep the two lists identical.
KNOWN_EXTENSIONS = frozenset({
    # video
    "mkv", "mp4", "m4v", "avi", "mov", "wmv", "mpg", "mpeg", "ts", "m2ts", "webm",
    "flv", "vob", "ogv", "3gp", "divx",
    # audio
    "mp3", "flac", "aac", "m4a", "m4b", "ogg", "opus", "wav", "wma", "ape", "alac",
    "aiff", "dsf",
    # images
    "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg",
    # documents and books
    "pdf", "epub", "mobi", "azw", "azw3", "cbr", "cbz", "djvu", "txt", "doc",
    "docx", "rtf",
    # archives and disk images
    "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img",
    "dmg", "pkg", "exe", "msi", "apk", "deb", "rpm", "appimage", "bin",
    # subtitles and torrent-adjacent
    "srt", "sub", "idx", "ass", "ssa", "vtt", "nfo", "sfv", "par2", "cue", "torrent",
})


def split_extension(name: str) -> tuple[str, str]:
    """Split a torrent name into stem and trailing file extension (``".mkv"``),
    so the list can keep the extension visible when it shortens the name.

    Only extensions in ``KNOWN_EXTENSIONS`` count, and the stem must be
    non-empty. Returns ``(name, "")`` when there isn't one.
    """
    stem, dot, ext = name.rpartition(".")
    if dot and stem and ext.lower() in KNOWN_EXTENSIONS:
        return stem, dot + ext
    return name, ""


def truncate_name(name: str, fits) -> str:
    """Shorten ``name`` from the end while keeping its extension:
    ``Reacher.S04E05.1080p.WEB-DL.mkv`` becomes ``Reacher.S04E05.1080p…mkv``.

    ``fits(text) -> bool`` is the caller's measurement — pixels in a widget,
    characters in a test — and must be monotone (if a string fits, so does
    every prefix of it). The ellipsis replaces the extension's period so the
    break reads as one mark; trailing spaces and periods on the kept stem are
    dropped for the same reason. Returns the name untouched when it fits, and
    the bare ``…ext`` tail when nothing does.
    """
    if fits(name):
        return name
    stem, ext = split_extension(name)
    tail = "…" + ext[1:]

    def candidate(n: int) -> str:
        return stem[:n].rstrip(" .") + tail

    lo, hi = 0, len(stem)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if fits(candidate(mid)):
            lo = mid
        else:
            hi = mid - 1
    return candidate(lo)


def link_display_name(link: str) -> str:
    """Best-effort human name for a magnet URI or .torrent path."""
    if link.startswith("magnet:"):
        qs = parse_qs(urlparse(link).query)
        dn = qs.get("dn", [""])[0]
        return dn or "(magnet link)"
    name = unquote(link.rstrip("/").rsplit("/", 1)[-1])
    return name or link
