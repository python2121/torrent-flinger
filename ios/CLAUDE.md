# CLAUDE.md — iPhone build

Guidance for Claude Code when working in `ios/`. The Mac app is in
[`../macos/`](../macos/CLAUDE.md); the Linux app in `../linux/`. For what the
phone does and doesn't do, and why, see [`../docs/ios.md`](../docs/ios.md).

## What this is

`TorrentFlingerPhone` is a SwiftUI iPhone app — a hand-written Xcode project
(`TorrentFlingerPhone.xcodeproj`, synchronized root folder, so adding a file
needs no project edit) that links `TorrentFlingerCore` from `../macos` as a
local package. Everything that talks to Transmission is that library; this
directory is only the phone's shell: a store, the screens, and the glue that
turns a `magnet:` URL or a `.torrent` document into an add sheet.

Personal build. iOS 17+, iPhone only, not sandboxed for the App Store (no
review, no entitlements beyond the defaults). Signed with the user's own team
in Xcode and installed directly.

## Common commands

```bash
./build.sh                       # simulator build (CODE_SIGNING_ALLOWED=NO)
./build.sh run                   # …then install + launch on the booted simulator
./build.sh run detail:files      # …opening straight onto a screen (below)
open TorrentFlingerPhone.xcodeproj    # device install: pick the team under Signing, Run
swift ../ios/make-icon.swift     # from the repo root: regenerate the app icon
```

**Device installs go through Xcode, not `xcodebuild`.** From a terminal,
`xcodebuild -destination generic/platform=iOS -allowProvisioningUpdates` fails
with "No Accounts" — the Apple ID lives in Xcode's own session and the CLI
doesn't see it. `DEVELOPMENT_TEAM` is set in the project, so Xcode's Run
button is all it takes once the phone is trusted.

**Needs full Xcode.** The Command Line Tools have no iOS SDK. This is also why
this app uses plain `@State` while the Mac app must use `@ViewState`: the
SwiftUI macro plugin ships inside Xcode, and this target never builds without
it.

## Layout

```
TorrentFlingerPhone/
  App/
    TorrentFlingerPhoneApp.swift   @main; scenePhase → polling; onOpenURL → store
    PhoneStore.swift               @Observable @MainActor hub: config, client, poll,
                                   actions, pending adds, toasts
    PhoneConfig.swift              Config on disk (same JSON as the Mac) + Keychain
    Keychain.swift                 generic-password wrapper
  Views/
    RootView.swift                 first-run vs the list; add sheet + toast overlay
    TorrentListView.swift          the root: grouped list, search, swipe actions, Select
                                   mode; pushes Detail / Statistics / Settings
    TorrentRowView.swift           badge · name · subtitle · progress bar
    TorrentDetailView.swift        DetailModel + Info/Files/Peers/Trackers/Options
    AddTorrentSheet.swift          destination picker, TV hint, free space
    SettingsView.swift             server/behaviour/folders (+ first-run intro)
    LimitsView.swift               session-get/-set speed limits, turtle, ratio
    StatsView.swift                now / this session / all time
    Components.swift               StateColor, StateBadge, ProgressGauge, ToastView
  Assets.xcassets                  AppIcon (from make-icon.swift), AccentColor
  Info.plist                       magnet scheme, .torrent type, ATS, local network
```

## Things to know before editing

