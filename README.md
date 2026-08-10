# Torrent Flinger

A native-feeling system-tray **viewer and administrator for a remote
Transmission server**, plus a browser-free way to fling magnet links and
`.torrent` files at it. Click a magnet link in **any** browser and it goes
straight to your server — no browser extension, no extension signing.

The tray popup is styled after KDE Plasma's own applets (the wifi-picker
anatomy: header strip, search, grouped list, footer) with all colors drawn
from the system palette, so Breeze light/dark both look right. Rows expand in
place — Plasma's `ExpandableListItem` interaction — and a full details window
covers per-torrent administration.

## What it does

**Tray popup** (styled like plasma-nm, 432px):
- Header: turtle-mode toggle, debounce-free search (`Ctrl+F`), add-torrent menu
- Torrents grouped by status (Error first, then Downloading / Verifying /
  Seeding / Paused / Finished) with per-group counts — no filter chrome
- Compact rows: state icon, name, `↓/↑ speed · % · ETA` subtitle, slim
  state-colored progress bar, one-click Pause/Resume
- Click a row to expand in place (animated, 100 ms): quick stats grid +
  Details / Copy magnet / Remove actions
- Clipboard magnet detection: open the popup with a magnet link copied and it
  offers to add it (Fragments' trick)
- Footer: aggregate speeds, torrent count, **free disk space on the server**,
  and stats / web-UI / settings buttons

**Details window** per torrent (transmission-qt/Tremotesf feature set):
- Info: sizes, ratio, dates, hash, pieces, privacy, error
- Files: per-file download checkbox + high/normal/low priority (right-click,
  multi-select)
- Peers: address, client, flags, progress, rates (sortable)
- Trackers: seeders/leechers, last/next announce, failure highlighting
- Options: per-torrent speed limits, seed-ratio mode, peer limit, queue moves
- Actions: pause/resume, verify, reannounce, set location (with/without moving
  data), copy magnet, remove (with optional data deletion)

**Server administration**: global + turtle speed limits and default seed ratio
(edited live via `session-set`), session statistics dialog (current +
cumulative), start/pause all, port-ready RPC client for more (`port-test`,
`queue-move-*`, `free-space` are all implemented and tested).

**Link handling**: `x-scheme-handler/magnet` + `application/x-bittorrent`
registration; a second invocation forwards the link to the running instance
over a local socket and exits. The add dialog offers your custom directories
(with labels), remembers the last destination, shows **free space for the
selected directory**, and pre-fills new paths with the server's default.

## Install

### Flatpak (recommended — this is the deployment target)

```bash
./scripts/build-flatpak.sh     # user-level; no root; installs from local build
flatpak run io.github.python2121.TorrentFlinger
```

The exported `.desktop` registers the magnet/.torrent handler automatically for
host browsers. Sandbox permissions are minimal: network + tray + notifications.
Works on SteamOS's immutable filesystem; if building *inside* a distrobox
fails (nested sandboxing), run the same script on the host — the repo is in
shared `$HOME`.

### Dev mode (venv, everything inside this folder)

```bash
./scripts/setup.sh              # .venv + PySide6, nothing system-wide
./bin/torrent-flinger           # run the tray app
./scripts/install-linux.sh      # register magnet/.torrent handler (dev paths)
```

Inside a distrobox, `bin/torrent-flinger` re-enters the box automatically when
invoked from the host (box name recorded in `.distrobox-name`).

First run: right-click tray icon → **Options…** → set server → Test Connection.

## Development

```
flinger/core/     RPC client, config, formats — pure stdlib, no Qt.
                  Ported (not shared) by the Swift build in macos/.
flinger/ui/       PySide6: popup, expandable rows, details window, dialogs,
                  palette-derived theming (style.py), thread-pool workers,
                  single-instance socket
packaging/flatpak Flatpak manifest (KDE runtime + PySide BaseApp), metainfo
tests/            29 tests: mock Transmission RPC server (with the protocol's
                  case-sensitivity quirks encoded), offscreen UI tests,
                  full-app integration test
macos/            the macOS build — a self-contained Swift package with its
                  own README, tests and build scripts (see below)
```

```bash
PYTHONPATH=. .venv/bin/python -m unittest discover tests   # run tests
.venv/bin/ruff check flinger tests                          # lint
```

The RPC client targets the pre-4.1 protocol (works with Transmission 3.x and
4.x). Field-name gotchas are documented in `tests/test_core.py`'s mock.

## macOS

The macOS build is a **separate, native Swift/SwiftUI app** in
[`macos/`](macos/README.md) — a menu-bar accessory with the same feature set,
rather than this app running under Qt. The two are independent: nothing in
`macos/` affects the Linux app, and they can coexist in this repo.

```bash
cd macos && ./install.sh
```

They do share one thing on purpose:
`~/Library/Application Support/torrent-flinger/config.json` uses the same keys
in both, so the file is interchangeable. `tests/test_core.py` is the shared
reference for core behavior — formatting, path mapping and TV detection are
asserted the same way on both sides, so a rule change should land in both.

## Credits

UI layout and feature set researched from: Transmission Remote Plus (the
Chrome extension in `chrome-transmission-remote-plus-master/`, Apache-2.0 —
icons reused from it), Tremotesf, transmission-remote-gtk, transgui,
Fragments, Transmissionic, and Transmission's own Qt/web clients. Popup
design follows KDE's plasma-nm applet and HIG measurements.
