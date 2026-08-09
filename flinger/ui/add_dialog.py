"""'Save in folder' dialog shown when a link arrives — mirrors downloadMagnet.html."""
from __future__ import annotations

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QVBoxLayout,
)

from ..core.config import Config
from ..core.formats import fmt_size
from .style import small_font
from .worker import run_async


class AddDialog(QDialog):
    def __init__(self, config: Config, torrent_name: str, client=None, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add torrent")
        self.config = config
        self.client = client

        name = QLabel(f"<b>{torrent_name}</b>")
        name.setWordWrap(True)

        # Default directory, then the custom dirs (managed in Options)
        self.location = QComboBox()
        self.location.addItem("< Default Directory >", None)
        for entry in config.custom_dirs:
            label = entry.get("label") or entry.get("dir", "")
            self.location.addItem(f"{label} ({entry.get('dir', '')})", entry.get("dir"))
        self.location.currentIndexChanged.connect(lambda _i: self._update_free_space())
        self._server_default_raw = ""
        if config.last_download_dir:
            index = self.location.findData(config.last_download_dir)
            if index >= 1:
                self.location.setCurrentIndex(index)

        self.free_label = QLabel("")
        self.free_label.setFont(small_font())

        self.paused = QCheckBox("Add in paused state")
        self.paused.setChecked(config.start_paused)

        form = QFormLayout()
        form.addRow("Save in folder:", self.location)
        form.addRow("", self.free_label)
        form.addRow(self.paused)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        root = QVBoxLayout(self)
        root.addWidget(name)
        root.addLayout(form)
        root.addWidget(buttons)
        self.setMinimumWidth(420)

    def set_server_default(self, directory: str) -> None:
        """The server's default download dir — used for the free-space readout
        when < Default Directory > is selected."""
        if directory:
            self._server_default_raw = directory
            self._update_free_space()

    def _update_free_space(self):
        """Free space for the selected destination — Tremotesf's add-dialog touch."""
        if self.client is None:
            return
        directory = self.location.currentData() or self._server_default_raw
        if not directory:
            self.free_label.setText("")
            return
        client, label = self.client, self.free_label
        run_async(lambda: client.free_space(directory),
                  on_done=lambda n: label.setText(f"{fmt_size(n)} free" if n >= 0 else ""),
                  on_error=lambda _msg: label.setText(""))

    def result_options(self) -> tuple[str | None, bool]:
        """(download_dir or None for server default, paused)."""
        directory = self.location.currentData()
        if (directory or "") != self.config.last_download_dir:
            self.config.last_download_dir = directory or ""
            self.config.save()
        return directory, self.paused.isChecked()
