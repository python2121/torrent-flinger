# TorrentFlinger (macOS) — Feature Map

TorrentFlinger is a single-target Swift Package macOS menu-bar app that views
and administers a **remote Transmission server**, and gives magnet links and
`.torrent` files somewhere to go without a browser extension. It's a port of
the PySide6 tray app in `../linux/flinger/`: the same RPC feature set and the same
`config.json`, rehoused in a SwiftUI panel hanging off an `NSStatusItem`. It
polls the server every 3 s while its panel is open and every 30 s while it's
closed, renders a smoothed view of the aggregate speeds in the menu bar, groups
torrents by status in an expandable list, and opens per-torrent Details, server
Options, session Statistics and add-torrent windows alongside. It stays out of
the Dock (`LSUIElement` + `.accessory`) and guards against duplicate menu-bar
items with a POSIX file lock.

## Feature areas

### Core (AppKit-free — `Sources/TorrentFlinger/Core/`)

- **Transmission RPC client** — `TransmissionClient` is an `actor` over
  `URLSession` covering the pre-4.1 protocol: `torrent-get` (list and detail
  field sets), `session-get`/`session-set`/`session-stats`, `torrent-add`,
  `torrent-start`/`-stop`/`-remove`/`-set`/`-set-location`/`-verify`/`-reannounce`,
  `queue-move-*`, `free-space`, `port-test`. Actor isolation exists because the
  CSRF session id is mutable state shared across concurrent calls.
  `Core/TransmissionClient.swift`
- **CSRF 409 handshake** — a 409 response carries the session id to repeat the
  call with; the client retries exactly once, so a second 409 surfaces as a
  real failure instead of looping. `Core/TransmissionClient.swift`
- **Auth, TLS and error mapping** — Basic auth from the config; 401/403 →
  `.authFailed`, other non-2xx → `.http`, transport failures →
  `.connectionFailed`, `result != "success"` → `.rpc`. An opt-out
  `InsecureTrustDelegate` accepts self-signed certificates only when the user
  has unticked "Verify TLS certificate". A malformed URL from the options
  dialog degrades to a clean per-call error rather than trapping at
  construction. `Core/TransmissionClient.swift`
- **`ids` semantics** — `nil` means "all torrents" (the key is omitted from the
  wire payload); an empty array is a no-op that never reaches the server. The
  difference between pausing nothing and pausing everything.
  `Core/TransmissionClient.swift`
- **Lenient torrent decoding** — one `Torrent` struct serves both the list poll
  and the details view (detail-only fields stay nil after a list poll). Every
  field falls back to a documented default because Transmission 3.x, 4.x and
  the reimplementations disagree about which keys they emit; `eta` defaults to
  -1 ("unknown") and `metadataPercentComplete` to 1. `fileStats[].wanted`
  decodes from either 0/1 or a boolean, and `peer-limit` is mapped through a
  `CodingKey` (kebab-case inside a camelCase object).
  `Core/TransmissionModels.swift`
- **Torrent state classification** — `Torrent.state` reproduces
  `linux/flinger/ui/style.py: torrent_state`: an error string wins over everything,
  then incomplete metadata (magnetizing), then status, with stopped splitting
  into complete vs paused on `percentDone`. `Torrent.group` maps state onto the
  six popover sections and `Torrent.groupOrder` fixes their order (Error
  first). `Core/TransmissionModels.swift`
- **Config load/save** — `Config` is `Codable` against the *Python* key names
  (`protocol`, `rpc_path`, `verify_tls`, `custom_dirs`, …) at
  `~/Library/Application Support/torrent-flinger/config.json`, so the Linux and
  macOS builds share one file. Decoding is per-key lenient (bad value → default,
  never a throw) and unknown keys are ignored. Saves are atomic and chmod 0600,
  because the password lives in there. `CustomDir` omits `tv` when false, matching
  Python's conditional key, so a round trip doesn't churn the file. `Core/Config.swift`
