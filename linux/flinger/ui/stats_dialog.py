"""Session statistics dialog: current session vs cumulative totals."""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QGridLayout,
    QLabel,
    QVBoxLayout,
)

from ..core.formats import fmt_eta, fmt_size
from .worker import run_async

ROWS = ["Downloaded", "Uploaded", "Ratio", "Files added", "Active time", "Sessions"]


def _stat_lines(block: dict) -> list[str]:
    down = block.get("downloadedBytes", 0)
    up = block.get("uploadedBytes", 0)
    ratio = f"{up / down:.2f}" if down else "—"
    return [fmt_size(down), fmt_size(up), ratio,
            str(block.get("filesAdded", 0)),
            fmt_eta(block.get("secondsActive", 0)) or "0s",
            str(block.get("sessionCount", 0))]


class StatsDialog(QDialog):
    def __init__(self, client, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Transmission Statistics")
        grid = QGridLayout()
        grid.setHorizontalSpacing(24)
        for col, title in enumerate(("", "This session", "Total")):
            label = QLabel(f"<b>{title}</b>")
            grid.addWidget(label, 0, col)
        self._cells: list[list[QLabel]] = []
        for i, name in enumerate(ROWS):
            grid.addWidget(QLabel(name), i + 1, 0)
            row = []
            for col in (1, 2):
                cell = QLabel("…")
                cell.setAlignment(Qt.AlignRight)
                grid.addWidget(cell, i + 1, col)
                row.append(cell)
            self._cells.append(row)

        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self.accept)

        root = QVBoxLayout(self)
        root.addLayout(grid)
        root.addWidget(buttons)

        run_async(client.session_stats, on_done=self._populate,
                  on_error=lambda msg: self._cells[0][0].setText(msg))

    def _populate(self, stats: dict):
        for col, key in enumerate(("current-stats", "cumulative-stats")):
            for i, text in enumerate(_stat_lines(stats.get(key, {}))):
                self._cells[i][col].setText(text)
