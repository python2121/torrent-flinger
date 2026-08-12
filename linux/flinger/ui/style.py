"""Native-Plasma theming.

Everything derives from the active QPalette so Breeze light/dark (and macOS
palettes) come along automatically. QSS `palette(role)` can't carry alpha, so
translucent colors are injected as hex-ARGB and the stylesheet is rebuilt on
palette change. Numbers follow Kirigami units: smallSpacing 4, largeSpacing 8,
corner radius 5, row icon 32, animations 50/100 ms.
"""
from __future__ import annotations

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QFont, QFontDatabase, QPainter, QPalette, QPixmap

POSITIVE = QColor("#27ae60")   # Breeze positive (seeding / complete)
NEGATIVE = QColor("#da4453")   # Breeze negative (error)


def argb(color: QColor, alpha: float | None = None) -> str:
    c = QColor(color)
    if alpha is not None:
        c.setAlphaF(alpha)
    return c.name(QColor.NameFormat.HexArgb)


def subtitle_color(palette: QPalette) -> QColor:
    c = QColor(palette.color(QPalette.WindowText))
    c.setAlphaF(0.75)
    return c


def state_color(palette: QPalette, state: str) -> QColor:
    if state in ("seeding", "complete"):
        return QColor(POSITIVE)
    if state == "error":
        return QColor(NEGATIVE)
    if state in ("paused",):
        c = QColor(palette.color(QPalette.WindowText))
        c.setAlphaF(0.45)
        return c
    if state in ("verifying", "queued"):
        c = QColor(palette.color(QPalette.WindowText))
        c.setAlphaF(0.70)
        return c
    return QColor(palette.color(QPalette.Highlight))  # downloading / magnetizing


STATE_GLYPHS = {
    "downloading": "↓",
    "seeding": "↑",
    "paused": "⏸",
    "complete": "✓",
    "verifying": "↻",
    "queued": "⏱",
    "magnetizing": "⚲",
    "error": "!",
}

_icon_cache: dict[tuple, QPixmap] = {}


def state_pixmap(palette: QPalette, state: str, size: int = 32, dpr: float = 1.0) -> QPixmap:
    """32px status icon: tinted circle + glyph, drawn from palette colors so it
    matches any theme (no icon-theme dependency — works on macOS too)."""
    color = state_color(palette, state)
    key = (state, size, round(dpr * 4), color.rgba())
    if key in _icon_cache:
        return _icon_cache[key]
    px = QPixmap(int(size * dpr), int(size * dpr))
    px.setDevicePixelRatio(dpr)
    px.fill(Qt.transparent)
    p = QPainter(px)
    p.setRenderHint(QPainter.Antialiasing)
    bg = QColor(color)
    bg.setAlphaF(min(color.alphaF(), 0.18))
    p.setPen(Qt.NoPen)
    p.setBrush(bg)
    p.drawEllipse(QRectF(1, 1, size - 2, size - 2))
    font = QFont()
    font.setPixelSize(int(size * 0.55))
    font.setBold(True)
    p.setFont(font)
    p.setPen(color)
    p.drawText(QRectF(0, 0, size, size), Qt.AlignCenter, STATE_GLYPHS.get(state, "•"))
    p.end()
    _icon_cache[key] = px
    return px


_tray_cache: dict[tuple, QPixmap] = {}


def tray_pixmap(state: str, color: QColor, size: int = 22, dpr: float = 1.0) -> QPixmap:
    """Tray glyph for `state`, tinted to `color`.

    The four `tray-*.svg` files in flinger/assets are monochrome silhouettes
    shared verbatim with the macOS build. macOS gets this for free by marking
    the image as a template; Qt has no equivalent, so we render the SVG and
    then composite the colour through its alpha (SourceIn). Without that a
    black glyph would be invisible on a dark Plasma panel.

    Falls back to an empty pixmap if QtSvg is unavailable, so the caller can
    detect it and keep the old raster icon.
    """
    key = (state, color.rgba(), size, round(dpr * 4))
    if key in _tray_cache:
        return _tray_cache[key]

    from pathlib import Path
    path = Path(__file__).resolve().parent.parent / "assets" / f"tray-{state}.svg"
    px = QPixmap(int(size * dpr), int(size * dpr))
    px.setDevicePixelRatio(dpr)
    px.fill(Qt.transparent)
    try:
        from PySide6.QtSvg import QSvgRenderer
    except ImportError:  # QtSvg not in this PySide6 build
        return px
    renderer = QSvgRenderer(str(path))
    if not renderer.isValid():
        return px

    p = QPainter(px)
    p.setRenderHint(QPainter.Antialiasing)
    renderer.render(p)
    p.setCompositionMode(QPainter.CompositionMode_SourceIn)
    p.fillRect(px.rect(), color)
    p.end()
    _tray_cache[key] = px
    return px


def small_font() -> QFont:
    return QFontDatabase.systemFont(QFontDatabase.SmallestReadableFont)


def torrent_state(t: dict) -> str:
    if t.get("errorString"):
        return "error"
    if t.get("metadataPercentComplete", 1) < 1:
        return "magnetizing"
    status = t.get("status", 0)
    if status == 0:
        return "complete" if t.get("percentDone", 0) >= 1 else "paused"
    if status in (1, 2):
        return "verifying"
    if status == 3:
        return "queued"
    if status == 4:
        return "downloading"
    return "seeding"


def build_stylesheet(palette: QPalette) -> str:
    mid = argb(palette.color(QPalette.Mid))
    dark = argb(palette.color(QPalette.Dark))
    window = argb(palette.color(QPalette.Window))
    highlight = argb(palette.color(QPalette.Highlight))
    sub = argb(subtitle_color(palette))
    return f"""
#popupRoot {{
    background: {window};
    border: 1px solid {dark};
    border-radius: 5px;
}}
#popupHeading, #popupFooter {{ background: transparent; }}
QLabel#popupTitle {{ font-size: {int(palette_font_px() * 1.35)}px; }}
QLabel.subtitle, QLabel#footerStats {{ color: {sub}; }}
QFrame#hline {{ border: none; border-top: 1px solid {mid}; }}
#listScroll, #listScroll > QWidget > QWidget {{ background: transparent; border: none; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 0; }}
QScrollBar::handle:vertical {{ background: {mid}; border-radius: 4px; min-height: 24px; }}
QScrollBar::handle:vertical:hover {{ background: {highlight}; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
QPushButton.rowAction {{
    border: none;
    background: transparent;
    text-align: left;
    padding: 4px 8px;
    border-radius: 3px;
}}
QPushButton.rowAction:hover {{ background: {argb(palette.color(QPalette.Highlight), 0.30)}; }}
QLabel#clipText {{ padding: 2px; }}
#clipBanner {{
    background: {argb(palette.color(QPalette.Highlight), 0.12)};
    border: 1px solid {argb(palette.color(QPalette.Highlight), 0.45)};
    border-radius: 4px;
}}
"""


def palette_font_px() -> int:
    from PySide6.QtWidgets import QApplication
    f = QApplication.font()
    if f.pixelSize() > 0:
        return f.pixelSize()
    from PySide6.QtGui import QFontMetrics
    return QFontMetrics(f).height() - 3  # approx pt→px body size
