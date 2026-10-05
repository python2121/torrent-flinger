# CLAUDE.md — macOS build

Guidance for Claude Code when working in `macos/`. For the Linux app one level
up, see the [root README](../README.md).

## What this is

`TorrentFlinger` is a Swift Package macOS menu-bar app with two targets
(`Package.swift`): `TorrentFlingerCore` (`Sources/TorrentFlingerCore/`), the
Foundation-only library, and `TorrentFlinger` (`Sources/TorrentFlinger/`), the
AppKit + SwiftUI executable. It's a port of the PySide6 tray app in
`../linux/flinger/`: same Transmission RPC feature set, same `config.json`,
different shell (SwiftUI + AppKit instead of Qt, menu bar instead of system
tray).

**The library is shared with the iPhone app in `../ios/`**, which links this
package from `../macos` as a local dependency and builds only the
`TorrentFlingerCore` product. So Core has three extra rules — see "Things to
know" below — and a change there is a change to the phone too; build both
(`cd ../ios && ./build.sh`) before pushing a Core change.

**The Linux app is off-limits.** Nothing in `macos/` may require a change to
anything under `../linux/` — the Python package, its tests, its scripts or its
packaging. The two builds are peers: they sit side by side at the repo root,
coexist in one repo, and must both keep working independently. The one
intentional coupling is `config.json`: both read and write
`~/Library/Application Support/torrent-flinger/config.json` on macOS with
identical key names, and both ignore keys they don't know. If you add a config
key here, give it a default that reads sensibly to the Python side, and don't
rename an existing one.

## Common commands

```bash
./build-app.sh          # swift build -c release + assemble + codesign → ./TorrentFlinger.app
./install.sh            # build (unless SKIP_BUILD=1), replace /Applications copy, restart
swift build             # compile only
swift run TorrentFlinger        # dev loop; unbundled, so no magnet handling or notifications
./test.sh               # the self-test suite
./test.sh client/       # …filtered by test-name substring
SIGN_IDENTITY="My Cert" ./build-app.sh   # sign with a real cert instead of ad-hoc
SKIP_BUILD=1 ./install.sh                # reinstall an already-built bundle
```

Logs — a menu-bar app has no terminal, so failures go to the unified log:

```bash
/usr/bin/log show --last 10m --info --style compact \
  --predicate 'subsystem == "io.github.python2121.TorrentFlinger"'
```

Two shell gotchas that will waste your time: `log` is a **zsh builtin** that
shadows `/usr/bin/log` (you get "too many arguments", or silently empty
output), and `pkill -x TorrentFlinger` does **not** match the running app — use
`pkill -f "TorrentFlinger.app/Contents/MacOS"`. A surviving instance holds the
single-instance flock, so every later launch exits 0 without a word and you end
up debugging a stale binary.

## Architecture

`App.swift` → `AppDelegate.swift` → `TorrentStore` (the single source of truth)
drives an `NSStatusItem` (menu bar) and a borderless `NSPanel` hosting
`PopoverView` (SwiftUI). `TorrentStore.objectWillChange` is observed by
`AppDelegate` to repaint the menu-bar item (hopped one runloop tick, because
`objectWillChange` fires *before* the `@Published` write).

`Sources/TorrentFlingerCore/` is the Foundation-only layer and a direct port of
`../linux/flinger/core/`. Everything the executable uses from it is reached via
`import TorrentFlingerCore`:

