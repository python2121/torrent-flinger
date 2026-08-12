# The Linux build (`linux/flinger/`)

Python 3 + PySide6. A `QSystemTrayIcon` with a popup styled to pass for a KDE
Plasma applet. Deployment target is Flatpak; a venv dev mode exists alongside.

Everything below is relative to `linux/`, which is self-contained: the venv,
the package, its tests and its packaging all live there.

> **Upgrading from before the `linux/` move?** `install-linux.sh` writes
> absolute paths into `~/.local/share/applications/torrent-flinger.desktop`, so
> the installed magnet handler still points at the old location. Re-run
> `./scripts/install-linux.sh` (and `./scripts/build-flatpak.sh` if you use the
> Flatpak) once, and it's fixed.

```bash
cd linux
./scripts/setup.sh          # .venv + PySide6, nothing system-wide
./bin/torrent-flinger       # run it
./scripts/install-linux.sh  # register the magnet/.torrent handler (dev paths)
./scripts/build-flatpak.sh  # the real deployment path
PYTHONPATH=. .venv/bin/python -m unittest discover tests
.venv/bin/ruff check flinger tests
```

## Entry point

**`flinger/__main__.py`** — argument parsing and one platform decision worth
knowing about: on Linux under Wayland it forces `QT_QPA_PLATFORM=xcb;wayland`
(XWayland) unless you've set it yourself. Wayland toplevels can't position
themselves, so the popup would land wherever the compositor decides (KWin:
screen centre), and Tool windows never receive activation, so click-outside
dismissal breaks. X11 windows anchor to the tray like a real applet.

It then tries `try_forward(links)` first: if a tray instance is already running,
the links go over a local socket and this process exits 0 without starting Qt.
`--smoke-test` runs the whole app for three seconds and quits, which is what the
integration test drives.

## `linux/flinger/core/` — no Qt, ported to Swift

