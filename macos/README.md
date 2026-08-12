# Torrent Flinger for macOS

The macOS menu-bar port of [Torrent Flinger](../README.md) — a native-feeling
**viewer and administrator for a remote Transmission server**, plus a
browser-free way to fling magnet links and `.torrent` files at it.

Same app, same feature set, same `config.json`. The Linux build is a PySide6
tray applet styled after KDE Plasma; this one is a Swift/SwiftUI menu-bar
accessory styled after macOS's own Control Center panels. **The Linux app in
the parent directory is untouched and unaffected** — this is a second,
independent build that happens to live in the same repo.

## Install

```bash
./build-app.sh          # swift build -c release + assemble + codesign → ./TorrentFlinger.app
./install.sh            # build, replace /Applications/TorrentFlinger.app, restart
```

First run: click the menu-bar icon → gear → **Options…** → set your server →
**Test Connection**.

`install.sh` re-registers the bundle with LaunchServices, so `magnet:` links
and `.torrent` files can be opened with Torrent Flinger from any browser
(Finder → Get Info → *Open with* to make it the default for `.torrent`;
browsers will offer it for magnet links).

## What it does

**Menu-bar item**: an icon that reflects state (idle / transferring /
disconnected) plus the live aggregate speeds (`↓1.2M ↑45K`), with the torrent
count and full speeds in the tooltip. Left-click opens the panel; right-click
gives the same menu the Linux tray icon has (Show torrents, Add torrent file…,
Add magnet from clipboard, Start all, Pause all, Statistics…, Full web
interface, Options…, Quit).

**Panel** (380pt, borderless `NSPanel` with a vibrant rounded background,
slide-and-fade in, dismissed by an outside click or Escape):

- Header: server connection dot, live search, add menu
- Torrents grouped by status (Error first, then Downloading / Verifying /
  Seeding / Paused / Finished) with per-group counts
- Compact rows: state badge, name, `↓/↑ speed · % · ETA` subtitle, slim
  state-colored progress bar, one-click Pause/Resume/Remove (the ✕ on a
  completed torrent removes straight away, without a confirmation)
- Click the chevron to expand a row in place: quick stats grid plus
  Details / Copy magnet / Reveal in Finder / Remove
- Click to select, ⇧-click for a range, ⌘-click to toggle, ↑/↓ to walk the
  list (scrolling the row into view), ⇧↑/⇧↓ to extend; right-click acts on
  the whole selection — Resume or Pause (only whichever applies to what's
  selected) and Remove, plus, on a single row, Reveal in Finder, Torrent
  files… (straight to the details window's Files tab) and Details…
- Clipboard magnet detection: open the panel with a magnet link copied and it
  offers to add it
- Footer: aggregate speeds, torrent count, **free disk space on the server**,
  and refresh / statistics / web-UI / settings controls

**Details window** per torrent (Info / Files / Peers / Trackers / Options):
sizes, ratio, dates, hash, pieces, privacy; per-file download checkbox and
high/normal/low priority (multi-select, right-click); peer and tracker tables;
per-torrent speed limits, seed-ratio mode, peer limit, queue moves; and
pause/resume, verify, reannounce, set location (with or without moving data),
copy magnet, remove.

**Server administration**: global speed limits, turtle mode (its on/off switch
and its limits) and the default seed ratio — all on the Options → Limits tab,
edited live via `session-set` — and a session-statistics window (current +
cumulative).

**Link handling**: `CFBundleURLTypes` (scheme `magnet`) and
`CFBundleDocumentTypes` (`org.bittorrent.torrent`) route links into the running
app via `application(_:open:)`. The add dialog offers your custom directories,
remembers the last destination, shows free space for the selected directory,
and auto-suggests the TV folder for TV-looking names.

**Reveal in Finder** works the way it does on Linux: tell it where the server's
download share is mounted locally (Options → Local) and rows gain a Reveal
action that selects the torrent's own file/folder in Finder.

## Development

```bash
swift build                    # compile
swift run TorrentFlinger       # dev loop (unsigned, no bundle → no magnet handling)
./test.sh                      # run the self-test suite
./test.sh client/              # …filtered by test-name substring
./build-app.sh                 # release bundle

# Open one window on its own to inspect its layout (debug builds only):
swift run TorrentFlinger --show-window options          # popover|add|details|stats
swift run TorrentFlinger --show-window options:limits   # straight to a tab
```

```
Sources/TorrentFlinger/Core/       Transmission RPC client, config, formatting,
                                   TV detection. AppKit-free, and a direct port
                                   of the Python app's linux/flinger/core.
Sources/TorrentFlinger/            AppKit + SwiftUI: menu-bar item, panel,
                                   expandable rows, details/options/stats/add
                                   windows, single-instance lock.
Sources/TorrentFlinger/SelfTest/   The test suite (debug builds only).
```

### Tests

This machine class (Command Line Tools, no full Xcode) ships **neither XCTest
nor swift-testing**, so there is no `swift test` to run and no third-party
testing package is used. The suite is hand-rolled instead:
`Sources/TorrentFlinger/SelfTest/` holds a ~90-line harness plus 57 test cases
(261 checks) covering formatting, path mapping, TV detection, config
load/save, torrent state classification, list grouping and search, selection
arithmetic, custom-directory rules, and the RPC client against a `URLProtocol`
mock that reproduces Transmission's quirks (the 409 CSRF handshake,
`fileStats[].wanted` as 0/1, kebab-case `peer-limit`) — plus the
URLSession-error mapping, including the blocked-local-network case.

