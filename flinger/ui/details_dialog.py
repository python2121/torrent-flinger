"""Per-torrent administration window: Info / Files / Peers / Trackers / Options.

Feature set follows the consensus of Tremotesf, transmission-remote-gtk and
transmission-qt: file wanted/priority editing, peer and tracker views,
per-torrent limits, verify/reannounce/set-location/queue actions.
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QToolButton,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..core import transmission as tr
from ..core.formats import fmt_date, fmt_eta, fmt_size, fmt_speed, status_name
from .worker import run_async

REFRESH_MS = 3000
PRIORITY_NAMES = {-1: "Low", 0: "Normal", 1: "High"}
PRIORITY_ARGS = {-1: "priority-low", 0: "priority-normal", 1: "priority-high"}


class SetLocationDialog(QDialog):
    def __init__(self, current: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Set torrent location")
        self.path = QLineEdit(current)
        self.move_data = QCheckBox("Move data to the new location")
        self.move_data.setChecked(True)
        form = QFormLayout()
        form.addRow("Location:", self.path)
        form.addRow(self.move_data)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        root = QVBoxLayout(self)
        root.addLayout(form)
        root.addWidget(buttons)
        self.setMinimumWidth(440)


class DetailsDialog(QDialog):
    def __init__(self, client, torrent_id: int, name: str, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.setWindowTitle(name)
        self.client = client
        self.torrent_id = torrent_id
        self._t: dict = {}
        self._updating = False
        self._inflight = False

        # --- action bar ---------------------------------------------------
        self.pause_btn = QPushButton("Pause")
        self.resume_btn = QPushButton("Resume")
        verify_btn = QPushButton("Verify")
        reannounce_btn = QPushButton("Reannounce")
        location_btn = QPushButton("Set location…")
        magnet_btn = QPushButton("Copy magnet")
        remove_btn = QPushButton("Remove…")
        self.pause_btn.clicked.connect(lambda: self._do(lambda: self.client.stop([self.torrent_id])))
        self.resume_btn.clicked.connect(lambda: self._do(lambda: self.client.start([self.torrent_id])))
        verify_btn.clicked.connect(lambda: self._do(lambda: self.client.verify([self.torrent_id])))
        reannounce_btn.clicked.connect(lambda: self._do(lambda: self.client.reannounce([self.torrent_id])))
        location_btn.clicked.connect(self._set_location)
        magnet_btn.clicked.connect(self._copy_magnet)
        remove_btn.clicked.connect(self._remove)
        bar = QHBoxLayout()
        for b in (self.resume_btn, self.pause_btn, verify_btn, reannounce_btn,
                  location_btn, magnet_btn, remove_btn):
            bar.addWidget(b)
        bar.addStretch(1)

        # --- tabs ---------------------------------------------------------
        self.tabs = QTabWidget()
        self.tabs.addTab(self._build_info(), "Info")
        self.tabs.addTab(self._build_files(), "Files")
        self.tabs.addTab(self._build_peers(), "Peers")
        self.tabs.addTab(self._build_trackers(), "Trackers")
        self.tabs.addTab(self._build_options(), "Options")

        root = QVBoxLayout(self)
        root.addLayout(bar)
        root.addWidget(self.tabs)
        self.resize(700, 560)

        self.timer = QTimer(self, interval=REFRESH_MS, timeout=self._refresh)
        self.timer.start()
        self._refresh()

    # --- tab construction --------------------------------------------------

    INFO_ROWS = ["Status", "Progress", "Size", "Downloaded", "Uploaded",
                 "Location", "Privacy", "Pieces", "Added", "Completed",
                 "Last activity", "Created", "Comment", "Hash", "Error"]

    def _build_info(self) -> QWidget:
        page = QWidget()
        form = QFormLayout(page)
        self._info: dict[str, QLabel] = {}
        for row in self.INFO_ROWS:
            label = QLabel("…")
            label.setTextInteractionFlags(Qt.TextSelectableByMouse)
            label.setWordWrap(True)
            self._info[row] = label
            form.addRow(row, label)
        return page

    def _build_files(self) -> QWidget:
        self.files = QTreeWidget()
        self.files.setHeaderLabels(["File", "Size", "Done", "Priority"])
        self.files.setRootIsDecorated(False)
        self.files.setSelectionMode(QTreeWidget.ExtendedSelection)
        self.files.header().setSectionResizeMode(0, QHeaderView.Stretch)
        self.files.itemChanged.connect(self._on_file_check)
        self.files.setContextMenuPolicy(Qt.CustomContextMenu)
        self.files.customContextMenuRequested.connect(self._file_menu)
        hint = QLabel("Checkbox = download this file. Right-click for priority.")
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.addWidget(self.files)
        layout.addWidget(hint)
        return page

    def _build_peers(self) -> QWidget:
        self.peers = QTableWidget(0, 6)
        self.peers.setHorizontalHeaderLabels(
            ["Address", "Client", "Flags", "Progress", "Down", "Up"])
        self.peers.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.peers.verticalHeader().setVisible(False)
        self.peers.setEditTriggers(QTableWidget.NoEditTriggers)
        self.peers.setSortingEnabled(True)
        return self.peers

    def _build_trackers(self) -> QWidget:
        self.trackers = QTableWidget(0, 5)
        self.trackers.setHorizontalHeaderLabels(
            ["Tracker", "Seeders", "Leechers", "Last announce", "Next announce"])
        self.trackers.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        self.trackers.verticalHeader().setVisible(False)
        self.trackers.setEditTriggers(QTableWidget.NoEditTriggers)
        return self.trackers

    def _build_options(self) -> QWidget:
        self.opt_dl_limited = QCheckBox("Limit download speed (KB/s)")
        self.opt_dl_limit = QSpinBox(minimum=1, maximum=10_000_000)
        self.opt_ul_limited = QCheckBox("Limit upload speed (KB/s)")
        self.opt_ul_limit = QSpinBox(minimum=1, maximum=10_000_000)
        self.opt_ratio_mode = QComboBox()
        self.opt_ratio_mode.addItems(["Use global setting", "Stop at ratio:", "Seed forever"])
        self.opt_ratio = QDoubleSpinBox(minimum=0.0, maximum=1000.0, singleStep=0.1)
        self.opt_peer_limit = QSpinBox(minimum=1, maximum=10000)
        apply_btn = QPushButton("Apply")
        apply_btn.clicked.connect(self._apply_options)
        self.queue_label = QLabel("…")
        queue_row = QHBoxLayout()
        queue_row.addWidget(self.queue_label)
        for text, where in (("⤒ Top", "top"), ("↑ Up", "up"),
                            ("↓ Down", "down"), ("⤓ Bottom", "bottom")):
            btn = QToolButton(text=text)
            btn.clicked.connect(
                lambda _=False, w=where: self._do(
                    lambda: self.client.queue_move([self.torrent_id], w)))
            queue_row.addWidget(btn)
        queue_row.addStretch(1)

        page = QWidget()
        form = QFormLayout(page)
        form.addRow(self.opt_dl_limited, self.opt_dl_limit)
        form.addRow(self.opt_ul_limited, self.opt_ul_limit)
        form.addRow(self.opt_ratio_mode, self.opt_ratio)
        form.addRow("Peer limit", self.opt_peer_limit)
        form.addRow("Queue", queue_row)
        form.addRow(apply_btn)
        return page

    # --- refresh ------------------------------------------------------------

    def _refresh(self):
        if self._inflight:
            return
        self._inflight = True
        run_async(lambda: self.client.torrent_details(self.torrent_id),
                  on_done=self._populate, on_error=self._on_error)

    def _on_error(self, message: str):
        self._inflight = False
        if "not found" in message:  # torrent removed on the server
            self.close()
        else:
            self._info["Error"].setText(message)

    def _populate(self, t: dict):
        self._inflight = False
        self._t = t
        paused = t["status"] == tr.STATUS_STOPPED
        self.pause_btn.setVisible(not paused)
        self.resume_btn.setVisible(paused)

        done = t.get("haveValid", 0) + t.get("haveUnchecked", 0)
        size = t.get("sizeWhenDone", 0) or t.get("totalSize", 0)
        ratio = max(t.get("uploadRatio", 0), 0)
        eta = fmt_eta(t.get("eta", -1))
        info = {
            "Status": status_name(t["status"]) + (f" — {eta} remaining" if eta and t["status"] == 4 else ""),
            "Progress": f"{t.get('percentDone', 0) * 100:.1f}%"
                        + (f" (DL {fmt_speed(t.get('rateDownload', 0))}, UL {fmt_speed(t.get('rateUpload', 0))})"
                           if t.get("rateDownload") or t.get("rateUpload") else ""),
            "Size": f"{fmt_size(done)} of {fmt_size(size)}",
            "Downloaded": fmt_size(t.get("downloadedEver", 0))
                          + (f" ({fmt_size(t.get('corruptEver', 0))} corrupt)" if t.get("corruptEver") else ""),
            "Uploaded": f"{fmt_size(t.get('uploadedEver', 0))} (ratio {ratio:.2f})",
            "Location": t.get("downloadDir", ""),
            "Privacy": "Private torrent" if t.get("isPrivate") else "Public torrent",
            "Pieces": f"{t.get('pieceCount', 0)} × {fmt_size(t.get('pieceSize', 0))}",
            "Added": fmt_date(t.get("addedDate")),
            "Completed": fmt_date(t.get("doneDate")),
            "Last activity": fmt_date(t.get("activityDate")),
            "Created": fmt_date(t.get("dateCreated"))
                       + (f" by {t['creator']}" if t.get("creator") else ""),
            "Comment": t.get("comment", ""),
            "Hash": t.get("hashString", ""),
            "Error": t.get("errorString", "") or "—",
        }
        for key, value in info.items():
            self._info[key].setText(str(value))

        self._populate_files(t)
        self._populate_peers(t.get("peers", []))
        self._populate_trackers(t.get("trackerStats", []))
        if not self.opt_dl_limit.hasFocus() and not self.opt_ul_limit.hasFocus():
            self._populate_options(t)

    def _populate_files(self, t: dict):
        files = t.get("files", [])
        stats = t.get("fileStats", [])
        self._updating = True
        try:
            if self.files.topLevelItemCount() != len(files):
                self.files.clear()
                for i, f in enumerate(files):
                    item = QTreeWidgetItem(["", "", "", ""])
                    item.setData(0, Qt.UserRole, i)
                    item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
                    self.files.addTopLevelItem(item)
            for i, (f, s) in enumerate(zip(files, stats)):
                item = self.files.topLevelItem(i)
                item.setText(0, f["name"])
                item.setToolTip(0, f["name"])
                item.setText(1, fmt_size(f.get("length", 0)))
                length = f.get("length", 0) or 1
                item.setText(2, f"{s.get('bytesCompleted', 0) / length * 100:.0f}%")
                item.setText(3, PRIORITY_NAMES.get(s.get("priority", 0), "Normal"))
                # wanted is serialized as 0/1, not boolean — treat as truthy
                item.setCheckState(0, Qt.Checked if s.get("wanted") else Qt.Unchecked)
        finally:
            self._updating = False

    def _populate_peers(self, peers: list[dict]):
        self.peers.setSortingEnabled(False)
        self.peers.setRowCount(len(peers))
        for row, p in enumerate(peers):
            cells = [p.get("address", ""), p.get("clientName", ""),
                     p.get("flagStr", ""), f"{p.get('progress', 0) * 100:.0f}%",
                     fmt_speed(p.get("rateToClient", 0)) if p.get("rateToClient") else "",
                     fmt_speed(p.get("rateToPeer", 0)) if p.get("rateToPeer") else ""]
            for col, text in enumerate(cells):
                self.peers.setItem(row, col, QTableWidgetItem(text))
        self.peers.setSortingEnabled(True)

    def _populate_trackers(self, stats: list[dict]):
        self.trackers.setRowCount(len(stats))
        for row, s in enumerate(stats):
            last = s.get("lastAnnounceResult", "") or "—"
            if not s.get("lastAnnounceSucceeded", True) and last != "—":
                last = f"⚠ {last}"
            cells = [s.get("host", "") or s.get("announce", ""),
                     str(s.get("seederCount", -1)), str(s.get("leecherCount", -1)),
                     last, fmt_date(s.get("nextAnnounceTime"))]
            for col, text in enumerate(cells):
                self.trackers.setItem(row, col, QTableWidgetItem(text))

    def _populate_options(self, t: dict):
        self.opt_dl_limited.setChecked(bool(t.get("downloadLimited")))
        self.opt_dl_limit.setValue(int(t.get("downloadLimit", 100) or 100))
        self.opt_ul_limited.setChecked(bool(t.get("uploadLimited")))
        self.opt_ul_limit.setValue(int(t.get("uploadLimit", 100) or 100))
        self.opt_ratio_mode.setCurrentIndex(int(t.get("seedRatioMode", 0)))
        self.opt_ratio.setValue(float(t.get("seedRatioLimit", 2.0)))
        self.opt_peer_limit.setValue(int(t.get("peer-limit", 50) or 50))
        self.queue_label.setText(f"position {t.get('queuePosition', 0)}")

    # --- actions ------------------------------------------------------------

    def _do(self, fn):
        run_async(fn, on_done=lambda _: self._refresh(),
                  on_error=lambda msg: QMessageBox.warning(self, "Transmission error", msg))

    def _on_file_check(self, item, column):
        if self._updating or column != 0:
            return
        index = item.data(0, Qt.UserRole)
        key = "files-wanted" if item.checkState(0) == Qt.Checked else "files-unwanted"
        self._do(lambda: self.client.torrent_set([self.torrent_id], {key: [index]}))

    def _file_menu(self, pos):
        items = self.files.selectedItems() or [self.files.itemAt(pos)]
        items = [i for i in items if i is not None]
        if not items:
            return
        indices = [i.data(0, Qt.UserRole) for i in items]
        menu = QMenu(self)
        for prio, label in ((1, "High priority"), (0, "Normal priority"), (-1, "Low priority")):
            menu.addAction(QAction(
                label, menu, triggered=lambda _=False, p=prio: self._do(
                    lambda: self.client.torrent_set(
                        [self.torrent_id], {PRIORITY_ARGS[p]: indices}))))
        menu.addSeparator()
        menu.addAction(QAction("Download", menu, triggered=lambda: self._do(
            lambda: self.client.torrent_set([self.torrent_id], {"files-wanted": indices}))))
        menu.addAction(QAction("Skip", menu, triggered=lambda: self._do(
            lambda: self.client.torrent_set([self.torrent_id], {"files-unwanted": indices}))))
        menu.exec(self.files.viewport().mapToGlobal(pos))

    def _apply_options(self):
        args = {
            "downloadLimited": self.opt_dl_limited.isChecked(),
            "downloadLimit": self.opt_dl_limit.value(),
            "uploadLimited": self.opt_ul_limited.isChecked(),
            "uploadLimit": self.opt_ul_limit.value(),
            "seedRatioMode": self.opt_ratio_mode.currentIndex(),
            "seedRatioLimit": self.opt_ratio.value(),
            "peer-limit": self.opt_peer_limit.value(),
        }
        self._do(lambda: self.client.torrent_set([self.torrent_id], args))

    def _set_location(self):
        dialog = SetLocationDialog(self._t.get("downloadDir", ""), self)
        if dialog.exec() == QDialog.Accepted and dialog.path.text().strip():
            path = dialog.path.text().strip()
            move = dialog.move_data.isChecked()
            self._do(lambda: self.client.set_location([self.torrent_id], path, move))

    def _copy_magnet(self):
        link = self._t.get("magnetLink", "")
        if link:
            QApplication.clipboard().setText(link)

    def _remove(self):
        box = QMessageBox(QMessageBox.Warning, "Remove torrent",
                          f"Remove “{self.windowTitle()}” from Transmission?",
                          QMessageBox.Yes | QMessageBox.No, self)
        check = QCheckBox("Also delete downloaded data")
        box.setCheckBox(check)
        if box.exec() == QMessageBox.Yes:
            delete = check.isChecked()
            self._do(lambda: self.client.remove([self.torrent_id], delete))
            self.close()
