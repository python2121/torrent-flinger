"""'Save in folder' dialog shown when a link arrives — mirrors downloadMagnet.html."""
from __future__ import annotations

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
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

        # Same ordering as the extension: Default, New Directory…, then customs
        self.location = QComboBox()
        self.location.addItem("< Default Directory >", None)
        self.location.addItem("< New Directory… >", "__new__")
        for entry in config.custom_dirs:
            label = entry.get("label") or entry.get("dir", "")
            self.location.addItem(f"{label} ({entry.get('dir', '')})", entry.get("dir"))
        self.location.currentIndexChanged.connect(self._on_location_changed)
        self._server_default = ""
        self._server_default_raw = ""
        if config.last_download_dir:
            index = self.location.findData(config.last_download_dir)
            if index > 1:  # only custom dirs; never preselect "New Directory…"
                self.location.setCurrentIndex(index)

        self.free_label = QLabel("")
        self.free_label.setFont(small_font())

        self.new_dir = QLineEdit(placeholderText="Directory (absolute path on the server)")
        self.new_label = QLineEdit(placeholderText="Optional label")
        self.remember = QCheckBox("Add to custom locations")
        for w in (self.new_dir, self.new_label, self.remember):
            w.setVisible(False)

        self.paused = QCheckBox("Add in paused state")
        self.paused.setChecked(config.start_paused)

        form = QFormLayout()
        form.addRow("Save in folder:", self.location)
        form.addRow("", self.free_label)
        form.addRow(self.new_dir)
        form.addRow(self.new_label)
        form.addRow(self.remember)
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
        """Prefill 'New Directory' with the server's default download dir,
        trailing slash added — same nicety as the extension."""
        if directory:
            self._server_default_raw = directory
            self._server_default = directory.rstrip("/") + "/"
            if self.location.currentData() == "__new__" and not self.new_dir.text():
                self.new_dir.setText(self._server_default)
            self._update_free_space()

    def _on_location_changed(self, _index):
        is_new = self.location.currentData() == "__new__"
        for w in (self.new_dir, self.new_label, self.remember):
            w.setVisible(is_new)
        if is_new:
            if not self.new_dir.text() and self._server_default:
                self.new_dir.setText(self._server_default)
            self.new_dir.setFocus()
        self._update_free_space()

    def _update_free_space(self):
        """Free space for the selected destination — Tremotesf's add-dialog touch."""
        if self.client is None:
            return
        directory = self.location.currentData()
        if directory in (None, "__new__"):
            directory = self._server_default_raw
        if not directory:
            self.free_label.setText("")
            return
        client, label = self.client, self.free_label
        run_async(lambda: client.free_space(directory),
                  on_done=lambda n: label.setText(f"{fmt_size(n)} free" if n >= 0 else ""),
                  on_error=lambda _msg: label.setText(""))

    def result_options(self) -> tuple[str | None, bool]:
        """(download_dir or None for server default, paused). Persists a new
        custom location if the user asked for it."""
        data = self.location.currentData()
        if data == "__new__":
            directory = self.new_dir.text().strip() or None
            if directory and self.remember.isChecked():
                # no label given → use the directory's basename, like the extension
                label = (self.new_label.text().strip()
                         or directory.rstrip("/").rsplit("/", 1)[-1])
                self.config.custom_dirs.append({"label": label, "dir": directory})
                self.config.save()
        else:
            directory = data
        if (directory or "") != self.config.last_download_dir:
            self.config.last_download_dir = directory or ""
            self.config.save()
        return directory, self.paused.isChecked()