- **Formatting** — SI (1000-based) sizes and speeds, ETA (`1d 1h` / `1h 5m` /
  `45s`, empty for -1), status names, dates, a compact menu-bar speed
  (`1.2M`), and `linkDisplayName` for magnet `dn` parameters (with `+` → space)
  and percent-encoded file paths. `Core/Formats.swift`
- **Remote→local path mapping** — `mapRemotePath` translates a server path
  under a local mount (matching on path *components*, so `/data/torrents2`
  isn't "under" `/data/torrents`); `commonRemoteRoot` infers the share root
  from the default download dir plus the custom dirs; `resolveLocalPath` tries
  the prefix mapping and then probes path suffixes longest-first, returning only
  paths that actually exist. `Core/Formats.swift`
- **TV detection** — marker-based and precision-first: episode markers
  (`S01E02` / `3x07`), air-date naming (daily shows), then season packs
  (`S01`, `Season 2`, `Complete Series`, `Seasons 1-6`). Bare titles are
  deliberately not matched — movie/show collisions weren't worth the false
  positives. `findTVDir` reads the explicit per-directory flag, not the label.
  `Core/TVDetect.swift`
- **Dynamic JSON** — `JSONValue` covers the free-form request bodies
  (`torrent-set`, `session-set`) with literal conformances; responses decode
  into concrete types. `Core/JSONValue.swift`

### Tray / menu-bar icon

- **Four shared states** — `TrayIcon.current(connected:downloadSpeed:recentlyAdded:)`
  picks between a horseshoe magnet (idle), a down arrow (downloading), an
  exclamation mark (error) and a plus (just added). Precedence: a fresh add
  wins for three seconds because it's a *notification* rather than a status,
  then disconnection, then transfer activity, then idle. "Downloading" keys off
  download speed alone — a seeding-only session shows the magnet, because a
  down arrow would be a lie. The Linux build implements the identical rules in
  `linux/flinger/core/trayicon.py`; both are tested.
  `Core/TrayIcon.swift`
- **One monochrome artwork set for both builds** — `linux/flinger/assets/tray-*.svg`,
  copied into the bundle's Resources by `build-app.sh` and read directly by the
  Linux tray. Monochrome so each OS can tint it: AppKit does it for free via
  `isTemplate` (adapting to light/dark, a tinted menu bar, and the inverted
  highlight while the panel is open); Qt has no equivalent, so the Linux side
  composites the palette colour through the alpha by hand. Drawn to fill ~82%
  of the 16pt box — a first cut at 65% read visibly lighter than the system
  icons either side of it. `AppDelegate.trayImage`, `linux/flinger/ui/style.py`
- **Dev-loop fallback** — `swift run` has no bundle to load resources from, so
  a missing asset falls back to an SF Symbol per state rather than showing a
  blank menu bar. Because that fallback is silent, a test asserts every state's
  SVG actually exists. `Core/TrayIcon.swift`, `SelfTest/UILogicTests.swift`
- **Transient "added" flash** — `TorrentStore.flashAdded()` sets
  `recentlyAdded` for `TrayIcon.addedDuration` (3 s) when a torrent is
  *newly* accepted; a duplicate doesn't flash, since nothing changed. A second
  add inside the window restarts the clock rather than stacking timers, so a
  batch of dropped files reads as one continuous "+". `TorrentStore.swift`

### Networking permissions

- **Local Network permission bootstrap** — macOS gates connections to LAN
  addresses. A `URLSession` request to a private IP without the grant fails with
  `NSURLErrorNotConnectedToInternet` (-1009) but does *not* prompt, and the app
  never appears in System Settings → Privacy & Security → Local Network, so
  there is nothing to switch on. `LocalNetwork.requestAccess()` starts an
  `NWBrowser` Bonjour browse at launch purely for its side effect — that is the
  operation the permission is keyed to — and cancels it after 10 s. Its
  `onReady` callback re-polls immediately, so the launch poll losing the race
  doesn't leave "Disconnected" up until the next tick. Because this runs every
  launch, access is re-established after a rebuild too — so ad-hoc signing
  survives the executable-UUID churn that Apple's TN3179 warns about.
  `Sources/TorrentFlinger/LocalNetwork.swift`, `AppDelegate.swift`
- **Quiet launch retry** — the launch poll reliably loses the race with the
  permission browse and comes back `-1009`. Rather than flashing
  "Disconnected", `TorrentStore` retries a `localNetworkBlocked` failure up to
  four times at 0.5 s intervals before surfacing it, so a genuinely denied
  permission still reaches the user while the expected startup blip doesn't.
  `TorrentStore.swift`
- **Actionable blocked-network error** — `TransmissionClient` maps -1009 to
  `TransmissionError.localNetworkBlocked`, whose message names the exact
  Settings pane instead of repeating URLSession's misleading "the Internet
  connection appears to be offline". `Core/TransmissionClient.swift`
- **Info.plist declarations** — `NSLocalNetworkUsageDescription` (without it the
  permission can't be granted) and `NSAppTransportSecurity` with
  `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` (Transmission's RPC is
  plain http, which ATS otherwise blocks with -1022). `build-app.sh`
- **Unified-log diagnostics** — a menu-bar app has no terminal and a
  LaunchServices-started bundle has no stdout, so `Log` writes failures to the
  unified log under subsystem `io.github.python2121.TorrentFlinger` at `.error`
  (persisted), including the underlying `NSError` domain/code.
  `Sources/TorrentFlinger/Log.swift`

### App core & state

- **App entry and dispatch** — `TorrentFlingerMain.main()` dispatches
  `--self-test` (debug builds only), then takes the single-instance lock, then
  creates the shared `NSApplication` with `.accessory` policy. Command-line
  links are replayed into `AppDelegate` once the app is up. `App.swift`
- **Single-instance lock** — a POSIX `flock` on `instance.lock` in Application
  Support, taken before `NSApplication`. macOS only de-dupes launches routed
  through LaunchServices, so the raw binary (or `swift run` beside an installed
  copy) would otherwise stack a second status item and a second poller. The
  kernel releases the lock on exit, so it can't go stale; a filesystem failure
  fails open. `SingleInstance.swift`
- **Second-launch link forwarding** — a launch that can't get the lock re-opens
  its links against our own bundle, so they reach the instance that holds it,
  then exits 0. The macOS equivalent of the Linux build's local-socket
  forwarding. `App.swift`
- **Polling** — `TorrentStore` polls `session-get` → `free-space` →
  `torrent-get` → `session-stats` on a `Timer` at the configured interval while
  the panel is open and no faster than every 30 s while it's closed — a floor,
  so closing the panel can't speed a slower configured interval up. Guarded
  against reentrancy. Free space is decoration and never fails the poll.
  `TorrentStore.swift`
- **Speeds-only tick** — a second `Timer` calling `session-stats` alone every
  2.5 s, running only while the panel is closed, the speeds are switched on and
  something is actually transferring. The menu-bar average needs readings far
  more often than the idle 30 s poll delivers, but not the torrent list to go
  with them. Skipped while a full poll — or a previous tick — is still in
  flight, so a server slower to answer than the tick can't have requests pile
  up on it. `TorrentStore.swift`
- **Menu-bar speed smoothing** — `SpeedAverager` widens the readout as a
  transfer settles: live for the first 15 s, then a 15 s average refreshed
  every 5 s, then a 30 s average refreshed every 10 s past the 30 s mark. Age
  runs from when the transfer started, so each new download gets the responsive
  tier again. Averages come from the session byte counter (bytes over wall
  time — exact, and undistorted by a late or missing sample), falling back to a
  time-weighted mean of the rate readings when the counter doesn't move (a
  server that doesn't report `current-stats`) or goes backwards (a daemon
  restart). A stall of a few seconds is absorbed; zero for 5 s ends the
  transfer and clears the bar. A gap wider than the widest window — a sleeping
  machine, a throttled timer — or a clock stepping backwards breaks continuity
  and starts the tiers over, rather than averaging the hole into the transfer.
  `Core/SpeedAverager.swift`
- **Path-mapping resolution at poll time** — the remote prefix is the explicit
  setting when set, else the common root of the server's download dir and every
  custom dir (so `/data/complete` and `/data/tv` both map through `/data`).
  `TorrentStore.swift`
- **Finish notifications** — the set of completed ids is tracked across polls
  and is nil until the first successful one, so launching doesn't announce the
  existing backlog. `Notifier` gates every call on being a real `.app` bundle
  (`UNUserNotificationCenter.current()` traps otherwise) and falls back to
  stderr. `TorrentStore.swift`, `Notifier.swift`
- **Selection model** — click selects, ⇧-click extends from the anchor over the
  *visual* order (grouping means that differs from server order), ⌘-click
  toggles. The anchor stays put across an extend so the range can be resized
  rather than ratcheting, and an extend with a missing or stale anchor degrades
  to a plain click instead of selecting nothing. ↑/↓ walk the visible list and
  land on what a plain click would produce (`Selection.step`), clamping at the
  ends and resuming from the last visible selected row when the cursor has been
  filtered away; ⇧↑/⇧↓ apply the landing row as an extend, so one range grows
  and shrinks. That needs a cursor (the moving end) tracked separately from the
  anchor — stepping from the anchor would leave ⇧↓ stuck one row from it. The
  panel takes the arrows in `sendEvent` because the search field is first
  responder whenever it's open, and the list scrolls the landing row into view.
  → and ← open and close every highlighted row (`Selection.expansion`),
  idempotently, since a held arrow repeats and a toggle would flicker the row.
  They're only claimed while something *is* highlighted: a single-line field
  ignores ↑/↓ so those can be taken outright, but ←/→ drive the caret, and
  taking them unconditionally would make the filter box uneditable.
  The arithmetic is the pure `Selection.apply`/`Selection.step`/
  `Selection.expansion`; `TorrentStore` only maps `EventModifiers` onto it.
  Selections and expansions are dropped for torrents that disappear
  server-side, and cleared when the panel closes so a reopened panel looks
  freshly opened. `Core/Selection.swift`, `TorrentStore.swift`
- **Grouping and search** — `Torrent.grouped(_:matching:)` applies the
  case-insensitive substring filter, buckets by status into `groupOrder`,
  preserves server order within a group (queue position is meaningful) and
  omits empty groups so no bare header renders. Pure, so the popover's list
  content is testable without a store. `Core/TransmissionModels.swift`
- **Actions** — start/stop (single, batch, and all), remove (with optional data
  deletion), add, copy magnets, open web UI; verify and reannounce live on
  `DetailsViewModel`, since the details window is the only place offering them. Each
  re-polls on success and surfaces failures as a notification rather than
  blocking the panel. `TorrentStore.swift`
- **Reveal in Finder** — resolves the torrent's server-side directory to a local
  path and selects the torrent's own file/folder via
  `NSWorkspace.activateFileViewerSelecting`, falling back to opening the
  containing directory when the item isn't there yet. The action is hidden
  entirely when nothing resolves. `TorrentStore.swift`

### UI

- **Menu-bar item** — an SF Symbol reflecting state (idle / transferring /
  disconnected) plus optional smoothed speeds (`↓1.2M ↑2.4M`, monospaced digits,
  toggleable in Options; see *Menu-bar speed smoothing*) and a tooltip with the
  torrent count, the live speeds and which window the bar is averaging over.
  Download shows at any speed; upload only above 1 MB/s, since a permanent
  seeding trickle is width without news. Both still appear in the tooltip and
  the popover footer at any speed. A lone figure is drawn at the menu bar's own
  point size so it sits with the system's items; a pair drops two points, which
  is the only way both fit.
  The glyph reads the same smoothed numbers, so the two can't disagree — except
  with the speeds switched off, where there are no numbers to disagree with and
  no fast sampling to feed a window, so it reads the raw speed instead.
  Repainted from `store.objectWillChange`, hopped one runloop tick because it
  fires before the `@Published` write lands. `AppDelegate.swift`
- **Status-item right-click menu** — a native `NSMenu` mirroring the Linux tray
  menu (Show torrents, Add torrent file…, Add magnet from clipboard, Start all,
  Pause all, Statistics…, Full web interface, Options…, Quit). Assigned to
  `statusItem.menu` only for the duration of the click and detached in
  `menuDidClose`, so left-click keeps toggling the panel. `AppDelegate.swift`
- **Borderless panel** — an `NSPanel` (`.borderless`, `.nonactivatingPanel`,
  `canBecomeKey`) with an `NSVisualEffectView` (`.menu`) masked by a resizable
  rounded-rect image plus a light-mode `NSBox` tint, animated open/close, placed
  under the status item and clamped on-screen. A global mouse monitor dismisses
  it on outside clicks; Escape clears the selection first, an active search
  second, and closes the panel third.
  It follows SwiftUI's `preferredContentSize` so adding a row doesn't make it
  drift. `AppDelegate.swift`
- **Panel layout** — header (title + connection dot), toolbar (search, add
  menu), optional clipboard banner, grouped scrolling list, footer.
  `PopoverView.swift`
- **Clipboard magnet offer** — opening the panel with a magnet link copied shows
  a banner offering to add it; dismissing remembers that link so it isn't
  re-offered. `TorrentStore.swift`, `PopoverView.swift`
- **Expandable rows** — state badge, elided name, `↓/↑ speed · % · ETA`
  subtitle (collapsing to the error string when in trouble, or size + ratio once
  complete), a slim state-colored progress bar, a three-state primary action
  (Remove when complete / Resume when paused / Pause when active — the ✕
  removes immediately, keeping the data, since it only shows on a completed
  torrent; the ellipsis entries elsewhere are the ones that confirm) and a chevron
  that expands quick actions plus a six-field detail grid. The chevron's glyph is
  10pt but its target is 30pt by the full row height: it was an 18pt box before,
  and a miss doesn't do nothing — it lands on the row and *selects*, so the
  chevron read as unreliable rather than as small. Nothing is drawn there, so
  the target costs only the gap beside the primary action, tightened to 2pt to
  keep it off the torrent name. `TorrentRowView.swift`
- **Row context menu** — Resume (only when something in the selection is
  stopped), Pause (only when something in it is running), and — for a single
  row — Reveal in Finder, Torrent files (the details window opened on its Files
  tab) and Details, plus Remove. Verify, reannounce and copy magnet were
  deliberately dropped from here; they live in the details window. Acts on
  the whole selection when the clicked row is in it. Targets are computed
  purely so building the menu never mutates state mid-update.
  `TorrentRowView.swift`
- **State color and glyph vocabulary** — the Breeze positive/negative accents
  the Linux build uses (so screenshots of the two read the same) over macOS
  dynamic colors for everything neutral, plus an SF Symbol per state.
  `StateBadge` and `ProgressGauge` (a `Canvas` bar, 4pt, 19%-alpha track) are
  the shared primitives. `StateColor.swift`
- **Footer** — aggregate speeds, torrent count and server free space (or the
  connection error), then refresh / statistics / web-UI controls and a gear
  menu (Start all, Pause all, Options…, Quit). `.focusEffectDisabled()` so the
  panel doesn't park a focus ring on a control at open. `PopoverView.swift`
- **Placeholder states** — distinguishes connecting, the connection error, "no
  torrents" and "no matching torrents", so the empty panel says which.
  `PopoverView.swift`

### Windows

- **Shared window chrome** — `HostedWindow` hosts SwiftUI in a titled
  `NSWindow`, built lazily and reused, closing on ⌘W and Escape (an accessory
  app has no menu bar, so neither has a default responder) and activating the
  app before fronting (an accessory app isn't active, so windows would open
  behind). `HostedWindow.swift`
- **Add-torrent dialog** — the torrent's name, a destination picker (server
  default plus the custom directories), live free space for the selected
  destination, and a paused checkbox. Preselects the last-used destination, and
  overrides it with the flagged TV folder — showing why — when the name looks
  like a TV show. One window per incoming link, so a batch of dropped files
  doesn't queue behind a single modal. `AddTorrentWindow.swift`
