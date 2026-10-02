#if DEBUG
import Foundation
@testable import TorrentFlingerCore

/// Formatting, path mapping and TV detection — kept assertion-for-assertion in
/// step with the Python suite (`tests/test_core.py`), so the Linux and macOS
/// builds can't drift apart in what they display or where they reveal files.
enum FormatTests {
    static let all: [TestEntry] = [
        TestEntry("format/sizes") { t in
            // Both overloads: the UI passes Int64 byte counts, the recursion
            // works in Double.
            t.equal(Format.size(Int64(500)), "500 B")
            t.equal(Format.size(Int64(1500)), "1.5 KB")
            t.equal(Format.size(Int64(2_500_000_000)), "2.5 GB")
            t.equal(Format.size(Int64(0)), "0 B")
            t.equal(Format.size(Int64(1_500_000_000_000_000)), "1.5 PB")
            t.equal(Format.size(1500.0), "1.5 KB")
            t.equal(Format.speed(Int(1_200_000)), "1.2 MB/s")
            t.equal(Format.speed(1_200_000.0), "1.2 MB/s")
        },

        TestEntry("format/menubar-short-speeds") { t in
            t.equal(Format.speedShort(0), "", "zero renders as nothing, not \"0\"")
            t.equal(Format.speedShort(512), "512")
            t.equal(Format.speedShort(1_200), "1.2K")
            t.equal(Format.speedShort(1_200_000), "1.2M")
            t.equal(Format.speedShort(24_000_000), "24M")
        },

        TestEntry("format/eta") { t in
            t.equal(Format.eta(-1), "", "-1 means \"unknown\", not \"-1s\"")
            t.equal(Format.eta(nil), "")
            t.equal(Format.eta(45), "45s")
            t.equal(Format.eta(3900), "1h 5m")
            t.equal(Format.eta(90000), "1d 1h")
            t.equal(Format.eta(0), "0s")
        },

        TestEntry("format/status-names") { t in
            t.equal(Format.statusName(0), "Paused")
            t.equal(Format.statusName(4), "Downloading")
            t.equal(Format.statusName(6), "Seeding")
            t.equal(Format.statusName(42), "Unknown (42)")
        },

        TestEntry("format/dates") { t in
            t.equal(Format.date(nil), "—")
            t.equal(Format.date(0), "—")
            t.equal(Format.date(-5), "—")
            t.expect(!Format.date(1_700_000_000).isEmpty, "a real epoch should format")
        },

        TestEntry("format/map-remote-path") { t in
            t.equal(Format.mapRemotePath("/data/torrents/tv",
                                         remotePrefix: "/data/torrents",
                                         localPrefix: "/run/media/nas"),
                    "/run/media/nas/tv")
            t.equal(Format.mapRemotePath("/data/torrents",
                                         remotePrefix: "/data/torrents",
                                         localPrefix: "/run/media/nas"),
                    "/run/media/nas")
            t.equal(Format.mapRemotePath("/data/torrents/",
                                         remotePrefix: "/data/torrents",
                                         localPrefix: "/run/media/nas/"),
                    "/run/media/nas")
            t.isNil(Format.mapRemotePath("/other/place",
                                         remotePrefix: "/data/torrents",
                                         localPrefix: "/mnt"))
            // Prefix match must be on path components, not raw string prefixes.
            t.isNil(Format.mapRemotePath("/data/torrents2/x",
                                         remotePrefix: "/data/torrents",
                                         localPrefix: "/mnt"),
                    "\"/data/torrents2\" is not under \"/data/torrents\"")
            t.isNil(Format.mapRemotePath("/data/x", remotePrefix: "", localPrefix: "/mnt"))
            t.isNil(Format.mapRemotePath("/data/x", remotePrefix: "/data", localPrefix: ""))
        },

        TestEntry("format/common-remote-root") { t in
            t.equal(Format.commonRemoteRoot(["/data/complete", "/data/tv"]), "/data")
            t.equal(Format.commonRemoteRoot(["/data/torrents"]), "/data/torrents")
            t.isNil(Format.commonRemoteRoot(["/data/tv", "/mnt/other"]),
                    "only \"/\" in common is no usable prefix")
            t.isNil(Format.commonRemoteRoot([]))
            t.isNil(Format.commonRemoteRoot(["", "relative/path"]))
            t.equal(Format.commonRemoteRoot(["/data/tv/", "/data/tv"]), "/data/tv")
        },

        TestEntry("format/resolve-local-path") { t in
            // The real scenario: movies in the default /data/complete, TV in a
            // custom /data/tv, share root /data mounted at /mnt/nas.
            let tree: Set<String> = ["/mnt/nas", "/mnt/nas/complete", "/mnt/nas/complete/MovieX",
                                     "/mnt/nas/tv", "/mnt/nas/tv/ShowY"]
            let exists: (String) -> Bool = { tree.contains($0) }

            t.equal(Format.resolveLocalPath(remoteDir: "/data/complete/MovieX",
                                            remotePrefix: "/data", localPrefix: "/mnt/nas",
                                            exists: exists),
                    "/mnt/nas/complete/MovieX")
            t.equal(Format.resolveLocalPath(remoteDir: "/data/tv",
                                            remotePrefix: "/data", localPrefix: "/mnt/nas",
                                            exists: exists),
                    "/mnt/nas/tv")
            t.equal(Format.resolveLocalPath(remoteDir: "/data/tv/ShowY",
                                            remotePrefix: "/data/complete",
                                            localPrefix: "/mnt/nas", exists: exists),
                    "/mnt/nas/tv/ShowY",
                    "wrong prefix → suffix probing finds the alignment anyway")
            t.equal(Format.resolveLocalPath(remoteDir: "/srv/deep/data/tv",
                                            remotePrefix: "", localPrefix: "/mnt/nas",
                                            exists: exists),
                    "/mnt/nas/tv", "longest existing suffix wins")
            t.isNil(Format.resolveLocalPath(remoteDir: "/data/other",
                                            remotePrefix: "/data", localPrefix: "/mnt/nas",
                                            exists: exists),
                    "nothing exists locally → no reveal")
            t.isNil(Format.resolveLocalPath(remoteDir: "/data/tv",
                                            remotePrefix: "/data", localPrefix: "/mnt/gone",
                                            exists: { _ in false }),
                    "a mapped path must exist; it is never invented")
        },

        TestEntry("format/link-display-names") { t in
            t.equal(Format.linkDisplayName("magnet:?xt=urn:btih:x&dn=My+File"), "My File")
            t.equal(Format.linkDisplayName("/tmp/some%20file.torrent"), "some file.torrent")
            t.equal(Format.linkDisplayName("magnet:?xt=urn:btih:x"), "(magnet link)")
            t.equal(Format.linkDisplayName("magnet:"), "(magnet link)")
        },

        TestEntry("tvdetect/positives") { t in
            let cases: [(String, TVDetect.Reason)] = [
                // Episode markers — the workhorse signal.
                ("The.Bear.S03E05.1080p.WEB.h264-ETHEL", .episode),
                ("shogun.s01e09.720p.hdtv.x264", .episode),
                ("The Wire 3x07 Back Burners", .episode),
                ("Severance.S2E1.2160p.ATVP.WEB-DL", .episode),
                ("Unknown.Obscure.Show.S01E01.480p", .episode),   // no title list needed
                // Air-date naming (daily shows).
                ("Last.Week.Tonight.2026.08.03.1080p.WEB", .airDate),
                ("The.Daily.Show.2026-01-15.720p.HEVC", .airDate),
                // Season packs.
                ("True.Detective.S04.2160p.WEB.COMPLETE", .season),
                ("Andor.Season.2.1080p.DSNP.WEB-DL", .season),
                ("Chernobyl.Complete.Series.1080p.BluRay", .season),
                ("Band.of.Brothers.Mini-Series.720p", .season),
                ("The.Sopranos.Seasons.1-6.DVDRip", .season),
            ]
            for (name, expected) in cases {
                let (isTV, reason) = TVDetect.looksLikeTV(name)
                t.expect(isTV, "missed TV: \(name)")
                t.equal(reason, expected, name)
            }
        },

        TestEntry("tvdetect/movie-negatives") { t in
            let names = [
                "Oppenheimer.2023.1080p.BluRay.x264-GROUP",
                "Fargo.1996.REMASTERED.1080p.BluRay",     // movie/show name collision
                "Watchmen.2009.Ultimate.Cut.2160p",
                "Friends.with.Benefits.2011.720p",        // contains a show title
                "1917.2019.2160p.HDR.REMUX",
                "2001.A.Space.Odyssey.1968.1080p",
                "Dune.Part.Two.2024.HDR.2160p",
                "Inception.1080p.BluRay.x264",
                "James.Bond.Complete.Collection.1080p",   // pack words alone don't count
                "Se7en.1995.720p",
                "Gladiator",
                // Bare show names without markers are intentionally NOT detected:
                // marker-free packs are rare and title matching wasn't worth its
                // false-positive risk.
                "Breaking Bad",
                "The Wire Complete 1080p",
            ]
            for name in names {
                let (isTV, reason) = TVDetect.looksLikeTV(name)
                t.expect(!isTV, "false positive: \(name) (\(reason?.rawValue ?? ""))")
            }
        },

        TestEntry("tvdetect/find-tv-dir") { t in
            // The explicit flag decides — labels and paths don't.
            let dirs = [CustomDir(label: "movies", dir: "/downloads/movies"),
                        CustomDir(label: "junk drawer", dir: "/downloads/tv", tv: true)]
            t.equal(TVDetect.findTVDir(dirs), "/downloads/tv")
            t.isNil(TVDetect.findTVDir([CustomDir(label: "tv", dir: "/downloads/tv")]),
                    "a \"tv\" label alone is not the flag")
            t.isNil(TVDetect.findTVDir([]))
        },
    ]
}
#endif
