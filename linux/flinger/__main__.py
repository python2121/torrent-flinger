"""Entry point.

    python -m flinger                    start the tray app (or raise the running one)
    python -m flinger <magnet-or-file>   add a torrent (forwards to a running instance)
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    # Wayland toplevels cannot position themselves, so the tray popup would
    # appear wherever the compositor drops it (KWin: screen center), and Tool
    # windows never receive activation so click-outside dismissal breaks.
    # Run via XWayland instead — X11 windows anchor to the tray like Plasma
    # applets. Overridable by setting QT_QPA_PLATFORM yourself.
    if (sys.platform.startswith("linux")
            and "QT_QPA_PLATFORM" not in os.environ
            and os.environ.get("WAYLAND_DISPLAY")):
        os.environ["QT_QPA_PLATFORM"] = "xcb;wayland"

    args = sys.argv[1:]
    links = [a for a in args if not a.startswith("--")]
    smoke = "--smoke-test" in args

    from .ui.single_instance import try_forward
    if not smoke and try_forward(links):
        return 0

    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication

    from .ui.app import FlingerApp

    qapp = QApplication(sys.argv)
    qapp.setApplicationName("Torrent Flinger")
    qapp.setQuitOnLastWindowClosed(False)

    app = FlingerApp(qapp)
    for link in links:
        QTimer.singleShot(0, lambda l=link: app.handle_link(l))
    if smoke:
        QTimer.singleShot(3000, qapp.quit)
    return qapp.exec()


if __name__ == "__main__":
    raise SystemExit(main())
