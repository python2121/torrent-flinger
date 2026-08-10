"""Expandable torrent row, modeled on Plasma's ExpandableListItem:
44px header (32px state icon, title + small subtitle, slim progress bar,
pause/resume button, chevron), click-to-expand body with full-width flat
actions and a details grid. Hover = Highlight at 30% alpha, 50ms fade;
expansion animates 100ms InOutCubic. No zebra striping, no row separators.
"""
from __future__ import annotations

from PySide6.QtCore import (
    QEasingCurve,
    QEvent,
    QPropertyAnimation,
    Qt,
    QVariantAnimation,
    Signal,
)
from PySide6.QtGui import QFontMetrics, QPainter, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSizePolicy,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ..core.formats import fmt_eta, fmt_size, fmt_speed, status_name
from .style import NEGATIVE, POSITIVE, argb, small_font, state_color, state_pixmap, torrent_state

ROW_HEIGHT = 44
BUTTON_SIZE = 24  # square size shared by the ✕ box and the chevron
EXPAND_MS = 100
HOVER_MS = 50

DETAIL_KEYS = ["Status", "Size", "Ratio", "Peers", "ETA", "Location"]


class TorrentRow(QWidget):
    pause_clicked = Signal(int)
    resume_clicked = Signal(int)
    remove_clicked = Signal(int, bool)
    details_requested = Signal(int)
    notify = Signal(str, str)
    clicked_with_modifiers = Signal(int, object)   # (id, Qt.KeyboardModifiers)
    context_requested = Signal(int, object)        # (id, global QPoint)

    def __init__(self, torrent: dict, text_width: int = 320, parent=None):
        super().__init__(parent)
        self.torrent_id = torrent["id"]
        self._t: dict = {}
        self._text_width = max(text_width, 120)
        self._btn_mode = "pause"
        self._hover = 0.0
        self._selected = False
        self._expanded = False
        self.setAttribute(Qt.WA_Hover, True)

        self._hover_anim = QVariantAnimation(
            self, duration=HOVER_MS, easingCurve=QEasingCurve.OutQuad)
        self._hover_anim.valueChanged.connect(self._set_hover)

        # --- header row ---------------------------------------------------
        self.icon_label = QLabel()
        self.icon_label.setFixedSize(32, 32)

        self.title_label = QLabel()
        self.subtitle_label = QLabel()
        self.subtitle_label.setFont(small_font())
        self.subtitle_label.setProperty("class", "subtitle")
        # never let long text widen the popup — layout decides the width,
        # update_torrent() elides to fit
        for label in (self.title_label, self.subtitle_label):
            label.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
            label.setMinimumWidth(60)
        self.progress = QProgressBar()
        self.progress.setRange(0, 1000)
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(4)
        text_col = QVBoxLayout()
        text_col.setContentsMargins(0, 0, 0, 0)
        text_col.setSpacing(2)
        text_col.addWidget(self.title_label)
        text_col.addWidget(self.subtitle_label)
        text_col.addWidget(self.progress)

        self.toggle_btn = QToolButton(autoRaise=True)
        self.toggle_btn.setToolButtonStyle(Qt.ToolButtonTextOnly)
        self.toggle_btn.clicked.connect(self._on_toggle_btn)
        self.chevron = QToolButton(autoRaise=True, text="⌄")
        self.chevron.setFixedSize(BUTTON_SIZE, BUTTON_SIZE)
        self.chevron.clicked.connect(self.toggle_expanded)

        header = QHBoxLayout()
        header.setContentsMargins(4, 4, 4, 4)
        header.setSpacing(6)
        header.addWidget(self.icon_label)
        header.addLayout(text_col, 1)
        header.addWidget(self.toggle_btn)
        header.addWidget(self.chevron)
        self._header_widget = QWidget()
        self._header_widget.setLayout(header)
        self._header_widget.setMinimumHeight(ROW_HEIGHT)

        # --- expandable body ----------------------------------------------
        self.body = QWidget()
        self.body.setMaximumHeight(0)
        body_layout = QVBoxLayout(self.body)
        body_layout.setContentsMargins(18, 0, 18, 4)
        body_layout.setSpacing(0)

        self.details_btn = self._action_button("Details…",
                                               lambda: self.details_requested.emit(self.torrent_id))
        self.magnet_btn = self._action_button("Copy magnet link", self._copy_magnet)
        self.remove_btn = self._action_button("Remove torrent…", self._remove)
        for b in (self.details_btn, self.magnet_btn, self.remove_btn):
            body_layout.addWidget(b)

        sep = QFrame(objectName="hline")
        sep.setFixedHeight(1)
        body_layout.addSpacing(4)
        body_layout.addWidget(sep)
        body_layout.addSpacing(4)

        grid = QGridLayout()
        grid.setContentsMargins(8, 0, 8, 0)
        grid.setHorizontalSpacing(12)
        grid.setVerticalSpacing(2)
        self._detail_values: dict[str, QLabel] = {}
        for i, key in enumerate(DETAIL_KEYS):
            key_label = QLabel(key)
            key_label.setFont(small_font())
            key_label.setProperty("class", "subtitle")
            value = QLabel()
            value.setFont(small_font())
            value.setTextInteractionFlags(Qt.TextSelectableByMouse)
            grid.addWidget(key_label, i % 3, (i // 3) * 2)
            grid.addWidget(value, i % 3, (i // 3) * 2 + 1)
            self._detail_values[key] = value
        grid.setColumnStretch(1, 1)
        grid.setColumnStretch(3, 1)
        body_layout.addLayout(grid)

        self._expand_anim = QPropertyAnimation(self.body, b"maximumHeight", self)
        self._expand_anim.setDuration(EXPAND_MS)
        self._expand_anim.setEasingCurve(QEasingCurve.InOutCubic)
        self._expand_anim.finished.connect(self._after_expand)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self._header_widget)
        root.addWidget(self.body)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        self.update_torrent(torrent)

    @staticmethod
    def _action_button(text: str, slot) -> QPushButton:
        btn = QPushButton(text, flat=True)
        btn.setProperty("class", "rowAction")
        btn.setCursor(Qt.PointingHandCursor)
        btn.clicked.connect(slot)
        return btn

    # --- data --------------------------------------------------------------

    def update_torrent(self, t: dict) -> None:
        self._t = t
        state = torrent_state(t)
        palette = self.palette()

        metrics = QFontMetrics(self.title_label.font())
        self.title_label.setText(
            metrics.elidedText(t["name"], Qt.ElideRight, self._text_width))
        self.title_label.setToolTip(t["name"])

        frac = (t.get("metadataPercentComplete", 0) if state == "magnetizing"
                else t.get("percentDone", 0))
        parts = []
        if t.get("rateDownload"):
            parts.append(f"↓ {fmt_speed(t['rateDownload'])}")
        if t.get("rateUpload"):
            parts.append(f"↑ {fmt_speed(t['rateUpload'])}")
        if state == "magnetizing":
            parts.append("fetching metadata")
        elif frac < 1:
            parts.append(f"{frac * 100:.0f}%")
            eta = fmt_eta(t.get("eta", -1))
            if eta and state == "downloading":
                parts.append(eta)
        else:
            parts.append(fmt_size(t.get("totalSize", 0)))
            ratio = max(t.get("uploadRatio", 0), 0)
            parts.append(f"ratio {ratio:.2f}")
        if t.get("errorString"):
            parts = [t["errorString"]]
        subtitle = " · ".join(parts) or status_name(t.get("status", 0))
        sub_metrics = QFontMetrics(self.subtitle_label.font())
        self.subtitle_label.setText(
            sub_metrics.elidedText(subtitle, Qt.ElideRight, self._text_width))
        self.subtitle_label.setToolTip(subtitle if subtitle != self.subtitle_label.text() else "")

        self.icon_label.setPixmap(
            state_pixmap(palette, state, 32, self.devicePixelRatioF()))
        self.progress.setValue(round(frac * 1000))
        color = state_color(palette, state)
        track = argb(color, 0.19)
        self.progress.setStyleSheet(
            f"QProgressBar {{ border: none; border-radius: 2px; background: {track} }} "
            f"QProgressBar::chunk {{ border-radius: 2px; background: {argb(color)} }}")

        # Primary action: Remove (red) once complete, Resume (green) while
        # paused and incomplete, Pause (plain) while active.
        paused = t.get("status", 0) == 0
        complete = (t.get("percentDone", 0) >= 1
                    and t.get("metadataPercentComplete", 1) >= 1)
        if complete:
            self._btn_mode, text, color = "remove", "✕", NEGATIVE
        elif paused:
            self._btn_mode, text, color = "resume", "Resume", POSITIVE
        else:
            self._btn_mode, text, color = "pause", "Pause", None
        self.toggle_btn.setText(text)
        self.toggle_btn.setToolTip("Remove torrent" if self._btn_mode == "remove" else "")
        if self._btn_mode == "remove":
            # ✕ box matches the chevron's footprint exactly
            self.toggle_btn.setFixedSize(BUTTON_SIZE, BUTTON_SIZE)
        else:
            self.toggle_btn.setMinimumSize(0, 0)
            self.toggle_btn.setMaximumSize(16777215, 16777215)
        if color is None:
            self.toggle_btn.setStyleSheet("")
        else:
            outline = argb(color)
            extra = ("font-size: 15px; font-weight: bold; padding: 0px;"
                     if self._btn_mode == "remove" else "padding: 1px 8px;")
            self.toggle_btn.setStyleSheet(
                f"QToolButton {{ border: 1px solid {outline}; border-radius: 3px;"
                f" color: {outline}; {extra} }}"
                f"QToolButton:hover {{ background: {argb(color, 0.15)}; }}")
        if self._expanded:
            self._update_details()

    def _update_details(self):
        t = self._t
        ratio = max(t.get("uploadRatio", 0), 0)
        done = t.get("sizeWhenDone", 0) or t.get("totalSize", 0)
        self._detail_values["Status"].setText(status_name(t.get("status", 0)))
        self._detail_values["Size"].setText(fmt_size(done))
        self._detail_values["Ratio"].setText(f"{ratio:.2f}")
        self._detail_values["Peers"].setText(str(t.get("peersConnected", 0)))
        self._detail_values["ETA"].setText(fmt_eta(t.get("eta", -1)) or "—")
        location = t.get("downloadDir", "")
        metrics = QFontMetrics(self._detail_values["Location"].font())
        self._detail_values["Location"].setText(
            metrics.elidedText(location, Qt.ElideMiddle, 150))
        self._detail_values["Location"].setToolTip(location)

    def matches(self, text: str) -> bool:
        return not text or text.lower() in self._t.get("name", "").lower()

    @property
    def group(self) -> str:
        state = torrent_state(self._t)
        return {"downloading": "Downloading", "magnetizing": "Downloading",
                "queued": "Downloading", "verifying": "Verifying",
                "seeding": "Seeding", "error": "Error",
                "paused": "Paused", "complete": "Finished"}[state]

    # --- expansion ---------------------------------------------------------

    def toggle_expanded(self):
        self._expanded = not self._expanded
        self.chevron.setText("⌃" if self._expanded else "⌄")
        if self._expanded:
            self._update_details()
        start = self.body.maximumHeight()
        end = self.body.sizeHint().height() if self._expanded else 0
        self._expand_anim.stop()
        self._expand_anim.setStartValue(start)
        self._expand_anim.setEndValue(end)
        self._expand_anim.start()

    def collapse(self):
        if self._expanded:
            self.toggle_expanded()

    def _after_expand(self):
        if self._expanded:
            self.body.setMaximumHeight(16777215)

    # --- interaction -------------------------------------------------------

    def _on_toggle_btn(self):
        if self._btn_mode == "remove":
            self._remove()  # same confirmation flow as the expanded action
        elif self._btn_mode == "resume":
            self.resume_clicked.emit(self.torrent_id)
        else:
            self.pause_clicked.emit(self.torrent_id)

    def _copy_magnet(self):
        link = self._t.get("magnetLink", "")
        if link:
            QApplication.clipboard().setText(link)
            self.notify.emit("Magnet link copied", self._t.get("name", ""))

    def _remove(self):
        box = QMessageBox(QMessageBox.Warning, "Remove torrent",
                          f"Remove “{self._t.get('name', '')}” from Transmission?",
                          QMessageBox.Yes | QMessageBox.No, self.window())
        from PySide6.QtWidgets import QCheckBox
        check = QCheckBox("Also delete downloaded data")
        box.setCheckBox(check)
        if box.exec() == QMessageBox.Yes:
            self.remove_clicked.emit(self.torrent_id, check.isChecked())

    def mousePressEvent(self, event):
        # main area selects (expansion is chevron-only); popup owns the
        # selection set and multi-select semantics
        if (event.button() == Qt.LeftButton
                and self._header_widget.geometry().contains(event.position().toPoint())):
            self.clicked_with_modifiers.emit(self.torrent_id, event.modifiers())
        super().mousePressEvent(event)

    def contextMenuEvent(self, event):
        self.context_requested.emit(self.torrent_id, event.globalPos())

    # --- selection ---------------------------------------------------------

    def set_selected(self, selected: bool) -> None:
        if self._selected != selected:
            self._selected = selected
            self.update()

    @property
    def is_selected(self) -> bool:
        return self._selected

    # --- hover paint -------------------------------------------------------

    def _set_hover(self, value):
        self._hover = value
        self.update()

    def _animate_hover(self, target: float):
        self._hover_anim.stop()
        self._hover_anim.setStartValue(self._hover)
        self._hover_anim.setEndValue(target)
        self._hover_anim.start()

    def event(self, e):
        if e.type() == QEvent.HoverEnter:
            self._animate_hover(0.30)
        elif e.type() == QEvent.HoverLeave:
            self._animate_hover(0.0)
        elif e.type() == QEvent.PaletteChange:
            self.update_torrent(self._t)
        return super().event(e)

    def paintEvent(self, event):
        # Breeze viewitem alphas: hover 0.30, selected 0.80, selected+hover 1.0
        if self._selected:
            alpha = 1.0 if self._hover > 0 else 0.80
        else:
            alpha = self._hover
        if alpha > 0:
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            color = self.palette().color(QPalette.Highlight)
            color.setAlphaF(alpha)
            p.setBrush(color)
            p.setPen(Qt.NoPen)
            p.drawRoundedRect(self.rect(), 5, 5)
        super().paintEvent(event)
