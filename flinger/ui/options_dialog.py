"""Settings dialog — mirrors the extension's options.html."""
from __future__ import annotations

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
)

from ..core.config import Config
from ..core.transmission import TransmissionClient
from .worker import run_async

POLL_CHOICES = [(1000, "1s"), (3000, "3s"), (10000, "10s"), (30000, "30s")]


class AddDirDialog(QDialog):
    """Small Save/Cancel dialog for adding a custom download directory."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add custom directory")
        self.label_edit = QLineEdit(placeholderText="Optional — defaults to folder name")
        self.dir_edit = QLineEdit(placeholderText="Absolute path on the server, e.g. /data/tv")
        form = QFormLayout()
        form.addRow("Label", self.label_edit)
        form.addRow("Directory", self.dir_edit)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        self._save_btn = buttons.button(QDialogButtonBox.Save)
        self._save_btn.setEnabled(False)
        self.dir_edit.textChanged.connect(
            lambda text: self._save_btn.setEnabled(bool(text.strip())))
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        root = QVBoxLayout(self)
        root.addLayout(form)
        root.addWidget(buttons)
        self.setMinimumWidth(420)
        self.dir_edit.setFocus()


SESSION_KEYS = [
    "speed-limit-down", "speed-limit-down-enabled",
    "speed-limit-up", "speed-limit-up-enabled",
    "alt-speed-down", "alt-speed-up",
    "seedRatioLimit", "seedRatioLimited",
]


class OptionsDialog(QDialog):
    def __init__(self, config: Config, client=None, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Torrent Flinger — Options")
        self.config = config

        # server
        self.protocol = QComboBox()
        self.protocol.addItems(["http", "https"])
        self.protocol.setCurrentText(config.protocol)
        self.host = QLineEdit(config.host)
        self.port = QSpinBox(minimum=1, maximum=65535)
        self.port.setValue(config.port)
        self.rpc_path = QLineEdit(config.rpc_path)
        self.web_path = QLineEdit(config.web_path)
        self.username = QLineEdit(config.username)
        self.password = QLineEdit(config.password, echoMode=QLineEdit.Password)
        self.verify_tls = QCheckBox("Verify TLS certificate")
        self.verify_tls.setChecked(config.verify_tls)

        addr = QHBoxLayout()
        addr.addWidget(self.protocol)
        addr.addWidget(QLabel("://"))
        addr.addWidget(self.host, 1)
        addr.addWidget(QLabel(":"))
        addr.addWidget(self.port)

        self.test_result = QLabel("")
        test_btn = QPushButton("Test Connection")
        test_btn.clicked.connect(self._test)
        test_row = QHBoxLayout()
        test_row.addWidget(test_btn)
        test_row.addWidget(self.test_result, 1)

        server = QGroupBox("Server")
        sf = QFormLayout(server)
        sf.addRow("Address", addr)
        sf.addRow("RPC Path", self.rpc_path)
        sf.addRow("Web Path", self.web_path)
        sf.addRow("Username", self.username)
        sf.addRow("Password", self.password)
        sf.addRow("", self.verify_tls)
        sf.addRow(test_row)

        # general
        self.notify_add = QCheckBox("Desktop notification when adding new torrents")
        self.notify_add.setChecked(config.notify_on_add)
        self.notify_finish = QCheckBox("Desktop notification when a torrent finishes")
        self.notify_finish.setChecked(config.notify_on_finish)
        self.poll = QComboBox()
        for ms, label in POLL_CHOICES:
            self.poll.addItem(label, ms)
        self.poll.setCurrentIndex(max(0, [ms for ms, _ in POLL_CHOICES].index(config.poll_interval_ms)
                                      if config.poll_interval_ms in [ms for ms, _ in POLL_CHOICES] else 1))
        general = QGroupBox("General")
        gf = QFormLayout(general)
        gf.addRow(self.notify_add)
        gf.addRow(self.notify_finish)
        gf.addRow("Popup refresh interval", self.poll)

        # download
        self.start_paused = QCheckBox("Add torrents in paused state")
        self.start_paused.setChecked(config.start_paused)
        self.show_dialog = QCheckBox("Show download popup when adding")
        self.show_dialog.setChecked(config.show_add_dialog)
        self.dirs = QTableWidget(0, 2)
        self.dirs.setHorizontalHeaderLabels(["Label", "Directory"])
        self.dirs.horizontalHeader().setStretchLastSection(True)
        self.dirs.verticalHeader().setVisible(False)
        for entry in config.custom_dirs:
            self._append_dir(entry.get("label", ""), entry.get("dir", ""))
        add_btn = QPushButton("Add…")
        add_btn.clicked.connect(self._add_dir_dialog)
        del_btn = QPushButton("Remove selected")
        del_btn.clicked.connect(self._remove_dir)
        dir_btns = QHBoxLayout()
        dir_btns.addWidget(add_btn)
        dir_btns.addWidget(del_btn)
        dir_btns.addStretch(1)
        download = QGroupBox("Download")
        df = QVBoxLayout(download)
        df.addWidget(self.start_paused)
        df.addWidget(self.show_dialog)
        df.addWidget(QLabel("Custom directories (shown in the download popup):"))
        df.addWidget(self.dirs)
        df.addLayout(dir_btns)

        # local integration: where the server's download share is mounted
        self.mount_remote = QLineEdit(config.mount_remote)
        self.mount_remote.setPlaceholderText(
            "auto: common root of the download dir + custom dirs")
        self.mount_local = QLineEdit(config.mount_local)
        self.mount_local.setPlaceholderText("e.g. /run/media/deck/nas/torrents")
        browse_btn = QPushButton("Browse…")
        browse_btn.clicked.connect(self._browse_mount)
        mount_row = QHBoxLayout()
        mount_row.addWidget(self.mount_local, 1)
        mount_row.addWidget(browse_btn)
        local = QGroupBox("Local integration")
        lof = QFormLayout(local)
        lof.addRow(QLabel("Where the server's downloads are mounted on this "
                          "machine — enables “Reveal in Dolphin”:"))
        lof.addRow("Remote prefix", self.mount_remote)
        lof.addRow("Local folder", mount_row)

        # server-side limits, loaded live via session-get
        self._session_loaded = False
        self.dl_limited = QCheckBox("Limit download speed (KB/s)")
        self.dl_limit = QSpinBox(minimum=1, maximum=10_000_000)
        self.ul_limited = QCheckBox("Limit upload speed (KB/s)")
        self.ul_limit = QSpinBox(minimum=1, maximum=10_000_000)
        self.alt_dl = QSpinBox(minimum=1, maximum=10_000_000)
        self.alt_ul = QSpinBox(minimum=1, maximum=10_000_000)
        self.ratio_limited = QCheckBox("Stop seeding at ratio")
        self.ratio_limit = QDoubleSpinBox(minimum=0.0, maximum=1000.0)
        self.ratio_limit.setSingleStep(0.1)
        self.limits_group = QGroupBox("Server limits (applied on the server)")
        lf = QFormLayout(self.limits_group)
        lf.addRow(self.dl_limited, self.dl_limit)
        lf.addRow(self.ul_limited, self.ul_limit)
        lf.addRow("Turtle download (KB/s)", self.alt_dl)
        lf.addRow("Turtle upload (KB/s)", self.alt_ul)
        lf.addRow(self.ratio_limited, self.ratio_limit)
        self.limits_group.setEnabled(False)
        self.limits_status = QLabel("Loading from server…")
        lf.addRow(self.limits_status)
        if client is not None:
            run_async(lambda: client.session_get(SESSION_KEYS),
                      on_done=self._load_session,
                      on_error=lambda msg: self.limits_status.setText(f"✗ {msg}"))
        else:
            self.limits_status.setText("Not connected")

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        root = QVBoxLayout(self)
        root.addWidget(server)
        root.addWidget(general)
        root.addWidget(download)
        root.addWidget(local)
        root.addWidget(self.limits_group)
        root.addWidget(buttons)
        self.resize(520, 780)

    def _add_dir_dialog(self):
        dialog = AddDirDialog(self)
        if dialog.exec() == QDialog.Accepted:
            directory = dialog.dir_edit.text().strip()
            if directory:
                label = (dialog.label_edit.text().strip()
                         or directory.rstrip("/").rsplit("/", 1)[-1])
                self._append_dir(label, directory)

    def _browse_mount(self):
        from PySide6.QtWidgets import QFileDialog
        path = QFileDialog.getExistingDirectory(
            self, "Local folder where the share is mounted",
            self.mount_local.text() or str(__import__("pathlib").Path.home()))
        if path:
            self.mount_local.setText(path)

    def _load_session(self, args: dict):
        self.dl_limited.setChecked(bool(args.get("speed-limit-down-enabled")))
        self.dl_limit.setValue(int(args.get("speed-limit-down", 100)))
        self.ul_limited.setChecked(bool(args.get("speed-limit-up-enabled")))
        self.ul_limit.setValue(int(args.get("speed-limit-up", 100)))
        self.alt_dl.setValue(int(args.get("alt-speed-down", 50)))
        self.alt_ul.setValue(int(args.get("alt-speed-up", 50)))
        self.ratio_limited.setChecked(bool(args.get("seedRatioLimited")))
        self.ratio_limit.setValue(float(args.get("seedRatioLimit", 2.0)))
        self.limits_group.setEnabled(True)
        self.limits_status.setText("")
        self._session_loaded = True

    def session_args(self) -> dict | None:
        """session-set payload, or None if server values never loaded."""
        if not self._session_loaded:
            return None
        return {
            "speed-limit-down": self.dl_limit.value(),
            "speed-limit-down-enabled": self.dl_limited.isChecked(),
            "speed-limit-up": self.ul_limit.value(),
            "speed-limit-up-enabled": self.ul_limited.isChecked(),
            "alt-speed-down": self.alt_dl.value(),
            "alt-speed-up": self.alt_ul.value(),
            "seedRatioLimit": self.ratio_limit.value(),
            "seedRatioLimited": self.ratio_limited.isChecked(),
        }

    def _append_dir(self, label: str, directory: str):
        row = self.dirs.rowCount()
        self.dirs.insertRow(row)
        self.dirs.setItem(row, 0, QTableWidgetItem(label))
        self.dirs.setItem(row, 1, QTableWidgetItem(directory))

    def _remove_dir(self):
        rows = sorted({i.row() for i in self.dirs.selectedIndexes()}, reverse=True)
        for row in rows:
            self.dirs.removeRow(row)

    def _test(self):
        cfg = self.to_config()
        self.test_result.setText("Testing…")
        client = TransmissionClient.from_config(cfg)
        run_async(
            lambda: client.session_get(["version"]),
            on_done=lambda args: self.test_result.setText(
                f"✓ Connected — Transmission {args.get('version', '?')}"),
            on_error=lambda msg: self.test_result.setText(f"✗ {msg}"),
        )

    def to_config(self) -> Config:
        dirs = []
        for row in range(self.dirs.rowCount()):
            label = (self.dirs.item(row, 0).text() if self.dirs.item(row, 0) else "").strip()
            directory = (self.dirs.item(row, 1).text() if self.dirs.item(row, 1) else "").strip()
            if directory:
                dirs.append({"label": label, "dir": directory})
        return Config(
            protocol=self.protocol.currentText(),
            host=self.host.text().strip(),
            port=self.port.value(),
            rpc_path=self.rpc_path.text().strip() or "/transmission/rpc",
            web_path=self.web_path.text().strip() or "/transmission/web/",
            username=self.username.text(),
            password=self.password.text(),
            verify_tls=self.verify_tls.isChecked(),
            notify_on_add=self.notify_add.isChecked(),
            notify_on_finish=self.notify_finish.isChecked(),
            poll_interval_ms=self.poll.currentData(),
            start_paused=self.start_paused.isChecked(),
            show_add_dialog=self.show_dialog.isChecked(),
            custom_dirs=dirs,
            last_download_dir=self.config.last_download_dir,
            mount_remote=self.mount_remote.text().strip(),
            mount_local=self.mount_local.text().strip(),
        )
