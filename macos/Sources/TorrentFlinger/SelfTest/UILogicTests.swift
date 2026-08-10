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
