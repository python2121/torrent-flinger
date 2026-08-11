#if DEBUG
import Foundation

/// The Files tab's tree: folding Transmission's flat path list into
/// directories, the aggregates each folder row shows, and resolving a
/// selection of rows back to the file indices an RPC call takes.
enum FileTreeTests {
    private static func file(_ name: String, _ length: Int64) -> TorrentFile {
        TorrentFile(name: name, length: length)
    }

    private static func stat(_ completed: Int64, wanted: Bool = true, priority: Int = 0) -> TorrentFileStats {
        var s = TorrentFileStats()
        s.bytesCompleted = completed
        s.wanted = wanted
        s.priority = priority
        return s
    }

    /// `Season 1/ep1.mkv`, `Season 1/subs/ep1.srt`, `readme.txt`.
    private static let sample = [
        file("Show/Season 1/ep1.mkv", 1000),
        file("Show/Season 1/subs/ep1.srt", 10),
        file("Show/readme.txt", 100),
    ]

    static let all: [TestEntry] = [
        TestEntry("filetree/folds-paths-into-directories") { t in
            let tree = FileNode.tree(files: sample, stats: [stat(1000), stat(10), stat(100)])
            t.equal(tree.count, 1, "one root: every file shares the torrent's top folder")
            let show = tree[0]
            t.equal(show.name, "Show")
            t.equal(show.isDirectory, true)
            // A directory appears where its first file did, so the tree reads
            // in the order the server listed the files.
            t.equal(show.children?.map(\.name), ["Season 1", "readme.txt"])
            let season = show.children?[0]
            t.equal(season?.children?.map(\.name), ["ep1.mkv", "subs"])
            t.equal(season?.children?[1].children?.map(\.name), ["ep1.srt"])
            t.equal(show.children?[1].isDirectory, false, "a file has no children, so no triangle")
        },

        TestEntry("filetree/directories-aggregate-their-subtree") { t in
            let tree = FileNode.tree(files: sample, stats: [stat(500), stat(10), stat(0)])
            let show = tree[0]
            t.equal(show.length, 1110)
            t.equal(show.completed, 510)
            t.equal(show.donePercent, "46%")
            t.equal(show.indices, [0, 1, 2], "checking a folder acts on every file under it")
            t.equal(show.children?[0].indices, [0, 1])
            t.equal(show.children?[0].length, 1010)
        },

        TestEntry("filetree/wanted-is-tri-state") { t in
            let allOn = FileNode.tree(files: sample, stats: [stat(0), stat(0), stat(0)])
            t.equal(allOn[0].wanted, .on)

            let allOff = FileNode.tree(files: sample,
                                       stats: [stat(0, wanted: false), stat(0, wanted: false),
                                               stat(0, wanted: false)])
            t.equal(allOff[0].wanted, .off)

            let some = FileNode.tree(files: sample,
                                     stats: [stat(0), stat(0, wanted: false), stat(0, wanted: false)])
            t.equal(some[0].wanted, .mixed, "the root disagrees with itself")
            t.equal(some[0].children?[0].wanted, .mixed, "…and so does Season 1")
            t.equal(some[0].children?[1].wanted, .off, "readme.txt alone is unambiguous")

            // A click on anything not fully checked checks it, which is the
            // only way out of mixed with one gesture.
            t.equal(FileNode.Wanted.mixed.toggled, true)
            t.equal(FileNode.Wanted.off.toggled, true)
            t.equal(FileNode.Wanted.on.toggled, false)
        },

        TestEntry("filetree/priority-is-nil-when-the-subtree-disagrees") { t in
            let same = FileNode.tree(files: sample,
                                     stats: [stat(0, priority: 1), stat(0, priority: 1),
                                             stat(0, priority: 1)])
            t.equal(same[0].priority, 1)

            let mixed = FileNode.tree(files: sample,
                                      stats: [stat(0, priority: 1), stat(0), stat(0)])
            t.isNil(mixed[0].priority, "the folder row has no single priority to show")
            t.equal(mixed[0].children?[1].priority, 0, "a file always has one")
        },

        TestEntry("filetree/selection-resolves-to-file-indices") { t in
            let tree = FileNode.tree(files: sample, stats: [stat(0), stat(0), stat(0)])
            let show = tree[0]
            let season = show.children![0]
            let readme = show.children![1]

            t.equal(FileNode.indices(for: [readme.id], in: tree), [2])
            t.equal(FileNode.indices(for: [season.id], in: tree), [0, 1],
                    "a folder stands for its whole subtree")
            // Selecting a folder and a file inside it must not send that file
            // twice — Transmission would take it, but the count in a
            // confirmation would lie.
            t.equal(FileNode.indices(for: [season.id, season.children![0].id], in: tree), [0, 1])
            t.equal(FileNode.indices(for: [], in: tree), [])
            t.equal(FileNode.indices(for: ["nonexistent"], in: tree), [])
        },

        TestEntry("filetree/single-file-torrents-and-short-filestats") { t in
            // No directory component: one row, no triangle — the common case
            // for a movie.
            let flat = FileNode.tree(files: [file("Movie.2026.mkv", 42)], stats: [stat(42)])
            t.equal(flat.count, 1)
            t.equal(flat[0].isDirectory, false)
            t.equal(flat[0].name, "Movie.2026.mkv")
            t.equal(flat[0].indices, [0])

            // Some servers send fewer fileStats than files mid-metadata-fetch;
            // the missing ones take the documented defaults rather than
            // dropping the rows.
            let short = FileNode.tree(files: sample, stats: [stat(1000)])
            t.equal(short[0].indices.count, 3)
            t.equal(short[0].wanted, .on)
            t.equal(short[0].completed, 1000)

            t.equal(FileNode.tree(files: [], stats: []).count, 0)
        },

        TestEntry("filetree/ids-are-stable-and-unique") { t in
            let stats = [stat(0), stat(0), stat(0)]
            let first = FileNode.tree(files: sample, stats: stats)
            let second = FileNode.tree(files: sample, stats: [stat(1), stat(1), stat(1)])
            // Refreshes rebuild the tree every few seconds; the ids have to
            // survive that or the outline would collapse under the user.
            t.equal(first[0].id, second[0].id)
            t.equal(first[0].children?.map(\.id), second[0].children?.map(\.id))

            // A torrent that lists the same path twice still gets two rows.
            let duplicated = FileNode.tree(files: [file("a/x.bin", 1), file("a/x.bin", 1)],
                                           stats: [stat(0), stat(0)])
            let ids = duplicated[0].children?.map(\.id) ?? []
            t.equal(ids.count, 2)
            t.equal(Set(ids).count, 2, "duplicate paths must not collapse into one row")
        },
    ]
}
#endif