Pure stdlib. Every module here has a Swift counterpart under
`macos/Sources/TorrentFlinger/Core/` implementing the same rules; see
[architecture.md](architecture.md#the-one-decision-worth-defending-ported-not-shared).

| File | Contents |
|---|---|
| `transmission.py` | The RPC client. Blocking `urllib`, 409 handshake, Basic auth, opt-out TLS verification, `TORRENT_FIELDS`/`DETAIL_FIELDS`, `TransmissionError`/`ConnectionFailed`/`AuthFailed`. See [rpc.md](rpc.md). |
| `config.py` | The `Config` dataclass, platform config paths, lenient load, 0600 save. See [config.md](config.md). |
| `formats.py` | `fmt_size`, `fmt_speed` (SI, 1000-based), `fmt_eta`, `status_name`, `fmt_date`, `map_remote_path`, `common_remote_root`, `resolve_local_path`, `link_display_name`. |
| `tvdetect.py` | `looks_like_tv(name)` → `(bool, reason)` on `S01E02`, `1x02`, air dates and season packs; `find_tv_dir(custom_dirs)` returns the first directory flagged `tv`. |
| `trayicon.py` | `tray_icon(connected, download_speed, recently_added)` → one of four state names, and `ADDED_DURATION_S = 3.0`. The precedence rule is duplicated in Swift with a test on both sides asserting the same 3 s. |
| `polling.py` | `poll_interval_ms(configured, visible, active, slow_when_idle)` and `any_active(torrents)` — the popup's refresh cadence, including the 10 s idle back-off. The one module here with **no** Swift counterpart: macOS has no idle slow-down, so there's no shared rule to keep in step. |
| `filetree.py` | `build_tree(files, fileStats)` folds Transmission's flat path list into a directory tree, aggregating size, progress, wanted (tri-state) and priority; `indices_for(ids, tree)` resolves selected rows back to file indices. Pure, so it's tested without a server. Ported from `FileTree.swift` — same ids, same ordering. |

## `linux/flinger/ui/` — PySide6

### `app.py` — `FlingerApp`, the hub

Owns the tray icon, its context menu, the poll timer, the config, the client,
and every action. Roughly the counterpart of `TorrentStore` + `AppDelegate` on
macOS.

- **Polling**: `QTimer` at `poll_interval_ms` while the popup is visible,
  `HIDDEN_POLL_MS` (30 s) while it isn't. The switch is driven by an event
  filter on the popup's Show/Hide, not by a signal. `_polling` guards
  reentrancy. One poll fetches `session-get(["download-dir"])` → `free-space` →
  `torrents` → `session-stats`, all on a worker thread, and `free-space`
  failures are swallowed so decoration can't fail the poll.
- **Path mapping** is resolved per poll: explicit `mount_remote`, else the
  common root of the server's download dir and every custom dir.
- **Finish notifications**: `_finished_ids` is `None` until the first successful
  poll, so launching doesn't announce the entire back catalogue.
- **Tray icon**: re-tinted from the palette on state change only, so a Breeze
  light/dark switch is picked up within one poll without repainting constantly.
  If `QtSvg` is missing, `tray_pixmap` returns null and the raster icon stays —
  a silent, deliberate fallback.
- **`_flash_added`**: shows the "+" for `ADDED_DURATION_S`; a second add
  restarts the clock rather than stacking timers, so a batch of dropped files
  reads as one continuous "+".
- **`handle_link`**: normalises `file://`, optionally opens the add dialog,
  adds, notifies, flashes, re-polls. A duplicate is reported as a duplicate.
- Details and Options windows are non-modal and de-duplicated by keeping a
  reference (`_details[id]`, `_options_dialog`) and raising the existing one.

### `popup.py` — `Popup`

The plasma-nm anatomy: header strip (title + search + add), grouped scrolling
list, footer (aggregate speeds, count, server free space, and the stats /
web-UI / settings buttons). `GROUP_ORDER` fixes the section order — Error,
Downloading, Verifying, Seeding, Paused, Finished — and is the same order as the
Swift `Torrent.grouped`.

Also owns: live search filtering, keyboard navigation and range selection, the
row context menu (`_build_context_menu`: Resume only when something selected is
stopped and Pause only when something is running, then — on a single row —
Reveal in Dolphin, Torrent files… and Details…, where the first of those two
emits `files_requested` so `FlingerApp` opens the details dialog on its Files
tab; verify, reannounce and copy magnet are the details dialog's job),
click-outside dismissal (via focus-window change), and Escape layering —
selection first, then the search, then the window.

### `torrent_row.py` — `TorrentRow`

Plasma's `ExpandableListItem` reproduced: 44 px header with state icon, name,
`↓/↑ speed · % · ETA` subtitle and a slim state-coloured progress bar; click to
expand into a details grid plus flat actions. Hover is Highlight at 30 % alpha
over 50 ms; expansion animates 100 ms InOutCubic. `update_torrent` diffs into
the existing widgets rather than rebuilding, so a 3 s poll doesn't flicker.

### `style.py`

Everything derives from the active `QPalette`, so Breeze light/dark follow
automatically. Two things to know: QSS `palette(role)` can't carry alpha, so
translucent colours are injected as hex-ARGB strings and the stylesheet is
rebuilt on palette change; and the numbers follow Kirigami units (spacing 4/8,
radius 5, icon 32, animation 50/100 ms) so it sits correctly among real applets.
`tray_pixmap` tints the shared monochrome SVG at runtime — the macOS side gets
the same asset for free via AppKit template images.

### Dialogs

| File | Window |
|---|---|
| `add_dialog.py` | Destination picker on a new link: custom dirs with labels, remembered last choice, free space for the selected directory, TV auto-suggestion, "add paused". |
| `details_dialog.py` | Per-torrent admin: Info / Files / Peers / Trackers / Options tabs, refreshing every `REFRESH_MS` (3 s). Files is a collapsible tree built by `core/filetree.py`, with a tri-state checkbox and aggregates on folder rows. File priorities map to `priority-high/normal/low`; actions include verify, reannounce, set location, remove. Every column on Files/Peers/Trackers is drag-resizable — `_ColumnFitter` grows one column into the slack until the user drags a divider, because Qt's `Stretch` mode fills the view but nails the section in place. |
| `options_dialog.py` | Settings, mirroring the Chrome extension's `options.html`: server, general (notifications, the `POLL_CHOICES` refresh interval and the idle back-off), download, local paths, and the Limits tab that writes global limits/turtle mode/seed ratio through `session-set`. |
| `stats_dialog.py` | Session vs cumulative totals. |

### Plumbing

- **`worker.py`** — `run_async(fn, on_done, on_error)` over `QThreadPool`.
  Workers are held in a module-level `_live` set until their queued signals are
  delivered (`setAutoDelete(False)`), and emitting into destroyed Qt objects is
  caught, because the app can quit mid-request.
- **`single_instance.py`** — `QLocalServer`/`QLocalSocket` named per user. The
  `.desktop` handler launches the same program with the link as an argument;
  `try_forward` hands it to the running instance and exits.

## Packaging

`linux/packaging/flatpak` holds the manifest (KDE runtime + PySide BaseApp) and the
metainfo. The exported `.desktop` registers `x-scheme-handler/magnet` and
`application/x-bittorrent` so host browsers route links in. Sandbox permissions
are deliberately minimal: network, tray, notifications.
