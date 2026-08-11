#if DEBUG
import Foundation

/// The pure logic behind the popover list and the options window: grouping +
/// search, list selection arithmetic, and the custom-directory rules. These
/// live in `Core` precisely so they can be exercised without standing up a
/// `TorrentStore` (which would start a poll timer and hit the network).
enum UILogicTests {
    /// Build a torrent with just the fields the grouping rules read.
    private static func torrent(_ id: Int, _ name: String,
                                status: Int = TorrentStatus.downloading,
                                percentDone: Double = 0.5,
                                error: String = "") -> Torrent {
        var t = Torrent()
        t.id = id
        t.name = name
        t.status = status
        t.percentDone = percentDone
        t.errorString = error
        return t
    }

    /// `flinger/assets` — the icon set both builds share — found by walking up
    /// from the working directory, so it resolves whether the suite is run
    /// from `macos/` (via test.sh) or the repo root.
    private static func sharedAssetsDirectory() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("flinger/assets")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static let all: [TestEntry] = [
        TestEntry("grouping/order-and-membership") { t in
            let torrents = [
                torrent(1, "seeding one", status: TorrentStatus.seeding, percentDone: 1),
                torrent(2, "downloading one"),
                torrent(3, "broken one", error: "tracker gone"),
                torrent(4, "paused one", status: TorrentStatus.stopped, percentDone: 0.3),
            ]
            let groups = Torrent.grouped(torrents)
            // Errors first — they're the only ones that need the user.
            t.equal(groups.map(\.name), ["Error", "Downloading", "Seeding", "Paused"])
            t.equal(groups.first?.torrents.map(\.id), [3])
            t.equal(groups.last?.torrents.map(\.id), [4])
        },

        TestEntry("grouping/omits-empty-groups") { t in
            let groups = Torrent.grouped([torrent(1, "only one")])
            t.equal(groups.count, 1, "a group with no torrents must not render a header")
            t.equal(groups.first?.name, "Downloading")
            t.equal(Torrent.grouped([]).count, 0)
        },

        TestEntry("grouping/preserves-server-order-within-a-group") { t in
            // Transmission's own ordering is meaningful (queue position); the
            // popover must not re-sort inside a section.
            let torrents = [torrent(7, "seven"), torrent(3, "three"), torrent(9, "nine")]
            t.equal(Torrent.grouped(torrents).first?.torrents.map(\.id), [7, 3, 9])
        },

        TestEntry("grouping/search-is-case-and-space-insensitive") { t in
            let torrents = [torrent(1, "The.Bear.S03E05"), torrent(2, "Oppenheimer.2023")]
            t.equal(Torrent.grouped(torrents, matching: "bear").first?.torrents.map(\.id), [1])
            t.equal(Torrent.grouped(torrents, matching: "BEAR").first?.torrents.map(\.id), [1],
                    "search must be case-insensitive")
            t.equal(Torrent.grouped(torrents, matching: "  bear  ").first?.torrents.map(\.id), [1],
                    "surrounding whitespace must not defeat the match")
            t.equal(Torrent.grouped(torrents, matching: "   ").count, 1,
                    "whitespace-only search is an empty search, not a filter that matches nothing")
            t.equal(Torrent.grouped(torrents, matching: "zzz").count, 0)
        },

        TestEntry("selection/plain-click-replaces") { t in
            let result = Selection.apply(.replace, to: 2, current: [1, 3], anchor: 1, order: [1, 2, 3])
            t.equal(result.selection, [2])
            t.equal(result.anchor, 2)
        },

        TestEntry("selection/command-click-toggles") { t in
            var result = Selection.apply(.toggle, to: 2, current: [1], anchor: 1, order: [1, 2, 3])
            t.equal(result.selection, [1, 2])
            t.equal(result.anchor, 2)
            // Toggling the same row again removes it, without clearing the rest.
            result = Selection.apply(.toggle, to: 2, current: [1, 2], anchor: 2, order: [1, 2, 3])
            t.equal(result.selection, [1])
        },

        TestEntry("selection/shift-click-extends-in-visual-order") { t in
            // The order here is deliberately not sorted by id: grouping means
            // visual order and id order differ, and the range must follow what
            // the user sees.
            let order = [5, 1, 4, 2, 3]
            let down = Selection.apply(.extend, to: 2, current: [5], anchor: 5, order: order)
            t.equal(down.selection, [5, 1, 4, 2])
            t.equal(down.anchor, 5, "the anchor stays put so the range can be resized")

            // Dragging back the other way selects the same span, not a new one.
            let up = Selection.apply(.extend, to: 5, current: [], anchor: 2, order: order)
            t.equal(up.selection, [5, 1, 4, 2])
        },

        TestEntry("selection/shift-click-without-a-usable-anchor") { t in
            // No anchor yet, or an anchor whose row has since been removed:
            // degrade to a plain click rather than selecting nothing.
            t.equal(Selection.apply(.extend, to: 3, current: [], anchor: nil, order: [1, 2, 3]).selection,
                    [3])
            t.equal(Selection.apply(.extend, to: 3, current: [], anchor: 99, order: [1, 2, 3]).selection,
                    [3], "a stale anchor must not wipe the click")
            t.equal(Selection.apply(.extend, to: 99, current: [1], anchor: 1, order: [1, 2, 3]).selection,
                    [99], "clicking a row that isn't in the order still selects it")
        },

        TestEntry("selection/escape-peels-one-layer-per-press") { t in
            // Selection outranks the search field, so a filtered multi-select
            // takes three presses to get from "busy" to "closed".
            t.equal(Selection.escape(hasSelection: true, hasSearch: true), .clearSelection)
            t.equal(Selection.escape(hasSelection: true, hasSearch: false), .clearSelection)
            t.equal(Selection.escape(hasSelection: false, hasSearch: true), .clearSearch)
            t.equal(Selection.escape(hasSelection: false, hasSearch: false), .close,
                    "nothing left to clear → the panel closes")
        },

        TestEntry("selection/arrow-keys-walk-the-visual-order") { t in
            // Again deliberately not id-sorted: arrows follow what's on screen.
            let order = [5, 1, 4, 2, 3]
            t.equal(Selection.step(1, current: [1], cursor: 1, order: order), 4)
            t.equal(Selection.step(-1, current: [1], cursor: 1, order: order), 5)

            // Nothing selected yet: Down starts at the top, Up at the bottom.
            t.equal(Selection.step(1, current: [], cursor: nil, order: order), 5)
            t.equal(Selection.step(-1, current: [], cursor: nil, order: order), 3)

            // The ends clamp instead of wrapping.
            t.equal(Selection.step(-1, current: [5], cursor: 5, order: order), 5)
            t.equal(Selection.step(1, current: [3], cursor: 3, order: order), 3)

            // A stale cursor (its row filtered away) resumes from the last
            // still-visible selected row rather than jumping to the top.
            t.equal(Selection.step(1, current: [1, 4], cursor: 99, order: order), 2)
            t.equal(Selection.step(1, current: [], cursor: nil, order: []), nil,
                    "an empty list has nowhere to move")
        },

        TestEntry("selection/shift-arrow-grows-and-shrinks-one-range") { t in
            // What the store does per ⇧-arrow: step the cursor, then apply the
            // landing row as an extend. The anchor never moves, so reversing
            // direction shrinks the range instead of starting a second one.
            let order = [5, 1, 4, 2, 3]
            var selection: Set<Int> = [1]
            var anchor: Int? = 1
            var cursor: Int? = 1

            func shiftArrow(_ direction: Int) {
                guard let landing = Selection.step(direction, current: selection,
                                                   cursor: cursor, order: order) else { return }
                let result = Selection.apply(.extend, to: landing, current: selection,
                                             anchor: anchor, order: order)
                selection = result.selection
                anchor = result.anchor
                cursor = landing
            }

            shiftArrow(1)
            t.equal(selection, [1, 4])
            shiftArrow(1)
            t.equal(selection, [1, 4, 2], "the cursor moves, so the range keeps growing")
            t.equal(anchor, 1, "the anchor stays where the selection started")

            shiftArrow(-1)
            t.equal(selection, [1, 4], "reversing shrinks the same range")
            shiftArrow(-1)
            t.equal(selection, [1])
            shiftArrow(-1)
            t.equal(selection, [5, 1], "and past the anchor it grows the other way")

            // At the top edge it clamps, leaving the range as-is.
            shiftArrow(-1)
            t.equal(selection, [5, 1])
        },

        TestEntry("tray-icon/state-precedence") { t in
            // A fresh add is a notification, not a status, so it outranks
            // everything for its three seconds — including a failed server.
            t.equal(TrayIcon.current(connected: true, downloadSpeed: 0, recentlyAdded: true), .added)
            t.equal(TrayIcon.current(connected: false, downloadSpeed: 0, recentlyAdded: true), .added)
            t.equal(TrayIcon.current(connected: true, downloadSpeed: 9000, recentlyAdded: true), .added)

            t.equal(TrayIcon.current(connected: false, downloadSpeed: 0, recentlyAdded: false), .error)
            t.equal(TrayIcon.current(connected: false, downloadSpeed: 9000, recentlyAdded: false), .error,
                    "a stale speed from the last good poll must not mask a disconnect")

            t.equal(TrayIcon.current(connected: true, downloadSpeed: 1, recentlyAdded: false), .downloading)
            t.equal(TrayIcon.current(connected: true, downloadSpeed: 0, recentlyAdded: false), .idle)
        },

        TestEntry("tray-icon/download-arrow-yields-to-the-speed-readout") { t in
            // macOS only: while downloading the arrow just repeats what "↓1.2M"
            // already says, so the numbers stand alone.
            t.equal(TrayIcon.downloading.showsGlyph(speedsVisible: true), false)

            // …but only when there are numbers to stand in for it. With speeds
            // switched off in Options, dropping the glyph would leave the
            // status item completely empty.
            t.equal(TrayIcon.downloading.showsGlyph(speedsVisible: false), true)

            // Every other state keeps its glyph either way — they carry
            // information the speed text doesn't.
            for icon in TrayIcon.allCases where icon != .downloading {
                t.equal(icon.showsGlyph(speedsVisible: true), true,
                        "\(icon.rawValue) must stay visible alongside the speeds")
                t.equal(icon.showsGlyph(speedsVisible: false), true)
            }
        },

        TestEntry("tray-icon/seeding-only-is-idle-not-downloading") { t in
            // The glyph is a down arrow; showing it while only uploading would
            // be a lie, so upload activity deliberately doesn't reach it.
            t.equal(TrayIcon.current(connected: true, downloadSpeed: 0, recentlyAdded: false), .idle)
        },

        TestEntry("tray-icon/assets-exist-for-every-state") { t in
            // A missing file silently falls back to an SF Symbol, so without
            // this the artwork could go absent and only show up by eye.
            // SwiftPM compiles with remapped, relative #filePath, so the
            // source location can't locate the repo — walk up from the working
            // directory instead.
            guard let dir = Self.sharedAssetsDirectory() else {
                return t.fail("couldn't locate flinger/assets from \(FileManager.default.currentDirectoryPath)")
            }
            for icon in TrayIcon.allCases {
                let svg = dir.appendingPathComponent("\(icon.assetName).svg")
                t.expect(FileManager.default.fileExists(atPath: svg.path),
                         "missing shared asset \(icon.assetName).svg")
                t.expect(!icon.fallbackSymbol.isEmpty, "every state needs a dev-loop fallback")
            }
            t.equal(TrayIcon.allCases.count, 4)
            t.equal(TrayIcon.addedDuration, 3, "must match ADDED_DURATION_S on the Linux side")
        },

        TestEntry("custom-dirs/tv-flag-is-exclusive") { t in
            let dirs = [CustomDir(label: "TV", dir: "/data/tv"),
                        CustomDir(label: "Movies", dir: "/data/movies"),
                        CustomDir(label: "Other", dir: "/data/other", tv: true)]
            let marked = CustomDir.markingTV("/data/tv", in: dirs)
            t.equal(marked.filter(\.tv).map(\.dir), ["/data/tv"],
                    "marking one must clear the previously flagged entry")
            // findTVDir returns the *first* flagged entry, so two flags would
            // make the add dialog's destination depend on list order.
            t.equal(TVDetect.findTVDir(marked), "/data/tv")

            let cleared = CustomDir.markingTV(nil, in: dirs)
            t.equal(cleared.filter(\.tv).count, 0)
            t.isNil(TVDetect.findTVDir(cleared))
        },

        TestEntry("custom-dirs/make-trims-and-defaults-the-label") { t in
            let unlabelled = CustomDir.make(label: "  ", dir: " /data/tv ", tv: false)
            t.equal(unlabelled?.label, "tv", "an empty label falls back to the folder name")
            t.equal(unlabelled?.dir, "/data/tv", "the path is trimmed")

            let labelled = CustomDir.make(label: " Shows ", dir: "/data/tv", tv: true)
            t.equal(labelled?.label, "Shows")
            t.equal(labelled?.tv, true)

            t.isNil(CustomDir.make(label: "x", dir: "   ", tv: false),
                    "a blank path yields no entry rather than an unusable one")
        },
    ]
}
#endif