- **Options window** — five tabs matching the Linux dialog. *Server*
  (scheme/host/port/paths/credentials/TLS + Test Connection), *General*
  (notifications, menu-bar speeds, and the refresh interval — the same twelve
  cadences from 1s to 2m the Linux dialog offers, plus whatever off-menu
  interval a hand-edited config holds), *Download* (start paused,
  show add dialog, and the custom-directory list with radio-exclusive TV
  flagging), *Local* (remote prefix + local mount with a folder picker, which is
  what enables Reveal in Finder), *Limits* (global speed caps, the turtle-mode
  switch and its caps, and the default seed ratio — turtle mode lives here
  rather than in the toolbar, since it's a set-and-forget server setting;
  loaded live via `session-get` and disabled until they
  arrive — so a failed load can't overwrite the server's values with our
  defaults). `OptionsWindow.swift`
- **Details window** — a per-torrent action bar (pause/resume, verify,
  reannounce, set location, copy magnet, remove) over five tabs: *Info*
  (sizes, ratio, dates, pieces, privacy, hash, error), *Files* (a collapsible
  directory tree — folders show the size, progress and priority of everything
  under them and a tri-state checkbox that checks or skips the whole subtree in
  one call — plus high/normal/low priority via a multi-select context menu;
  `FileNode` in `Core/FileTree.swift` builds the tree), *Peers*, *Trackers*
  (with failed-announce highlighting) and *Options*
  (per-torrent limits, seed-ratio mode, peer limit, queue moves). Refreshes
  every 3 s, pauses field updates while the Options tab is being edited, and
  closes itself when the torrent disappears server-side. One window per torrent,
  reused while open. `DetailsWindow.swift`
