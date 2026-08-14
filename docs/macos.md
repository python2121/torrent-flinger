# The macOS build (`macos/`)

A single-target Swift Package menu-bar app: SwiftUI inside AppKit chrome, no
dependencies beyond the OS. Same feature set as the Linux build, rehoused.

Two documents already cover part of this ground and are the ones to keep
current:

- [`macos/CLAUDE.md`](../macos/CLAUDE.md) — build/run/test commands and the
  gotchas that cost real time (Local Network permission, the zsh `log` builtin,
  `pkill` matching, why offscreen snapshots don't work).
- [`macos/FEATURE_MAP.md`](../macos/FEATURE_MAP.md) — the feature-by-feature
  catalogue.

This page is the structural map: what each file is for, and the handful of
decisions you'd otherwise have to reverse-engineer.

```bash
cd macos
swift build                 # compile
swift run TorrentFlinger    # dev loop (no bundle: no magnet handling, no notifications)
./test.sh                   # the self-test suite
./build-app.sh              # release build → TorrentFlinger.app
./install.sh                # build, replace /Applications copy, restart
```

## Layout

```
Sources/TorrentFlinger/
  App.swift              entry point: self-test, single instance, link replay
  AppDelegate.swift      status item, panel, menus, the four aux windows
  TorrentStore.swift     the single source of truth
  PopoverView.swift      the panel's SwiftUI content
  TorrentRowView.swift   one row, expandable
  DetailsWindow.swift    per-torrent admin (Info/Files/Peers/Trackers/Options)
  OptionsWindow.swift    settings
  AddTorrentWindow.swift destination picker
  StatsWindow.swift      session vs cumulative
  HostedWindow.swift     shared chrome for the four windows above
  Dialogs.swift          NSAlert/NSOpenPanel helpers
  Notifier.swift         user notifications (bundle-gated)
  LocalNetwork.swift     the Bonjour browse that unlocks LAN access
  SingleInstance.swift   POSIX flock
  StateColor.swift       state → colour
  Log.swift              os.Logger wrapper
  Core/                  AppKit-free, ported from flinger/core/
  SelfTest/              the whole test suite + debug tooling (#if DEBUG)
```

## `Core/` — the ported layer

| File | Notes |
|---|---|
| `TransmissionClient.swift` | An `actor` over `URLSession`. Actor because the CSRF session id is mutable state shared across concurrent calls. See [rpc.md](rpc.md). |
| `TransmissionModels.swift` | `Torrent`, `SessionStats`, `SessionSettings`, files/peers/trackers. Hand-written `init(from:)` everywhere so a missing key is a default, not a throw. One `Torrent` struct serves both the list poll and the details view; detail-only fields stay nil after a list poll. |
| `Config.swift` | [config.md](config.md). `scheme` maps to the JSON key `protocol`. |
| `Formats.swift`, `TVDetect.swift` | Rule-for-rule ports of the Python modules. |
| `FileTree.swift` | `FileNode.tree` folds Transmission's flat path list into a directory tree, aggregating size, progress and priority. Pure, so it's tested without a server. |
| `Selection.swift` | List selection arithmetic and the Escape ordering. Pure for the same reason. |
| `TrayIcon.swift` | The four-state glyph rule, duplicated from `linux/flinger/core/trayicon.py`, plus `showsGlyph(speedsVisible:)` — macOS-only, because the Linux tray has no text label. |
| `SpeedAverager.swift` | The menu bar's moving average. See below. |
| `JSONValue.swift` | Dynamic JSON for free-form request bodies (`torrent-set`, `session-set`). Responses decode into concrete types; only requests need this. |

**The rule for this directory**: logic the UI depends on lives here as pure
functions, not inside `@MainActor` view models. Constructing a `TorrentStore`
starts a poll timer and hits the network, which a test must never do — so
anything with branching worth testing gets pushed down here first.

## `TorrentStore` — the hub

`@MainActor final class TorrentStore: ObservableObject`. Owns polling, the
config, the client, selection and expansion state, every mutating action,
finish notifications, and remote→local path resolution.

- Poll cadence: `config.pollIntervalMs` while the panel is open, and no faster
  than 30 s while closed (a floor, so a config asking for something slower keeps
  it), guarded against reentrancy by `isPolling`.
- Mutating actions run the RPC and then re-poll, so the UI never shows an
  optimistic guess.
- `client` is injectable — that's the seam `--demo` uses (below).

## `AppDelegate` — the AppKit half

Owns the `NSStatusItem`, the panel, link handling and the auxiliary windows. It
repaints the status item from `store.objectWillChange`, **hopped one runloop
tick**, because `objectWillChange` fires *before* the `@Published` value is
written — without the hop you paint the previous state.

The panel is a borderless `NSPanel`, not an `NSPopover`: `NSPopover` mis-places
its anchor rect, and a `.nonactivatingPanel` that can become key lets the search
field take keystrokes without activating the app.

## Speed smoothing

`Core/SpeedAverager.swift` widens the menu-bar readout as a transfer settles:
live for the first 15 s, then a 15 s average refreshed every 5 s, then a 30 s
average refreshed every 10 s. Transmission's own `downloadSpeed` covers about
two seconds, so a raw reading in the menu bar is noise.

Three things about it that aren't obvious:

- **It needs its own sampling.** The closed-panel poll is every 30 s, which
  can't feed a 15 s window. `TorrentStore` runs a second timer calling
  `session-stats` alone every 2.5 s, only while the panel is closed, the speeds
  are switched on and something is transferring.
- **Averages come from the byte counter**, not from averaging rate readings —
  `current-stats.downloadedBytes` over wall time is exact. It falls back to a
  time-weighted mean when the counter doesn't move (servers that don't report
  `current-stats`) or goes backwards (a daemon restart).
