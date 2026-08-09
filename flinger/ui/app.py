"""Application hub: tray icon, polling, link handling, notifications."""
from __future__ import annotations

import webbrowser
from pathlib import Path
from urllib.parse import unquote, urlparse

from PySide6.QtCore import QObject, QTimer
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from ..core.config import Config
from ..core.formats import fmt_speed, link_display_name
from ..core.transmission import TransmissionClient, TransmissionError
from .add_dialog import AddDialog
from .options_dialog import OptionsDialog
from .popup import Popup
from .single_instance import InstanceServer
from .stats_dialog import StatsDialog
from .worker import run_async

ASSETS = Path(__file__).resolve().parent.parent / "assets"
HIDDEN_POLL_MS = 30000


class FlingerApp(QObject):
    def __init__(self, qapp: QApplication):
        super().__init__()
        self.qapp = qapp
        self.config = Config.load()
        self.client = TransmissionClient.from_config(self.config)
        self._polling = False
        self._finished_ids: set[int] | None = None  # None until first successful poll

        icon = QIcon(str(ASSETS / "icon128.png"))
        qapp.setWindowIcon(icon)

        self.popup = Popup()
        self.popup.turtle_toggled.connect(self._set_turtle)
        self.popup.pause_clicked.connect(lambda tid: self._action(lambda: self.client.stop([tid])))
        self.popup.resume_clicked.connect(lambda tid: self._action(lambda: self.client.start([tid])))
        self.popup.remove_clicked.connect(
            lambda tid, data: self._action(lambda: self.client.remove([tid], data)))
        self.popup.details_requested.connect(self._open_details)
        self.popup.add_link.connect(self.handle_link)
        self.popup.add_file_requested.connect(self.add_torrent_file)
        self.popup.open_web_requested.connect(lambda: webbrowser.open(self.config.web_url))
        self.popup.settings_requested.connect(self._show_options)
        self.popup.stats_requested.connect(self._show_stats)
        self.popup.notify.connect(
            lambda title, body: self.tray.showMessage(
                title, body, QSystemTrayIcon.Information, 3000))
        self._details: dict[int, object] = {}

        self.tray = QSystemTrayIcon(icon)
        self.tray.setToolTip("Torrent Flinger")
        self.tray.activated.connect(self._on_tray_activated)
        menu = QMenu()
        menu.addAction(QAction("Show torrents", menu, triggered=self._show_popup))
        menu.addSeparator()
        menu.addAction(QAction("Add torrent file…", menu, triggered=self.add_torrent_file))
        menu.addAction(QAction("Add magnet from clipboard", menu,
                               triggered=self.add_magnet_from_clipboard))
        menu.addSeparator()
        menu.addAction(QAction("Start all", menu, triggered=lambda: self._action(self.client.start)))
        menu.addAction(QAction("Pause all", menu, triggered=lambda: self._action(self.client.stop)))
        menu.addSeparator()
        menu.addAction(QAction("Statistics…", menu, triggered=self._show_stats))
        menu.addAction(QAction("Full web interface", menu,
                               triggered=lambda: webbrowser.open(self.config.web_url)))
        menu.addAction(QAction("Options…", menu, triggered=self._show_options))
        menu.addSeparator()
        menu.addAction(QAction("Quit", menu, triggered=qapp.quit))
        self.tray.setContextMenu(menu)
        self.tray.show()

        self.instance_server = InstanceServer(self)
        self.instance_server.link_received.connect(self.handle_link)
        self.instance_server.show_requested.connect(self._show_popup)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._poll)
        self.timer.start(HIDDEN_POLL_MS)
        self.popup.installEventFilter(self)
        self._poll()

    # -- polling ------------------------------------------------------------

    def eventFilter(self, obj, event):
        if obj is self.popup and event.type() in (event.Type.Show, event.Type.Hide):
            visible = event.type() == event.Type.Show
            self.timer.start(self.config.poll_interval_ms if visible else HIDDEN_POLL_MS)
            if visible:
                self._poll()
        return super().eventFilter(obj, event)

    def _poll(self):
        if self._polling:
            return
        self._polling = True
        client = self.client

        def fetch():
            session = client.session_get(["alt-speed-enabled", "download-dir"])
            free = -1
            if session.get("download-dir"):
                try:
                    free = client.free_space(session["download-dir"])
                except TransmissionError:
                    pass  # free space is decoration; never fail the poll over it
            return {
                "torrents": client.torrents(),
                "stats": client.session_stats(),
                "session": session,
                "free_space": free,
            }

        run_async(fetch, on_done=self._on_poll_done, on_error=self._on_poll_error)

    def _on_poll_done(self, data):
        self._polling = False
        torrents = data["torrents"]
        stats = data["stats"]
        turtle = bool(data["session"].get("alt-speed-enabled"))
        self.popup.set_data(torrents, stats, turtle,
                            free_space=data.get("free_space", -1),
                            server=self.config.host)
        self.tray.setToolTip(
            f"Torrent Flinger — {len(torrents)} torrents\n"
            f"DL: {fmt_speed(stats.get('downloadSpeed', 0))}  "
            f"UL: {fmt_speed(stats.get('uploadSpeed', 0))}")

        finished = {t["id"] for t in torrents if t.get("percentDone", 0) >= 1}
        if self._finished_ids is not None and self.config.notify_on_finish:
            for t in torrents:
                if t["id"] in finished and t["id"] not in self._finished_ids:
                    self.tray.showMessage("Download complete", t["name"],
                                          QSystemTrayIcon.Information, 5000)
        self._finished_ids = finished

    def _on_poll_error(self, message):
        self._polling = False
        self.popup.set_error(f"Can't reach {self.config.host} — {message}")
        self.tray.setToolTip(f"Torrent Flinger — connection failed:\n{message}")

    def _action(self, fn):
        run_async(fn, on_done=lambda _: self._poll(),
                  on_error=lambda msg: self.tray.showMessage(
                      "Transmission error", msg, QSystemTrayIcon.Warning, 4000))

    def _set_turtle(self, enabled):
        self._action(lambda: self.client.set_turtle(enabled))

    # -- links --------------------------------------------------------------

    def handle_link(self, link: str) -> None:
        link = link.strip()
        if link.startswith("file://"):
            link = unquote(urlparse(link).path)
        if not link:
            return
        name = link_display_name(link)

        if self.config.show_add_dialog:
            dialog = AddDialog(self.config, name, self.client)
            dialog.setWindowIcon(self.qapp.windowIcon())
            client = self.client
            run_async(lambda: client.session_get(["download-dir"]),
                      on_done=lambda args: dialog.set_server_default(
                          args.get("download-dir", "")))
            if dialog.exec() != AddDialog.Accepted:
                return
            download_dir, paused = dialog.result_options()
        else:
            download_dir, paused = None, self.config.start_paused

        def add():
            return self.client.add(link, download_dir, paused)

        def on_done(result):
            status, info = result
            if self.config.notify_on_add:
                title = "Torrent added" if status == "added" else "Already in Transmission"
                self.tray.showMessage(title, info.get("name", name),
                                      QSystemTrayIcon.Information, 4000)
            self._poll()

        run_async(add, on_done=on_done,
                  on_error=lambda msg: self.tray.showMessage(
                      "Failed to add torrent", f"{name}\n{msg}",
                      QSystemTrayIcon.Warning, 6000))

    # -- windows ------------------------------------------------------------

    def _on_tray_activated(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.MiddleClick):
            self._show_popup()

    def _show_popup(self):
        geo = self.tray.geometry()  # valid on X11/XWayland; empty under pure Wayland
        self.popup.toggle_near(geo if geo.isValid() and not geo.isEmpty() else None)

    def _show_options(self):
        dialog = OptionsDialog(self.config, self.client)
        if dialog.exec() == OptionsDialog.Accepted:
            self.config = dialog.to_config()
            self.config.save()
            self.client = TransmissionClient.from_config(self.config)
            session_args = dialog.session_args()
            if session_args:
                self._action(lambda: self.client.session_set(session_args))
            self._finished_ids = None
            self._poll()

    def _show_stats(self):
        StatsDialog(self.client).exec()

    def _open_details(self, torrent_id: int):
        existing = self._details.get(torrent_id)
        if existing is not None:
            try:
                existing.raise_()
                existing.activateWindow()
                return
            except RuntimeError:
                pass  # closed and deleted
        from .details_dialog import DetailsDialog
        row = self.popup._rows.get(torrent_id)
        name = row._t.get("name", "Torrent") if row else "Torrent"
        dialog = DetailsDialog(self.client, torrent_id, name)
        dialog.destroyed.connect(lambda: self._details.pop(torrent_id, None))
        self._details[torrent_id] = dialog
        dialog.show()

    def add_torrent_file(self):
        from PySide6.QtWidgets import QFileDialog
        path, _ = QFileDialog.getOpenFileName(
            None, "Add torrent", "", "Torrent files (*.torrent);;All files (*)")
        if path:
            self.handle_link(path)

    def add_magnet_from_clipboard(self):
        text = QApplication.clipboard().text().strip()
        if text.startswith("magnet:"):
            self.handle_link(text)
        else:
            self.tray.showMessage("No magnet link",
                                  "The clipboard doesn't contain a magnet: link.",
                                  QSystemTrayIcon.Warning, 3000)