- **`TransmissionClient.swift`** — an `actor` over `URLSession`. Async/await
  instead of the Python version's blocking `urllib` + `QThreadPool`; an actor
  because the CSRF session id is mutable state shared across concurrent calls.
  Handles the 409 handshake (one retry, then it's a real failure), Basic auth,
  and an opt-out TLS trust delegate for self-signed NAS certificates.
- **`TransmissionModels.swift`** — `Torrent` and friends. Every field decodes
  leniently (missing → documented default) because Transmission 3.x, 4.x and
  the reimplementations disagree about which keys they emit. One `Torrent`
  struct serves both the list poll and the details view; detail-only fields
  stay nil after a list poll.
- **`Config.swift`**, **`Formats.swift`**, **`TVDetect.swift`** — ports of the
  Python modules of the same name, key-for-key and rule-for-rule.
- **`JSONValue.swift`** — dynamic JSON for the free-form request bodies
  (`torrent-set`, `session-set`). Responses decode into concrete types.
- **`PollChoices.swift`**, **`Log.swift`** — the refresh-interval menu rules
  (shared with the phone's Settings) and the unified-log wrapper (the client
  logs transport failures, so it lives with the client).

`TorrentStore.swift` owns polling (config's interval while the panel is open,
30 s while it's closed), selection and expansion state, every mutating action,
"newly finished" notifications, and remote→local path resolution for Reveal in
Finder. `AppDelegate` owns the panel, the status item, link handling, and the
four auxiliary windows.

`HostedWindow.swift` is the shared chrome for the Options / Stats / Details /
Add windows: a titled `NSWindow` that closes on ⌘W and Escape (an accessory app
has no menu bar, so those have no default responder) and activates the app
before fronting (an accessory app isn't active, so windows would otherwise open
behind and unfocused). The same applies to any `NSAlert` or `NSOpenPanel` —
`Dialogs.swift` calls `NSApp.activate(ignoringOtherApps:)` for exactly this
reason.

`SingleInstance.swift` takes a POSIX `flock` on
`~/Library/Application Support/torrent-flinger/instance.lock` before
`NSApplication` starts. macOS only de-dupes launches that go through
LaunchServices, so running the raw binary — or `swift run` while the installed
copy is up — otherwise stacks a second status item and a second poller. When a
second launch carries links, `App.main` re-opens them against our own bundle so
they reach the instance holding the lock (the macOS equivalent of the Linux
build's local-socket forwarding), then exits.

## Testing

**There is no `swift test` here, and no testing package is used.** Command Line
Tools ship neither XCTest nor swift-testing, so the suite is hand-rolled:
`Sources/TorrentFlinger/SelfTest/` holds `TestHarness.swift` (a `TestCase`
collector, a `TestEntry` registry, and a runner that prints a report and
returns an exit code) plus the cases. `SelfTest.runIfRequested` is dispatched
from `App.main` before the single-instance lock and before `NSApplication`, so
running tests never disturbs an installed copy.

The whole directory is wrapped in `#if DEBUG`, so `swift build -c release` —
what `build-app.sh` runs — compiles none of it into the shipping binary. If you
add a file under `SelfTest/`, wrap it the same way, or the release build will
carry test code.

The suite is in the executable target and reaches the library with
`@testable import TorrentFlingerCore` (SwiftPM debug builds enable
testability; the release build never compiles the suite).

Current coverage: 98 cases / 471 checks over formatting, path mapping, TV
detection, config load/save, torrent state classification, list grouping +
search, selection arithmetic, custom-directory rules, the Files tab's directory
tree (`FileNode.tree`), the menu bar's speed smoothing (`SpeedAverager` — pure
with an injected clock, so a minute of a download runs instantly), and the RPC client
against `MockRPC` (a `URLProtocol` reproducing the 409 handshake,
`fileStats[].wanted` as 0/1, and kebab-case `peer-limit`) plus
`FailingTransport` for the URLSession-error mapping. It deliberately does
**not** cover SwiftUI rendering or the AppKit panel — those are verified by
running the app.

Logic that the UI depends on lives in `TorrentFlingerCore/` as pure functions
(`Torrent.grouped`, `Selection.apply`, `CustomDir.markingTV`/`make`) rather than
inside the `@MainActor` view models, specifically so it's testable: constructing
a `TorrentStore` starts a poll timer and hits the network, which a test must
never do. If you add branching logic to a view model, push it down here first.

## Looking at the UI

Driving the real status item needs an Accessibility grant a terminal session
doesn't have, so `DebugWindow` (debug builds only) opens any one window on its
own for inspection:

```bash
swift run TorrentFlinger --show-window options          # or popover|add|details|stats
swift run TorrentFlinger --show-window options:limits   # straight to a tab
swift run TorrentFlinger --show-window details:26:files # a specific torrent + tab
screencapture -x /tmp/shot.png                          # from another shell
```

It uses the real `config.json`, so the views show real server data.

**Don't try to snapshot these offscreen.** `cacheDisplay` and
`CALayer.render(in:)` were both tried and both silently drop SwiftUI-drawn
chrome — the tab bar and the Cancel/Save bar came out blank while the Form
(a real `NSScrollView`) rendered fine, which reads as a layout bug that isn't
there. Show the window and capture it externally.

`../linux/tests/test_core.py` is the shared reference for core behavior. When you
change a formatting rule, a path-mapping rule or a TV-detection pattern here,
the Python test for it should still describe the same behavior — if it doesn't,
one of the two builds has drifted.

**When to run** — during feature development, after finishing a change, and
always before `git push`. `.githooks/pre-push` enforces the last one (activate
with `git config core.hooksPath macos/.githooks`); it runs `./test.sh` and, when
a `.venv` exists, the Linux app's Python tests too, so a shared-repo push can't
break the other target.

## Things to know before editing

- **Core is a library the phone links, so three rules apply under
  `Sources/TorrentFlingerCore/`.** (1) Anything the UI uses must be `public` —
  a new model field, a new `Format` helper, a new client method. A missing
  `public` fails the *executable's* build with "inaccessible due to 'internal'
  protection level", which is the hint. (2) Every public struct/enum is
  `Sendable`: the phone builds in Swift 6 language mode and its store is
  `@MainActor`, so a non-Sendable value returned from the `TransmissionClient`
  actor is a hard error there even though this Swift 5-mode package accepts it.
  (3) Foundation only, and it has to compile for iOS: no AppKit, no `Process`,
  and a macOS-only API goes behind `#if os(macOS)` with an iOS branch (see
  `Config.directory`, and the `localNetworkBlocked` message).
- **Never use `@State`; use `@ViewState`** (`ViewState.swift`). Since the
  macOS 27 SDK, `@State` is a macro backed by `libSwiftUIMacros.dylib`, which
  ships only inside Xcode — this machine has Command Line Tools only, so
  `@State` fails with "plugin for module 'SwiftUIMacros' not found" plus a
  cascade of "'self' is immutable" errors. `@ViewState` wraps the still-present
  `State<Value>` struct and behaves like the classic property wrapper
  (`$binding` works). `build-app.sh` rejects any `@State` in `Sources/`.
  `@Binding`, `@ObservedObject`, `@StateObject`, `@Environment`, and friends
  are still plain wrappers and fine. Also `import Combine` explicitly in files
  using `Timer.publish`/`onReceive` — Swift 6.4 warns when it's only reached
  through SwiftUI.
- **The Local Network permission is load-bearing — don't remove any of the
  three pieces.** macOS gates connections to LAN addresses, and a Transmission
  server is essentially always on the LAN. Getting this wrong costs an evening,
  because the symptom is a bare "Disconnected" while the same URL loads fine in
  a browser. The three pieces:
  1. `NSLocalNetworkUsageDescription` in `Info.plist` (`build-app.sh`) — without
     it the permission can't be granted at all.
  2. `NSAppTransportSecurity` with `NSAllowsArbitraryLoads` — Transmission's RPC
     is plain http; ATS blocks that with `-1022` for dotted hostnames.
  3. `LocalNetwork.requestAccess()` at launch (`AppDelegate`) — **this is the
     non-obvious one.** A `URLSession` request to a private IP is *blocked*
     without the grant but does **not** trigger the prompt, and the app never
     appears under System Settings → Privacy & Security → Local Network, so
     there's nothing to switch on either. Starting an `NWBrowser` Bonjour browse
     is what actually registers the app. The browse's results are ignored; it
     exists purely for that side effect.

  The failure mode is `NSURLErrorNotConnectedToInternet` (-1009), which
  `TransmissionClient` maps to `TransmissionError.localNetworkBlocked` so the
  UI says something actionable instead of "the Internet connection appears to
  be offline". Note that a process launched from a terminal inherits
  *Terminal's* grant, so `swift run` can work while the installed `.app`
  fails — never conclude "it works" from a shell-launched run alone.
- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus
  `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove
  either.
- The panel is a borderless `NSPanel`, not an `NSPopover` — same reasoning as
  ClaudeUsage: it sidesteps `NSPopover`'s anchor-rect mis-placement, and a
  `.nonactivatingPanel` that `canBecomeKey` lets the search field take
  keystrokes without activating the app. Escape peels back one layer per press
  — selection, then an active search, then the panel — matching the Linux popup
  (the order lives in `Selection.escape`).
- Don't mutate `@Published` state while building a view. `TorrentRowView`'s
  context menu computes its targets purely (selection if the row is in it, else
  just that row) rather than selecting on right-click, specifically to avoid
  "modifying state during view update".
- **The popover list's row identity includes its section, and its sections are
  a struct rather than a tuple.** Both matter, and getting either wrong shows up
  as a row that keeps drawing its old state until the panel is reopened — the
  torrent errors out, moves into the Error section, and stays blue with its old
  speed subtitle. A torrent that changes state changes section, so for one
  update the list holds both the old row and the new one: identified by torrent
  id alone the two collide and SwiftUI keeps the stale view, and `ForEach` over
  `(name:, torrents:)` tuples can't tell that a section's contents changed
  because tuples aren't `Equatable`. Reproduce by leaving the popover open and
  running `torrent-start`/`torrent-stop` over RPC from another shell; the row's
  `body` re-runs with the right data either way, so only the pixels tell you.
- **The popover list hides its scroll indicators, and that's load-bearing.**
  An overlay `NSScroller` draws over the trailing ~17pt of the list, but while
  it's *revealed* — the flash when the panel opens, or any scroll — its live
  hit strip reaches ≈33pt in from the edge, squarely over every row's chevron.
  A click there hits the scroller knob: nothing visible happens, the scroller
  collapses, and the *next* click at the same coordinates reaches the button.
  That's the "first click after opening does nothing" bug, and it cost a long
  session because every plausible explanation is wrong. It isn't
  `acceptsFirstMouse` (the event *is* delivered, just to the scroller, and
  SwiftUI already answers first-mouse correctly per location), it isn't gesture
  precedence, it isn't row identity, and a bigger hit target *masks* it —
  clicks landing left of the strip start working, so it looks fixed and returns
  the moment aiming stops being the obstacle. The keyboard is never affected,
  which makes it read as one broken control rather than a region of the window.
  If you ever need the indicator back, budget ≥34pt of trailing dead space per
  row for it. Diagnose this class of bug by logging `contentView.hitTest` per
  click in `PopoverPanel.sendEvent` — the hit-test target names the thief
  immediately, where reasoning about AppKit's input rules does not.
- `Notifier` is gated on being a real `.app` bundle:
  `UNUserNotificationCenter.current()` traps otherwise, which is exactly the
  `swift run` dev loop. Keep the guard.
- The RPC client targets the pre-4.1 protocol (Transmission 3.x and 4.x).
  `ids: nil` means "all torrents" and an empty array must stay a no-op — the
  difference between pausing nothing and pausing everything. There are tests
  for it; keep them.
- **The tray artwork is shared with the Linux build, so changes are paired.**
  `linux/flinger/assets/tray-{idle,downloading,error,added}.svg` is one monochrome set
  consumed by both: `build-app.sh` copies it into the bundle, `linux/flinger/ui/style.py`
  tints it for Qt. The selection rules are duplicated deliberately —
  `TorrentFlingerCore/TrayIcon.swift` and `linux/flinger/core/trayicon.py` — with matching tests on
  both sides, including one asserting the 3 s "added" duration is the same
  number in both. Keep them in step. Monochrome is a requirement, not a style
  choice: colour can't adapt to a dark panel or a tinted menu bar.
- **Ad-hoc signing is fine here** (unlike ClaudeUsage, where a stable identity
  is required for Keychain ACLs). Apple's TN3179 warns that local-network
  identity keys off the code signature plus the main executable's UUID, and
  that UUID does churn every rebuild — but in practice rebuilds keep working,
  because `LocalNetwork.requestAccess()` re-establishes access on every launch.
  Verified over rebuilds with genuinely different UUIDs: each one shows a
  blocked launch poll, then `browse ready`, then `connected` within a second.
  Don't reintroduce a hard signing requirement on the strength of the tech note
  alone — measure it.
- **Keep `FEATURE_MAP.md` in sync as you add, change, or remove features.** It's
  the human-readable map of what the app does. A stale feature map is worse
  than none.