- **Discontinuities reset it.** A gap wider than the widest window (a sleeping
  laptop, a throttled timer) or a backward clock step starts the tiers over.
  Without that, waking from a four-hour sleep reported kilobytes per second
  while pulling megabytes.

## `SelfTest/` — tests and tooling

Entirely `#if DEBUG`, so `swift build -c release` compiles none of it. See
[testing.md](testing.md) for the suite itself. Two pieces of tooling live here:

**`DebugWindow.swift`** opens any one window on its own, because driving the
real status item needs an Accessibility grant a terminal session doesn't have:

```bash
swift run TorrentFlinger --show-window options          # or popover|add|details|stats
swift run TorrentFlinger --show-window options:limits   # straight to a tab
swift run TorrentFlinger --show-window details:13:files # a torrent + a tab
```

Don't try to snapshot these offscreen — `cacheDisplay` and `CALayer.render(in:)`
both silently drop SwiftUI-drawn chrome, which reads as a layout bug that isn't
there. Show the window and capture it externally.

**`DemoRPC.swift`** is a `URLProtocol` serving an invented session — every list
section occupied, a nested file tree, peers and trackers — plus a throwaway
`Config` pointing at `transmission.example.lan`. Add `--demo` to any
`--show-window` command and nothing real is on screen:

```bash
swift run TorrentFlinger --show-window popover --demo
```

That's how the screenshots in [`docs/images/`](images/) were made, and how they
should be remade. The alternative — screenshotting a live server — puts a
hostname, real torrent names and local paths into a public repository.

### Regenerating the screenshots

```bash
cd macos
swift run TorrentFlinger --show-window popover --demo &
# find the window id, then capture just that window:
screencapture -x -o -l"$(…CGWindowListCopyWindowInfo…)" popover.png
```

The window id comes from `CGWindowListCopyWindowInfo` filtered by owner name —
a dozen lines of Swift run as a script. `screencapture -R x,y,w,h` works for the
menu bar itself. Both need Screen Recording permission for the terminal.
