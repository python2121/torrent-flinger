"""The tray popup, styled after Plasma 6 applets (plasma-nm anatomy):
header strip (title row + toolbar with turtle toggle, search, add button),
status-grouped torrent list with expandable rows, footer with aggregate
speeds + free space and web-UI/settings buttons. All colors from QPalette.
"""
from __future__ import annotations

from PySide6.QtCore import QEvent, QRect, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QCursor, QFontMetrics, QGuiApplication, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMenu,
    QScrollArea,
    QSizePolicy,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ..core.formats import fmt_size, fmt_speed, link_display_name
from .style import NEGATIVE, POSITIVE, argb, build_stylesheet, small_font
from .torrent_row import TorrentRow

GROUP_ORDER = ["Error", "Downloading", "Verifying", "Seeding", "Paused", "Finished"]


class SectionHeader(QWidget):
    """Small label + horizontal line — Plasma's ListSectionHeader."""

    def __init__(self, text: str, parent=None):
        super().__init__(parent)
        self.label = QLabel(text)
        self.label.setFont(small_font())
        self.label.setProperty("class", "subtitle")
        line = QFrame(objectName="hline")
        line.setFixedHeight(1)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 6, 4, 0)
        layout.setSpacing(8)
        layout.addWidget(self.label)
        layout.addWidget(line, 1)


