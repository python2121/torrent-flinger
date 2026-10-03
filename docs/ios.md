# The iPhone build (`ios/`)

A SwiftUI iPhone app that links the Mac app's `TorrentFlingerCore` library and
puts a phone-shaped shell on it. Not a reduced viewer: everything the Mac app
does *to the server* the phone does too. What it drops is everything that
needs a menu bar or a background process.

Two documents already cover part of this ground and are the ones to keep
current:

- [`ios/CLAUDE.md`](../ios/CLAUDE.md) — build/run commands and the gotchas
  (device installs via Xcode only, the imported `.torrent` UTI, the add-sheet
  binding, by-value edit tracking).
- [`macos/FEATURE_MAP.md`](../macos/FEATURE_MAP.md) — the Core section
  catalogues the shared layer the phone is built on.

This page is the evaluation and the structural map: what ported, what
didn't, why, and where each piece lives.

```bash
cd ios
./build.sh                    # simulator build
./build.sh run detail:files   # install + launch on the booted simulator, on a screen
open TorrentFlingerPhone.xcodeproj   # device: pick your team under Signing, Run
```

## Why this port was easy

The Movie Stats phone app next door had to invent a snapshot pipeline because
the phone couldn't do the real work (no `Process`, no SMB crawling). Torrent
Flinger's real work is HTTP JSON-RPC, which a phone does natively, and the
Mac app already kept its AppKit-free layer in its own directory. So the port
was: turn that directory into a library target (`public`, `Sendable`, one
`#if os(macOS)`), write about 2,100 lines of SwiftUI, and declare two things
in `Info.plist`.

## What ported

| Mac | Phone | Notes |
|---|---|---|
| Popover list, grouped by status, search | `TorrentListView` | Same `Torrent.grouped`; sections are `List` sections with counts. Pull to refresh. |
| Row: badge, name, subtitle, progress bar | `TorrentRowView` | Same subtitle rules (speeds · % · ETA; error string; size + ratio once done). The name is shortened from the end with its extension kept (`…mkv`) by the shared `Format.truncateName`, drawn with a `UILabel` so the measurement and the drawing agree — see `ios/CLAUDE.md`. |
| Row primary action, context menu, ⇧/⌘-click selection | Swipe actions + **Select** mode | Leading swipe pauses/resumes, trailing removes (with the delete-data choice). Select mode gives a bottom bar with Resume / Pause / Remove for the selection, in visual order. |
| Details window: Info / Files / Peers / Trackers / Options | `TorrentDetailView` | A segmented control over five lists. The Files tab is `List(children:)` over the same `FileNode.tree`, with the folder-level checkbox and a long-press menu for priority. |
| Details action bar | Toolbar menu | Pause/Resume, Verify, Reannounce, Set location (a sheet), Copy / Share magnet, Remove. |
| Add dialog | `AddTorrentSheet` | Server default + custom folders as an inline picker, free space for the choice, TV detection pre-selecting the flagged folder with its reason, add-paused. |
| Options: Server / General / Download tabs | `SettingsView` | One Form. Draft + Save so typing a host doesn't rebuild the client per keystroke. Download folders are tapped to edit (one add-or-edit sheet, `FolderSheet`, with Remove when editing). Also the first-run screen. |
| Options: Limits tab | `LimitsView` | Same `session-get` keys, disabled until loaded, Apply writes `session-set`. |
| Statistics window | `StatsView` | Plus the live figures (speeds, counts, free space, server version). |
| Start all / Pause all / web UI | List toolbar menu | Web UI opens in Safari. The same menu pushes Statistics and Settings — there is no tab bar; the list is the whole root. |
| Clipboard magnet offer | **Paste magnet link** in the add menu | iOS shows a paste banner on read, so it's a deliberate action rather than an offer on open. |
| magnet: handler | `CFBundleURLTypes` scheme | Safari asks "Open in Torrent Flinger?", then the add sheet opens. |
| .torrent handler | `CFBundleDocumentTypes` + imported UTI | Share sheet / Files → the add sheet, with the file read immediately and the Inbox copy deleted. |
| Finish notifications | A toast, if the app is open | See below. |
| `config.json` | Same file, imported | Settings → **Import config.json** reads the Mac's file; the password moves to the Keychain. |

## What didn't, and why

- **Menu-bar speed readout, tray icon, `SpeedAverager`.** No status surface on
  a phone. A Home Screen widget refreshes every quarter hour at best and a Live
  Activity can't be updated once the app is backgrounded, so neither is an
  honest substitute for a number that changes every second. The list footer
  shows the aggregate speeds while the app is open; that's the whole story.
- **Background polling and "download complete" notifications.** iOS gives a
  personal app no reliable background schedule. The store polls only while the
  scene is `.active`, and a torrent that finishes while the app is open shows a
  toast. Nothing fires while it's closed — the list is simply fresh when you
  come back.
- **Reveal in Finder, the Local tab, remote→local path mapping.** No meaning
  on a phone. `mount_remote` / `mount_local` are still read and written so an
  imported file round-trips, but nothing uses them.
- **Keyboard navigation and `Selection.swift`.** Desktop-shaped; iOS's own
  edit mode covers multi-select.
- **Single-instance lock, Bonjour permission trick.** iOS runs one instance
  and prompts for local-network access on the first LAN request by itself.
  The `NSLocalNetworkUsageDescription` key and the ATS exemption for plain
  `http` are still required.

## Shape

```
ios/
  TorrentFlingerPhone.xcodeproj     hand-written; local package reference to ../macos
  TorrentFlingerPhone/
    App/      PhoneStore (the hub), PhoneConfig (+ Keychain), app entry
    Views/    one file per screen, Components.swift for the shared primitives
    Assets.xcassets, Info.plist
  build.sh                          simulator build (+ run)
  make-icon.swift                   renders the icon from the shared tray magnet
```

`PhoneStore` is the counterpart of the Mac's `TorrentStore`: `@Observable`,
`@MainActor`, owns the `Config`, the `TransmissionClient`, the poll loop, every
mutating action (each re-polls on success and surfaces failure as a toast),
the queue of pending adds, and the toast itself. Views read it from the
environment. `DetailModel` is the per-screen counterpart of
`DetailsViewModel`, refreshing every 3 s via the view's `.task`.

## Off the LAN

The server is a NAS. The phone is wherever you are. The app does nothing
special about this: with Tailscale on both ends, the host is the server's
tailnet name and it resolves on the couch and on cellular alike. That's the
intended setup, and why there's no VPN-ish code in here.

## Settings and secrets

The same `Config` as the desktops, saved by the same `Config.save` into the
app's own Application Support. The password is the exception: it goes to the
Keychain, and the file on disk carries an empty one. A freshly imported Mac
file *does* carry the password; it's honoured and migrated on the next save.
`UIFileSharingEnabled` is on so a `config.json` can also be dropped into the
app's Documents from Finder, for the simulator or a one-off.
