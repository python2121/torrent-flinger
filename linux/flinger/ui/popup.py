"""The tray popup, styled after Plasma 6 applets (plasma-nm anatomy):
header strip (title row + toolbar with search and add button),
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

from ..core import transmission as tr
from ..core.formats import (completion_time, fmt_size, fmt_speed, link_display_name,
                            resolve_local_path)
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
    pause_clicked = Signal(int)
    resume_clicked = Signal(int)
    remove_clicked = Signal(int, bool)
    details_requested = Signal(int)
    files_requested = Signal(int)
    add_link = Signal(str)
    add_file_requested = Signal()
    open_web_requested = Signal()
    settings_requested = Signal()
    stats_requested = Signal()
    notify = Signal(str, str)
    # batch actions from the selection context menu (lists of torrent ids)
    pause_many = Signal(list)
    resume_many = Signal(list)
    remove_many = Signal(list, bool)

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
        self._selected_ids: set[int] = set()
        self._anchor_id: int | None = None
        self._cursor_id: int | None = None   # moving end of a Shift range
        self._mount_remote = ""
        self._mount_local = ""
        import os
        self._exists = os.path.isdir      # injectable for tests
        self._exists_any = os.path.exists  # files or dirs (torrent content)

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
        # Left/Right have to be taken before the field editor uses them to move
        # the caret, which means an event filter — unlike Up/Down, which a
        # single-line QLineEdit ignores and lets bubble up to keyPressEvent.
        self.search.installEventFilter(self)

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

    def set_data(self, torrents: list[dict], stats: dict,
                 free_space: int = -1, server: str = "") -> None:
        if server:
            self.set_server(server)
        self.status_label.setText(
            f'<span style="color:{argb(POSITIVE)}">●</span> Connected')
        self.status_label.setToolTip("")

        current_ids = {t["id"] for t in torrents}
        for tid in [tid for tid in self._rows if tid not in current_ids]:
            row = self._rows.pop(tid)
            self._selected_ids.discard(tid)
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
                row.clicked_with_modifiers.connect(self._on_row_clicked)
                row.context_requested.connect(self._on_row_context)
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
        # Server order within a group (queue position is meaningful) — except
        # Finished, which reads best newest first.
        if "Finished" in groups:
            groups["Finished"].sort(key=lambda r: completion_time(r.torrent()), reverse=True)
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

    # --- selection & context menu -----------------------------------------

    def _visual_order(self) -> list[int]:
        return [row.torrent_id for _group, rows in self._grouped()
                for row in rows if not row.isHidden()]

    def _apply_selection(self):
        for tid, row in self._rows.items():
            row.set_selected(tid in self._selected_ids)

    def _on_row_clicked(self, tid: int, modifiers):
        modifiers = Qt.KeyboardModifiers(modifiers)
        if modifiers & Qt.ShiftModifier and self._anchor_id in self._rows:
            order = self._visual_order()
            if tid in order and self._anchor_id in order:
                lo, hi = sorted((order.index(self._anchor_id), order.index(tid)))
                self._selected_ids = set(order[lo:hi + 1])
        elif modifiers & Qt.ControlModifier:
            self._selected_ids.symmetric_difference_update({tid})
            self._anchor_id = tid
        else:
            self._selected_ids = {tid}
            self._anchor_id = tid
        # Every click moves the cursor, Shift-clicks included: arrowing on from
        # a Shift-clicked row continues from where the click landed.
        self._cursor_id = tid
        self._apply_selection()

    def step_selection(self, delta: int, extend: bool = False) -> int | None:
        """Move one visible row up (-1) or down (+1), optionally extending.

        A plain step lands on exactly what a plain click on that row would
        produce; with `extend` it does what a Shift-click there would — the
        anchor stays put so the range grows and shrinks instead of ratcheting.
        Movement stops at the ends rather than wrapping, which is what every
        list view on both desktops does. With nothing selected, Down starts at
        the top and Up at the bottom.

        The cursor (the moving end) is tracked separately from the anchor: the
        two differ the moment a range is extended, and stepping from the anchor
        would leave Shift+Down stuck one row from it.
        """
        order = self._visual_order()
        if not order:
            return None
        cursor = self._cursor_id if self._cursor_id in order else None
        if cursor is None:
            selected = [tid for tid in order if tid in self._selected_ids]
            cursor = selected[-1] if selected else None
        if cursor is None:
            tid = order[0] if delta > 0 else order[-1]
        else:
            index = min(max(order.index(cursor) + delta, 0), len(order) - 1)
            tid = order[index]
        # Same path as a click, so the two can't drift apart. A Shift step with
        # no usable anchor degrades to a plain click there, as a Shift-click does.
        self._on_row_clicked(tid, Qt.ShiftModifier if extend else Qt.NoModifier)
        row = self._rows.get(tid)
        if row is not None:
            self.scroll.ensureWidgetVisible(row, 0, 8)
        return tid

    def selected_ids(self) -> list[int]:
        return [tid for tid in self._visual_order() if tid in self._selected_ids]

    def set_expanded(self, expand: bool) -> bool:
        """Open (Right) or close (Left) every highlighted row.

        Returns whether there was anything to act on: with nothing selected the
        caller hands the arrow back to the search field, whose caret it
        normally drives. Every selected row moves together, the way Pause and
        Remove already treat a multi-row selection as one thing.
        """
        ids = self.selected_ids()
        if not ids:
            return False
        for tid in ids:
            row = self._rows.get(tid)
            if row is None:
                continue
            row.expand() if expand else row.collapse()
        return True

    def clear_selection(self) -> None:
        """Drop the selection along with the anchor and cursor that go with it,
        so the next arrow key starts from the top (Down) or bottom (Up) again."""
        self._selected_ids.clear()
        self._anchor_id = None
        self._cursor_id = None
        self._apply_selection()

    def _on_row_context(self, tid: int, global_pos):
        if tid not in self._selected_ids:
            self._selected_ids = {tid}
            self._anchor_id = tid
            self._apply_selection()
        menu = self._build_context_menu(self.selected_ids())
        menu.exec(global_pos)

    def _is_paused(self, tid: int) -> bool:
        row = self._rows.get(tid)
        return row is not None and row._t.get("status", 0) == tr.STATUS_STOPPED

    def _build_context_menu(self, ids: list[int]) -> QMenu:
        """Only the entries that can act on this selection: Resume when
        something in it is stopped, Pause when something in it is running.
        Verify / reannounce / copy magnet are details-window business."""
        menu = QMenu(self)
        n = len(ids)
        suffix = "" if n == 1 else f" ({n})"
        if any(self._is_paused(i) for i in ids):
            menu.addAction(QAction(f"Resume{suffix}", menu,
                                   triggered=lambda: self.resume_many.emit(ids)))
        if any(not self._is_paused(i) for i in ids):
            menu.addAction(QAction(f"Pause{suffix}", menu,
                                   triggered=lambda: self.pause_many.emit(ids)))
        if n == 1:
            menu.addSeparator()
            paths = self._reveal_paths(ids[0])
            if paths:
                local_dir, item = paths
                menu.addAction(QAction("Reveal in Dolphin", menu,
                                       triggered=lambda: self._reveal(local_dir, item)))
            menu.addAction(QAction("Torrent files…", menu,
                                   triggered=lambda: self.files_requested.emit(ids[0])))
            menu.addAction(QAction("Details…", menu,
                                   triggered=lambda: self.details_requested.emit(ids[0])))
        menu.addSeparator()
        menu.addAction(QAction(f"Remove{suffix}…", menu,
                               triggered=lambda: self._confirm_remove(ids)))
        return menu

    def set_path_mapping(self, remote_prefix: str, local_prefix: str) -> None:
        self._mount_remote = remote_prefix
        self._mount_local = local_prefix

    def _local_path_for(self, tid: int) -> str | None:
        row = self._rows.get(tid)
        if row is None:
            return None
        return resolve_local_path(row._t.get("downloadDir", ""),
                                  self._mount_remote, self._mount_local,
                                  self._exists)

    def _reveal_paths(self, tid: int) -> tuple[str, str] | None:
        """(containing dir, torrent's own file/folder path or "").
        The item path lets Dolphin highlight the torrent itself instead of
        just opening the directory it lives in."""
        local_dir = self._local_path_for(tid)
        if not local_dir:
            return None
        name = self._rows[tid]._t.get("name", "")
        item = f"{local_dir}/{name}" if name else ""
        if item and not self._exists_any(item):
            item = ""  # not there (yet) — fall back to opening the directory
        return local_dir, item

    @staticmethod
    def _reveal(local_dir: str, item_path: str = ""):
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices
        if item_path:
            # FileManager1.ShowItems opens the parent with the item selected —
            # proper "reveal" semantics (Dolphin implements this)
            try:
                from PySide6.QtDBus import QDBusConnection, QDBusMessage
                msg = QDBusMessage.createMethodCall(
                    "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                    "org.freedesktop.FileManager1", "ShowItems")
                msg.setArguments([[QUrl.fromLocalFile(item_path).toString()], ""])
                reply = QDBusConnection.sessionBus().call(msg)
                if reply.type() != QDBusMessage.MessageType.ErrorMessage:
                    return
            except Exception:  # noqa: BLE001, S110 — any D-Bus trouble → plain open
                pass
        QDesktopServices.openUrl(QUrl.fromLocalFile(local_dir))

    def _confirm_remove(self, ids: list[int]):
        from PySide6.QtWidgets import QCheckBox, QMessageBox
        if len(ids) == 1 and ids[0] in self._rows:
            what = f"“{self._rows[ids[0]]._t.get('name', '')}”"
        else:
            what = f"{len(ids)} torrents"
        box = QMessageBox(QMessageBox.Warning, "Remove",
                          f"Remove {what} from Transmission?",
                          QMessageBox.Yes | QMessageBox.No, self)
        check = QCheckBox("Also delete downloaded data")
        box.setCheckBox(check)
        if box.exec() == QMessageBox.Yes:
            self.remove_many.emit(ids, check.isChecked())

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

    def eventFilter(self, obj, event):
        """Claim Left/Right from the search field while rows are highlighted.

        Only while highlighted: with nothing selected the arrows stay the
        caret's, or typing a filter would become unnavigable. Escape clears the
        selection, so there's always a way back to editing.
        """
        if (obj is self.search and event.type() == QEvent.KeyPress
                and event.key() in (Qt.Key_Left, Qt.Key_Right)
                and not (event.modifiers() & (Qt.ControlModifier | Qt.AltModifier
                                              | Qt.MetaModifier))):
            if self.set_expanded(event.key() == Qt.Key_Right):
                return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, event):
        # Up/Down reach us because a single-line QLineEdit ignores them, so
        # they bubble out of the search field — the same route Escape takes.
        if event.key() in (Qt.Key_Up, Qt.Key_Down) and not (
                event.modifiers() & (Qt.ControlModifier | Qt.AltModifier
                                     | Qt.MetaModifier)):
            self.step_selection(1 if event.key() == Qt.Key_Down else -1,
                                extend=bool(event.modifiers() & Qt.ShiftModifier))
            return
        if event.key() in (Qt.Key_Left, Qt.Key_Right) and not (
                event.modifiers() & (Qt.ControlModifier | Qt.AltModifier
                                     | Qt.MetaModifier)):
            if self.set_expanded(event.key() == Qt.Key_Right):
                return
        if event.key() == Qt.Key_Escape:
            # Escape peels back one layer of transient state per press:
            # selection first (the lightest, most recently made), then the
            # search filter, and only then the popup itself. The test is the
            # *visible* selection, so a press always changes something on
            # screen — rows the filter has hidden are cleared with the search
            # they're hiding behind, one press later.
            if self.selected_ids():
                self.clear_selection()
            elif self.search.text():
                self.search.clear()
            else:
                self.hide()
            return
        super().keyPressEvent(event)

    def event(self, e):
        if e.type() == QEvent.WindowDeactivate:
            self.hide()
        return super().event(e)