class Popup(QWidget):
    turtle_toggled = Signal(bool)
    pause_clicked = Signal(int)
    resume_clicked = Signal(int)
    remove_clicked = Signal(int, bool)
    details_requested = Signal(int)
    add_link = Signal(str)
    add_file_requested = Signal()
    open_web_requested = Signal()
    settings_requested = Signal()
    stats_requested = Signal()
    notify = Signal(str, str)

    def __init__(self, parent=None):
        super().__init__(parent)
        # NOT Qt.Popup: popup windows are override-redirect, so KWin neither
        # manages nor revokes their focus — under XWayland that means no
        # deactivate event ever fires and outside clicks can't dismiss. A Tool
        # window is KWin-managed: it activates on show and deactivates (→ hide)
        # when anything else is clicked, X11 or Wayland alike.
        self.setWindowFlags(Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self._rows: dict[int, TorrentRow] = {}
        self._section_headers: list[SectionHeader] = []
        self._layout_key: list = []
        self._dismissed_clip = ""

        root_frame = QFrame(objectName="popupRoot")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(root_frame)
        root = QVBoxLayout(root_frame)
        root.setContentsMargins(1, 1, 1, 1)
        root.setSpacing(0)

        # --- header: title row --------------------------------------------
        heading = QWidget(objectName="popupHeading")
        heading_layout = QVBoxLayout(heading)
        heading_layout.setContentsMargins(8, 6, 8, 6)
        heading_layout.setSpacing(4)

        self.title_label = QLabel("Transmission", objectName="popupTitle")
        self.status_label = QLabel()
        self.status_label.setFont(small_font())
        title_row = QHBoxLayout()
        title_row.setSpacing(6)
        title_row.addWidget(self.title_label)
        title_row.addStretch(1)
        title_row.addWidget(self.status_label)
        heading_layout.addLayout(title_row)

        # --- header: toolbar row ------------------------------------------
        self.turtle_btn = QToolButton(autoRaise=True, checkable=True, text="🐢")
        self.turtle_btn.setToolTip("Turtle mode (alternative speed limits)")
        self.turtle_btn.toggled.connect(self._on_turtle)

        self.search = QLineEdit(placeholderText="Search…", clearButtonEnabled=True)
        self.search.textChanged.connect(self._apply_filter)
        self.search.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        add_btn = QToolButton(autoRaise=True, text="＋")
        add_btn.setToolTip("Add torrent")
        add_menu = QMenu(add_btn)
        add_menu.addAction(QAction("Add torrent file…", add_menu,
                                   triggered=self.add_file_requested))
        add_menu.addAction(QAction("Add magnet from clipboard", add_menu,
                                   triggered=self._add_clip_now))
        add_btn.setMenu(add_menu)
        add_btn.setPopupMode(QToolButton.InstantPopup)

        toolbar = QHBoxLayout()
        toolbar.setSpacing(4)
        toolbar.addWidget(self.turtle_btn)
        toolbar.addSpacing(12)
        toolbar.addWidget(self.search)
        toolbar.addWidget(add_btn)
        heading_layout.addLayout(toolbar)
        root.addWidget(heading)

        top_line = QFrame(objectName="hline")
        top_line.setFixedHeight(1)
        root.addWidget(top_line)

        # --- clipboard banner ---------------------------------------------
        self.clip_banner = QFrame(objectName="clipBanner")
        clip_layout = QHBoxLayout(self.clip_banner)
        clip_layout.setContentsMargins(8, 2, 4, 2)
        self.clip_label = QLabel(objectName="clipText")
        self.clip_label.setFont(small_font())
        clip_add = QToolButton(autoRaise=True, text="Add")
        clip_add.clicked.connect(self._add_clip_now)
        clip_close = QToolButton(autoRaise=True, text="✕")
        clip_close.clicked.connect(self._dismiss_clip)
        clip_layout.addWidget(self.clip_label, 1)
        clip_layout.addWidget(clip_add)
        clip_layout.addWidget(clip_close)
        banner_holder = QVBoxLayout()
        banner_holder.setContentsMargins(8, 4, 8, 0)
        banner_holder.addWidget(self.clip_banner)
        root.addLayout(banner_holder)
        self.clip_banner.hide()

        # --- torrent list --------------------------------------------------
        self.scroll = QScrollArea(objectName="listScroll")
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list_container = QWidget()
        self.list_layout = QVBoxLayout(self.list_container)
        self.list_layout.setContentsMargins(8, 4, 8, 8)
        self.list_layout.setSpacing(4)
        self.placeholder = QLabel("Connecting…")
        self.placeholder.setAlignment(Qt.AlignCenter)
        self.placeholder.setProperty("class", "subtitle")
        self.placeholder.setWordWrap(True)
        self.list_layout.addWidget(self.placeholder)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.list_container)
        root.addWidget(self.scroll, 1)

        # --- footer --------------------------------------------------------
        bottom_line = QFrame(objectName="hline")
        bottom_line.setFixedHeight(1)
        root.addWidget(bottom_line)
        footer = QWidget(objectName="popupFooter")
        footer_layout = QHBoxLayout(footer)
        footer_layout.setContentsMargins(8, 4, 8, 4)
        self.footer_stats = QLabel(objectName="footerStats")
        self.footer_stats.setFont(small_font())
        self.footer_stats.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        stats_btn = QToolButton(autoRaise=True, text="Σ", toolTip="Statistics")
        stats_btn.clicked.connect(self.stats_requested)
        web_btn = QToolButton(autoRaise=True, text="🌐", toolTip="Open web interface")
        web_btn.clicked.connect(self.open_web_requested)
        settings_btn = QToolButton(autoRaise=True, text="⚙", toolTip="Configure…")
        settings_btn.clicked.connect(self.settings_requested)
        footer_layout.addWidget(self.footer_stats, 1)
        footer_layout.addWidget(stats_btn)
        footer_layout.addWidget(web_btn)
        footer_layout.addWidget(settings_btn)
        root.addWidget(footer)

        # Size in font units like Plasma (gridUnit = font height, popup =
        # gridUnit * 24 wide) so large fonts / scaling don't overflow the frame.
        self._grid = max(QFontMetrics(QApplication.font()).height(), 14)
        self.setFixedSize(self._grid * 24, self._grid * 31)
        self._apply_theme()
        QShortcut(QKeySequence.Find, self, activated=self.search.setFocus)

        # Focus loss is the primary outside-click signal…
        QGuiApplication.instance().focusWindowChanged.connect(self._on_focus_window_changed)
        # …and a watchdog covers the case where the popup never received
        # activation in the first place (focus-stealing prevention): if the
        # window is inactive, no menu/dialog of ours is open, and the pointer
        # is not over the popup for ~1.5s, dismiss it.
        self._dismiss_timer = QTimer(self, interval=300, timeout=self._check_dismiss)
        self._dismiss_strikes = 0

    def _on_focus_window_changed(self, window):
        if not self.isVisible():
            return
        handle = self.windowHandle()
        if window is not None and (window is handle
                                   or window.transientParent() is handle):
            return
        self.hide()

    def _check_dismiss(self):
        if not self.isVisible():
            self._dismiss_timer.stop()
            return
        keep = (self.isActiveWindow()
                or QApplication.activeModalWidget() is not None
                or QApplication.activePopupWidget() is not None
                or self.rect().contains(self.mapFromGlobal(QCursor.pos())))
        if keep:
            self._dismiss_strikes = 0
            return
        self._dismiss_strikes += 1
        if self._dismiss_strikes >= 5:
            self.hide()

    def showEvent(self, event):
        self._dismiss_strikes = 0
        self._dismiss_timer.start()
        super().showEvent(event)

    def hideEvent(self, event):
        self._dismiss_timer.stop()
        super().hideEvent(event)

    def row_text_width(self) -> int:
        """Width available for a row's title/subtitle text (icon, buttons and
        margins subtracted) — rows elide to this so they can't widen the popup."""
        return self.width() - 150

    # --- theming -----------------------------------------------------------

    def _apply_theme(self):
        self.setStyleSheet(build_stylesheet(self.palette()))

    def changeEvent(self, e):
        if e.type() in (QEvent.PaletteChange, QEvent.ApplicationPaletteChange):
            self._apply_theme()
        super().changeEvent(e)

    # --- data --------------------------------------------------------------

    def set_server(self, label: str):
        self.title_label.setText("Transmission")
        self.title_label.setToolTip(label)

    def set_error(self, message: str) -> None:
        self.status_label.setText(
            f'<span style="color:{argb(NEGATIVE)}">●</span> Disconnected')
        self.status_label.setToolTip(message)
        if not self._rows:
            self.placeholder.setText(message)
            self.placeholder.show()
        self.footer_stats.setText(message)
        self.footer_stats.setToolTip(message)

    def set_data(self, torrents: list[dict], stats: dict, turtle: bool,
                 free_space: int = -1, server: str = "") -> None:
        if server:
            self.set_server(server)
        self.status_label.setText(
            f'<span style="color:{argb(POSITIVE)}">●</span> Connected')
        self.status_label.setToolTip("")
        self.turtle_btn.blockSignals(True)
        self.turtle_btn.setChecked(turtle)
        self.turtle_btn.blockSignals(False)

        current_ids = {t["id"] for t in torrents}
        for tid in [tid for tid in self._rows if tid not in current_ids]:
            row = self._rows.pop(tid)
            self.list_layout.removeWidget(row)
            row.deleteLater()
        for t in torrents:
            if t["id"] in self._rows:
                self._rows[t["id"]].update_torrent(t)
            else:
                row = TorrentRow(t, text_width=self.row_text_width())
                row.pause_clicked.connect(self.pause_clicked)
                row.resume_clicked.connect(self.resume_clicked)
                row.remove_clicked.connect(self.remove_clicked)
                row.details_requested.connect(self.details_requested)
                row.notify.connect(self.notify)
                self._rows[t["id"]] = row

        self._relayout()
        parts = [f"↓ {fmt_speed(stats.get('downloadSpeed', 0))}",
                 f"↑ {fmt_speed(stats.get('uploadSpeed', 0))}",
                 f"{len(torrents)} torrent{'s' if len(torrents) != 1 else ''}"]
        if free_space >= 0:
            parts.append(f"{fmt_size(free_space)} free")
        self.footer_stats.setText("   ".join(parts))

        if torrents:
            self.placeholder.hide()
        else:
            self.placeholder.setText("No torrents")
            self.placeholder.show()

    def _grouped(self) -> list[tuple[str, list[TorrentRow]]]:
        groups: dict[str, list[TorrentRow]] = {}
        for row in self._rows.values():
            groups.setdefault(row.group, []).append(row)
        return [(g, groups[g]) for g in GROUP_ORDER if g in groups]

    def _relayout(self):
        grouped = self._grouped()
        key = [(g, [r.torrent_id for r in rows]) for g, rows in grouped]
        if key == self._layout_key:
            self._update_counts(grouped)
            self._apply_filter()
            return
        self._layout_key = key
        while self.list_layout.count():
            item = self.list_layout.takeAt(0)
            if item.widget() and isinstance(item.widget(), SectionHeader):
                item.widget().deleteLater()
            elif item.widget():
                item.widget().setParent(None)
        self._section_headers = []
        self._row_sections: dict[int, SectionHeader] = {}
        self.list_layout.addWidget(self.placeholder)
        for group, rows in grouped:
            header = SectionHeader(f"{group} · {len(rows)}")
            self._section_headers.append(header)
            self.list_layout.addWidget(header)
            for row in rows:
                self.list_layout.addWidget(row)
                self._row_sections[row.torrent_id] = header
        self.list_layout.addStretch(1)
        self._apply_filter()

    def _update_counts(self, grouped):
        for header, (group, rows) in zip(self._section_headers, grouped):
            header.label.setText(f"{group} · {len(rows)}")

    def _apply_filter(self, *_):
        text = self.search.text().strip()
        visible_by_header: dict = {}
        for row in self._rows.values():
            show = row.matches(text)
            row.setVisible(show)
            header = getattr(self, "_row_sections", {}).get(row.torrent_id)
            if header is not None:
                visible_by_header[header] = visible_by_header.get(header, False) or show
        for header in self._section_headers:
            header.setVisible(visible_by_header.get(header, False))

    # --- clipboard magnet offer -------------------------------------------

    def _clip_text(self) -> str:
        return QApplication.clipboard().text().strip()

    def _maybe_offer_clip(self):
        text = self._clip_text()
        if text.startswith("magnet:") and text != self._dismissed_clip:
            self.clip_label.setText(f"Add “{link_display_name(text)}”?")
            self.clip_banner.show()
        else:
            self.clip_banner.hide()

    def _add_clip_now(self):
        text = self._clip_text()
        self.clip_banner.hide()
        if text.startswith("magnet:"):
            self._dismissed_clip = text
            self.add_link.emit(text)
        else:
            self.notify.emit("No magnet link",
                             "The clipboard doesn't contain a magnet: link.")

    def _dismiss_clip(self):
        self._dismissed_clip = self._clip_text()
        self.clip_banner.hide()

    # --- behaviour ---------------------------------------------------------

    def _on_turtle(self, checked: bool):
        self.turtle_toggled.emit(checked)

    def toggle_near(self, anchor: QRect | None) -> None:
        """Show anchored to the tray icon (when its geometry is known) or to
        the panel corner — the edge the panel occupies is derived from the gap
        between the screen's full and available geometry."""
        if self.isVisible():
            self.hide()
            return
        has_anchor = anchor is not None and anchor.isValid() and not anchor.isEmpty()
        screen = (QGuiApplication.screenAt(anchor.center()) if has_anchor else None) \
            or QGuiApplication.primaryScreen()
        full = screen.geometry()
        avail = screen.availableGeometry()

        # Gap between popup and panel. Plasma 6 floating panels float 8px off
        # the screen edge and plasmashell floats its popups a further ~8px off
        # the panel; a window closer than that also triggers the panel's
        # "window touching → dock" behavior. 8+8 keeps both properties.
        panel_gap = 16
        edge_margin = 8

        if self.height() > avail.height() - 2 * panel_gap:
            self.setFixedHeight(avail.height() - 2 * panel_gap)
        w, h = self.width(), self.height()

        if has_anchor:
            x = anchor.center().x() - w // 2
            above = anchor.center().y() > full.center().y()
            y = anchor.top() - h - edge_margin if above else anchor.bottom() + edge_margin
        elif avail.bottom() < full.bottom():      # panel at bottom (KDE default)
            x, y = avail.right() - w - edge_margin, avail.bottom() - h - panel_gap
        elif avail.top() > full.top():            # panel at top
            x, y = avail.right() - w - edge_margin, avail.top() + panel_gap
        elif avail.right() < full.right():        # panel at right
            x, y = avail.right() - w - panel_gap, avail.bottom() - h - edge_margin
        elif avail.left() > full.left():          # panel at left
            x, y = avail.left() + panel_gap, avail.bottom() - h - edge_margin
        else:
            x, y = avail.right() - w - edge_margin, avail.bottom() - h - panel_gap

        x = min(max(x, avail.left()), avail.right() - w)
        y = min(max(y, avail.top()), avail.bottom() - h)
        self.move(x, y)
        self._maybe_offer_clip()
        self.show()
        self.raise_()
        self.activateWindow()
        if self.windowHandle() is not None:
            self.windowHandle().requestActivate()  # focus-loss = our outside-click signal
        self.search.setFocus()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Escape:
            self.hide()
            return
        super().keyPressEvent(event)

    def event(self, e):
        if e.type() == QEvent.WindowDeactivate:
            self.hide()
        return super().event(e)