- **Statistics window** — this session vs. cumulative totals (downloaded,
  uploaded, ratio, files added, active time, sessions) with a Refresh button.
  `StatsWindow.swift`
- **Confirmations and pickers** — the remove confirmation (raised by the
  expanded-row and context-menu entries, not by the row's ✕) carries the Linux
  build's "Also delete downloaded data" checkbox as an `NSAlert` accessory;
  folder selection uses `NSOpenPanel`. Both activate the app first.
  `Dialogs.swift`

### Link handling

- **Magnet and `.torrent` registration** — `CFBundleURLTypes` (scheme `magnet`)
  and `CFBundleDocumentTypes` (`org.bittorrent.torrent`) in the generated
  `Info.plist`; both arrive via `application(_:open:)`. `build-app.sh` and
  `install.sh` run `lsregister` so the registration takes effect without a
  logout. `build-app.sh`, `install.sh`, `AppDelegate.swift`
- **Add flow** — links go through the add dialog when
  `show_add_dialog` is set, otherwise straight to the server with the configured
  paused state. Outcomes are announced as "Torrent added" or "Already in
  Transmission" (the server reports a duplicate under a different key).
  `AppDelegate.swift`, `TorrentStore.swift`

### Build & test

- **Bundle assembly** — `build-app.sh` runs `swift build -c release`, assembles
  `TorrentFlinger.app`, generates `AppIcon.icns` from the Linux build's shared
  PNG assets (optional; a failure isn't fatal), writes the `Info.plist`
  inline (including `LSUIElement` and the URL/document types), signs, and
  re-registers with LaunchServices. Ad-hoc signing is the default; a requested
  `SIGN_IDENTITY` that silently falls back to ad-hoc is a hard error.
  `build-app.sh`
- **Install** — `install.sh` stops the LaunchAgent and any running copy, replaces
  `/Applications/TorrentFlinger.app`, verifies the signature survived the move,
  re-registers, and restarts (via the LaunchAgent when one exists).
  `install.sh`
- **Self-test suite** — a hand-rolled harness (`TestCase` collector,
  `TestEntry` registry, a runner that reports and returns an exit code), because
  Command Line Tools ship neither XCTest nor swift-testing. 57 cases / 261
  checks over formatting, path mapping, TV detection, config load/save, torrent
  state classification, list grouping + search, selection arithmetic,
  custom-directory rules, and the RPC client against `MockRPC` — a
  `URLProtocol` reproducing the 409 handshake, 0/1 `wanted`, and kebab-case
  `peer-limit` — plus `FailingTransport`, which pins the URLSession-error
  mapping (notably that -1009 becomes the actionable local-network message and
  that other transport errors don't). The whole directory is `#if DEBUG`,
  dispatched by `--self-test` before `NSApplication`, so release builds contain
  none of it.
  `Sources/TorrentFlinger/SelfTest/`, `test.sh`
- **Pre-push gate** — `.githooks/pre-push` runs `./test.sh` and, when a `.venv`
  exists, the Linux app's Python tests too, so a shared-repo push can't break
  the other target. `.githooks/pre-push`

## Key types

| Type | Role | File |
|---|---|---|
| `TransmissionClient` | Actor wrapping the RPC protocol | `Core/TransmissionClient.swift` |
| `Torrent`, `SessionStats`, `SessionSettings` | Lenient response models | `Core/TransmissionModels.swift` |
| `Config`, `CustomDir` | Persisted settings, shared with the Linux build | `Core/Config.swift` |
| `Format`, `TVDetect` | Display formatting, path mapping, TV heuristics | `Core/Formats.swift`, `Core/TVDetect.swift` |
| `Selection` | Pure list-selection arithmetic (replace/extend/toggle) | `Core/Selection.swift` |
| `Log`, `LocalNetwork` | Unified-log channel; Local Network permission bootstrap | `Log.swift`, `LocalNetwork.swift` |
| `TorrentStore` | The single source of truth: polling, selection, actions | `TorrentStore.swift` |
| `AppDelegate` | Status item, panel, links, window ownership | `AppDelegate.swift` |
| `PopoverView`, `TorrentRowView` | The panel and its expandable rows | `PopoverView.swift`, `TorrentRowView.swift` |
| `HostedWindow` | Shared chrome for the auxiliary windows | `HostedWindow.swift` |
| `TestCase`, `TestEntry`, `TestRunner` | The test harness | `SelfTest/TestHarness.swift` |

## Launch → poll → render flow

1. `App.main` dispatches `--self-test` (debug), takes the single-instance lock,
   sets `.accessory`, and starts `NSApplication`.
2. `AppDelegate.applicationDidFinishLaunching` creates the status item, builds
   the panel, subscribes to `store.objectWillChange`, requests notification
   authorization, installs a minimal Edit menu (so ⌘V works in text fields —
   an accessory app has no menu bar), and replays any command-line links.
3. `TorrentStore.init` loads the config, constructs the client, starts the
   30 s timer and polls immediately.
4. Each poll resolves the path-mapping prefix, publishes the new state, and
   announces newly finished torrents.
5. `objectWillChange` repaints the menu-bar item; opening the panel switches the
   timer to the configured interval, refreshes the clipboard offer, and polls
   again.
