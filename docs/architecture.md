# Architecture

## What this project is

A **client** for a Transmission daemon that runs somewhere else — a NAS, a home
server, a seedbox. It stores nothing, downloads nothing, and has no state of
its own beyond a config file. Everything it shows is a rendering of
`torrent-get`, and everything it does is an RPC call.

That single fact explains most of the design. There is no database, no sync, no
migration, no cache invalidation — because the server is the model and the app
is a view. When you're tempted to add local state, that's the constraint to
weigh it against.

The second purpose is link handling: register as the system's `magnet:` and
`.torrent` handler so a click in any browser reaches the server, without a
browser extension.

## Two apps, one server

```
                     ┌──────────────────────────────┐
                     │  Transmission daemon         │
                     │  (NAS / server / seedbox)    │
                     └──────────────┬───────────────┘
                                    │ JSON-RPC over HTTP
                    ┌───────────────┴────────────────┐
                    │                                │
        ┌───────────┴────────────┐      ┌────────────┴───────────┐
        │  linux/    (Linux)     │      │  macos/   (macOS)      │
        │  Python 3 + PySide6    │      │  Swift + SwiftUI       │
        │  system tray + popup   │      │  menu bar + panel      │
        └───────────┬────────────┘      └────────────┬───────────┘
                    │                                │
                    └──────────────┬─────────────────┘
                                   │
                    ~/.config/torrent-flinger/config.json      (Linux)
                    ~/Library/Application Support/…/config.json (macOS)
```

Same feature set, same server, same config file. Different shells, because a
Qt app on macOS is a bad macOS app and a SwiftUI app on Linux doesn't exist.

## The one decision worth defending: ported, not shared

`linux/flinger/core/` (Python) and `macos/Sources/TorrentFlinger/Core/` (Swift) are
the same five modules — RPC client, config, formatting, TV detection, tray icon
selection — implemented twice, deliberately.

The alternative was one implementation with a bridge: PythonKit, or a C
library, or a local service both talk to. Each buys shared logic at the cost of
a runtime dependency in the macOS app, a build-time coupling between the two
targets, and a class of bug (marshalling, version skew, "which Python?") that
neither app has today.

What's actually shared is small, stable and specified: a wire protocol that
Transmission versions, a config file format, and about 400 lines of pure
formatting rules that change roughly never. Duplicating that is cheap. The
duplication is held honest by tests: `linux/tests/test_core.py` and the Swift
`SelfTest/` suite assert the same rules, and a change on one side that isn't
mirrored shows up as a failing test on the other.

The cost is real and should be stated plainly: a formatting change is two
commits' worth of work, and drift is possible in the window between them. That
trade was taken so the macOS app could ship as a single self-contained
`.app` with no runtime beyond the OS.

The one thing genuinely shared as a *file* is the tray artwork:
`linux/flinger/assets/tray-{idle,downloading,error,added}.svg`, copied into the macOS
bundle by `build-app.sh` and tinted at runtime by `linux/flinger/ui/style.py`. One
monochrome set, two consumers.

## How a click becomes an RPC call

Both apps have the same four layers; only the names differ.

| Layer | Linux | macOS |
|---|---|---|
| Transport | `linux/flinger/core/transmission.py` (`urllib`, blocking) | `Core/TransmissionClient.swift` (`URLSession`, `actor`) |
| Off-thread | `linux/flinger/ui/worker.py` (`QThreadPool`) | `async`/`await` |
| State hub | `linux/flinger/ui/app.py` (`FlingerApp`) | `TorrentStore.swift` (`@MainActor`, `ObservableObject`) |
| Views | `popup.py`, `torrent_row.py`, dialogs | `PopoverView`, `TorrentRowView`, windows |

The hub owns the poll timer, the config, the client, and every mutating action.
Views raise intent (a signal on Linux, a method call on macOS); the hub performs
the RPC off the main thread and re-polls on success, so the UI only ever renders
server truth rather than optimistically guessing.

**Polling cadence** is the same on both: the configured interval (default 3 s)
while the panel is open, 30 s while it's closed. The macOS build adds a third
timer — `session-stats` alone every 2.5 s while a transfer is running and the
panel is closed — to feed the menu bar's moving average. See
[macos.md](macos.md#speed-smoothing).

## Where the two builds genuinely differ

Not stylistic differences — places where the platform forced a different design.

| Concern | Linux | macOS |
|---|---|---|
| Status surface | `QSystemTrayIcon`: icon, tooltip, menu, nothing else | `NSStatusItem`: icon **and text**, hence the speed readout and its smoothing |
| Panel | `QWidget` tool window anchored to the tray geometry | borderless `NSPanel` (an `NSPopover` mis-places its anchor rect) |
| Second instance | `QLocalServer` socket; the second process forwards its links and exits | POSIX `flock`, plus re-opening links against our own bundle so LaunchServices routes them to the lock holder |
| Display server | Forced onto XWayland (`QT_QPA_PLATFORM=xcb;wayland`) because Wayland toplevels can't position themselves and never get activation | n/a |
| Theming | Qt palette-derived stylesheet, re-tinted per poll so a Breeze light/dark switch is picked up | AppKit template images and semantic colours adapt on their own |
| Network permission | none | Local Network grant is load-bearing and non-obvious — see [`macos/CLAUDE.md`](../macos/CLAUDE.md) |

## Failure model

The server is remote, on a LAN, often asleep. Every layer assumes it can vanish:

- **Decode leniently.** Transmission 3.x, 4.x and reimplementations disagree
  about which fields they emit. Every field decodes to a documented default
  rather than throwing, so one unknown key can't blank the list.
- **Decoration never fails the poll.** `free-space` is wrapped separately: if it
  errors, free space shows as unknown and the torrent list still renders.
- **Errors are one line in the UI and the whole story in the log**, and only
  logged on change — an unreachable server polls forever, and a line every 30 s
  buries everything else.
- **Mutations re-poll rather than assume.** A pause that the server rejected
  must not leave a paused-looking row.