The whole directory is wrapped in `#if DEBUG` and dispatched from
`TorrentFlinger --self-test` before `NSApplication` starts, so a release build
contains none of it (verified: no test symbols in `.build/release`).

The Python core tests upstream are the reference — when a rule changes in one
language, change it in both.

### Code signing

**Ad-hoc signing is the default and is fine.** Rebuilds keep working —
verified across rebuilds with genuinely different executable UUIDs — because
the app re-establishes local network access on every launch (see
`LocalNetwork.swift`). Nothing here depends on a stable code identity: no
Keychain ACL, and a locally built app you run yourself isn't gated by
Gatekeeper.

If you want one anyway, `build-app.sh` uses a certificate named
`Torrent Flinger` automatically, or whatever `SIGN_IDENTITY` names (env or a
gitignored `.env`), and fails loudly if a requested identity silently falls
back to ad-hoc. The only things it buys: a presentable name in *System Settings
→ Login Items* (which shows the certificate's Common Name, not the app's), and
a marginally smoother first poll after a rebuild. Create one via Keychain
Access → Certificate Assistant → Create a Certificate (Self Signed Root, Code
Signing).

### Launching at login

Either add `/Applications/TorrentFlinger.app` to *System Settings → General →
Login Items*, or drop a LaunchAgent at
`~/Library/LaunchAgents/io.github.python2121.TorrentFlinger.plist` — `install.sh`
bootstraps it automatically when that file exists.

## Troubleshooting

**"Disconnected", but the web interface opens fine.** macOS gates connections
to LAN addresses behind the Local Network permission, and reports a blocked
connection as *"The Internet connection appears to be offline"* — so the app
looks broken while the same URL loads in your browser. The app asks for the
permission at launch (see `LocalNetwork.swift`); if it's been denied, re-allow
Torrent Flinger under **System Settings → Privacy & Security → Local Network**.

For anything else, the app logs to the unified log:

```bash
/usr/bin/log show --last 10m --info --style compact \
  --predicate 'subsystem == "io.github.python2121.TorrentFlinger"'
```

(`log` is a zsh builtin — the `/usr/bin/` prefix is required.)

## Differences from the Linux build

Same features, adapted to platform conventions:

| | Linux (PySide6) | macOS (SwiftUI) |
|---|---|---|
| Shell | `QSystemTrayIcon` + `Qt.Tool` popup | `NSStatusItem` + borderless `NSPanel` |
| Theming | QPalette / Breeze | System materials, dynamic colors, SF Symbols |
| Reveal | Dolphin via `FileManager1` D-Bus | Finder via `NSWorkspace` |
| Second launch | forwards the link over a local socket | LaunchServices delivers it to the running app |
| Link registration | `.desktop` MIME types | `CFBundleURLTypes` / `CFBundleDocumentTypes` |
| Speeds | tray tooltip | menu-bar text (toggleable) + tooltip |

`~/Library/Application Support/torrent-flinger/config.json` is shared: the two
builds read and write the same keys, and unknown keys survive a round trip.

## Credits

Feature set and layout inherited from the Linux build (see the
[parent README](../README.md)). The window/panel chrome, build script and
install script follow the pattern established by
[claude-usage](https://github.com/python2121/claude-usage).