- **Core changes are Mac changes.** Anything you need from Transmission goes
  in `../macos/Sources/TorrentFlingerCore/`, must be `public`, and its models
  must be `Sendable` — this target builds in Swift 6 language mode and
  `PhoneStore` is `@MainActor`, so a non-Sendable value coming back from the
  `TransmissionClient` actor is a hard error here (the Mac package is Swift 5
  mode and won't warn). Run `cd ../macos && ./test.sh` after touching Core.
- **Polling is foreground-only, by design.** `PhoneStore.setActive` starts a
  `Task` loop on `.active` and cancels it otherwise. There is no
  `BGAppRefreshTask`, no push, no Live Activity: iOS doesn't give a personal
  app a schedule worth building on, so "download complete" is a toast you
  see if the app is open and nothing if it isn't. Don't add a background mode
  expecting it to poll.
- **Links arrive two ways and both land on `PhoneStore.receive`.** A `magnet:`
  URL comes through `onOpenURL` via the `CFBundleURLTypes` scheme; a
  `.torrent` comes as a file URL via `CFBundleDocumentTypes` (with
  `LSSupportsOpeningDocumentsInPlace` false, iOS copies it into
  `Documents/Inbox/` and the store deletes it after reading). The
  `org.bittorrent.torrent` UTI is **imported** in `Info.plist` — it isn't a
  system type, and without the declaration the share sheet never offers the
  app. Reading the file happens immediately in `receive(fileURL:)`, because
  the URL is a one-shot.
- **No tab bar, by request.** The list is the only root; Statistics and
  Settings are pushed from its overflow (…) menu. The list's selection
  binding is handed to `List` only in Select mode — a selectable List takes
  the tap itself, so with the binding always present a row highlighted
  instead of navigating.
- **The torrent name is a `UILabel`, not `Text`.** The list shortens names
  from the end but keeps the file extension (`…mkv`), via the shared
  `Format.truncateName` against a measurement of the real width. The
  measurement has to come from the engine that draws: `Text` breaks long
  unspaced release names in its own places (it hyphenates mid-word), so a
  string UIKit measured as two lines rendered as three in SwiftUI, and
  SwiftUI's own tail ellipsis ate the extension. Widening the slack didn't
  fix it — the break moves by more than a glyph. `TruncatedNameLabel`
  measures with `boundingRect` and draws with `UILabel`, which agree.
- **The add sheet is `sheet(item:)` over `pendingAdds.first`.** Dismissing it
  (Add or Cancel) removes the first pending entry through the binding's
  setter — `store.add` itself must not remove it, or a link that arrived while
  the sheet was up would be dropped with it.
- **`Config` on disk never holds the password.** `PhoneConfig.save` writes the
  file with an empty password and the secret to the Keychain; `load` prefers
  the Keychain and falls back to whatever the file says, which is how an
  imported Mac `config.json` works on first use. Don't "fix" the fallback.
- **Options-tab editing is tracked by value, not `onChange`.** `DetailModel`
  compares `options` with `serverOptions`; a diverging field is an edit, and
  the 3 s poll leaves the fields alone until Apply. An `onChange`-based flag
  fires when the poll *fills the fields in*, which froze them on their first
  values and enabled Apply with nothing to apply.
- **Plain `http` to the server is deliberate.** `NSAppTransportSecurity`
  allows arbitrary loads because Transmission's RPC is http and the host is a
  LAN name or tailnet name, which ATS would otherwise refuse. The
  `NSLocalNetworkUsageDescription` key is what lets iOS show the local-network
  prompt on the first poll; unlike macOS no Bonjour trick is needed, the
  URLSession request itself triggers it.
- **Debug screens.** Debug builds honour launch arguments so screens can be
  captured with `simctl` instead of tapping:
  `-debugScreen stats|settings|detail|detail:<info|files|peers|trackers|options>`
  (detail opens the largest torrent once the first poll lands) and
  `-debugMagnet '<magnet link>'` (feeds a link in as if the system had opened
  it, skipping iOS's "Open in Torrent Flinger?" confirmation that `simctl
  openurl` can't answer). Screenshot with `xcrun simctl io booted screenshot`.
  Both are `#if DEBUG` and no-ops in release.
- **Seeding the simulator with a real config**: copy the Mac's `config.json`
  into the app container —
  `xcrun simctl get_app_container booted com.python21.TorrentFlingerPhone data`
  → `Library/Application Support/torrent-flinger/config.json` — and relaunch.
  The simulator shares the Mac's network (and its Tailscale), so the app then
  talks to the real server. Read-only polling is harmless; be deliberate with
  anything that mutates.
- **The icon is generated**, not drawn by hand: `make-icon.swift` transcribes
  the shared tray magnet (`../linux/flinger/assets/tray-idle.svg`) onto a
  gradient at 1024 px. If the tray artwork changes shape, update both.
