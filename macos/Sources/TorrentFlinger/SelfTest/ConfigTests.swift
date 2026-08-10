#if DEBUG
import Foundation

/// Config load/save, and the decode of torrent-shaped JSON into the state the
/// popover groups and badges torrents by.
enum ConfigTests {
    static let all: [TestEntry] = [
        TestEntry("config/derived-urls") { t in
            var config = Config()
            config.host = "nas"
            config.port = 9091
            t.equal(config.rpcURL, "http://nas:9091/transmission/rpc")
            t.equal(config.webURL, "http://nas:9091/transmission/web/")

            config.scheme = "https"
            config.port = 443
            t.equal(config.rpcURL, "https://nas:443/transmission/rpc")
        },

        TestEntry("config/decodes-the-linux-apps-file") { t in
            // The Linux app writes this exact shape to the same path on macOS;
            // the two must stay interchangeable.
            let json = """
            {
              "protocol": "https", "host": "nas.local", "port": 9092,
              "rpc_path": "/rpc", "web_path": "/web/",
              "username": "me", "password": "s3cret", "verify_tls": false,
              "notify_on_add": false, "notify_on_finish": true,
              "poll_interval_ms": 10000,
              "start_paused": true, "show_add_dialog": false,
              "custom_dirs": [
                {"label": "TV", "dir": "/data/tv", "tv": true},
                {"label": "Movies", "dir": "/data/movies"}
              ],
              "last_download_dir": "/data/tv",
              "mount_remote": "/data", "mount_local": "/Volumes/nas"
            }
            """
            let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            t.equal(config.scheme, "https")
            t.equal(config.host, "nas.local")
            t.equal(config.port, 9092)
            t.equal(config.rpcPath, "/rpc")
            t.equal(config.verifyTLS, false)
            t.equal(config.notifyOnAdd, false)
            t.equal(config.pollIntervalMs, 10000)
            t.equal(config.startPaused, true)
            t.equal(config.showAddDialog, false)
            t.equal(config.customDirs.count, 2)
            t.equal(TVDetect.findTVDir(config.customDirs), "/data/tv")
            t.equal(config.mountLocal, "/Volumes/nas")
            t.equal(config.menubarShowSpeeds, true,
                    "a macOS-only key the Linux app never writes falls back to its default")
        },

        TestEntry("config/unknown-keys-and-bad-types-fall-back") { t in
            let json = #"{"host": "nas", "port": "not-a-number", "future_setting": 42}"#
            let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            t.equal(config.host, "nas")
            t.equal(config.port, 9091, "a bad value yields the default, never a throw")
            t.equal(config.rpcPath, "/transmission/rpc")
        },

        TestEntry("config/custom-dir-omits-false-tv-flag") { t in
            // Python writes `tv` only when true, so a round trip through this
            // app must not churn the file the Linux app reads.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let plain = String(decoding: try encoder.encode(CustomDir(label: "M", dir: "/m")),
                               as: UTF8.self)
            t.equal(plain, #"{"dir":"\/m","label":"M"}"#)

            let flagged = String(decoding: try encoder.encode(CustomDir(label: "T", dir: "/t", tv: true)),
                                 as: UTF8.self)
            t.expect(flagged.contains("\"tv\":true"), "expected a tv flag in \(flagged)")
        },

        TestEntry("config/save-load-round-trip") { t in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flinger-config-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("config.json")
            defer { try? FileManager.default.removeItem(at: dir) }

            var config = Config()
            config.host = "nas"
            config.password = "hunter2"
            config.customDirs = [CustomDir(label: "TV", dir: "/data/tv", tv: true)]
            config.save(to: url)

            t.equal(Config.load(from: url), config)

            // The password lives in this file, so it must be owner-only.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            t.equal(attributes[.posixPermissions] as? NSNumber, 0o600)
        },

        TestEntry("config/missing-file-yields-defaults") { t in
            let missing = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flinger-absent-\(UUID().uuidString).json")
            t.equal(Config.load(from: missing), Config())
        },
    ]
}

/// State classification and grouping — the logic the popover's sections and row
/// badges are built from (`flinger/ui/style.py: torrent_state` plus
/// `TorrentRow.group`).
enum TorrentModelTests {
    private static func torrent(_ json: String) throws -> Torrent {
        try JSONDecoder().decode(Torrent.self, from: Data(json.utf8))
    }

    static let all: [TestEntry] = [
        TestEntry("model/state-classification") { t in
            // An error string wins over everything else.
            t.equal(try torrent(#"{"status":4,"errorString":"tracker gone"}"#).state, .error)
            // Incomplete metadata means we're still resolving the magnet.
            t.equal(try torrent(#"{"status":4,"metadataPercentComplete":0.3}"#).state, .magnetizing)
            // Stopped splits on whether the data is all there.
            t.equal(try torrent(#"{"status":0,"percentDone":1}"#).state, .complete)
            t.equal(try torrent(#"{"status":0,"percentDone":0.4}"#).state, .paused)
            t.equal(try torrent(#"{"status":1}"#).state, .verifying)
            t.equal(try torrent(#"{"status":2}"#).state, .verifying)
            t.equal(try torrent(#"{"status":3}"#).state, .queued)
            t.equal(try torrent(#"{"status":4}"#).state, .downloading)
            t.equal(try torrent(#"{"status":5}"#).state, .seeding)
            t.equal(try torrent(#"{"status":6}"#).state, .seeding)
        },

        TestEntry("model/grouping") { t in
            t.equal(try torrent(#"{"status":4}"#).group, "Downloading")
            t.equal(try torrent(#"{"status":3}"#).group, "Downloading")
            t.equal(try torrent(#"{"status":4,"metadataPercentComplete":0.1}"#).group, "Downloading")
            t.equal(try torrent(#"{"status":2}"#).group, "Verifying")
            t.equal(try torrent(#"{"status":6}"#).group, "Seeding")
            t.equal(try torrent(#"{"status":0,"percentDone":0.2}"#).group, "Paused")
            t.equal(try torrent(#"{"status":0,"percentDone":1}"#).group, "Finished")
            t.equal(try torrent(#"{"status":4,"errorString":"x"}"#).group, "Error")
            // Every group a torrent can report needs a section to live in, or
            // rows would silently vanish from the popover.
            let reachable = Set(Torrent.State.allCases.map { state -> String in
                var sample = Torrent()
                switch state {
                case .error: sample.errorString = "x"
                case .magnetizing: sample.metadataPercentComplete = 0.5
                case .complete: sample.percentDone = 1
                case .paused: sample.status = TorrentStatus.stopped
                case .verifying: sample.status = TorrentStatus.checking
                case .queued: sample.status = TorrentStatus.downloadWait
                case .downloading: sample.status = TorrentStatus.downloading
                case .seeding: sample.status = TorrentStatus.seeding
                }
                return sample.group
            })
            t.expect(Set(Torrent.groupOrder).isSuperset(of: reachable),
                     "groupOrder is missing \(reachable.subtracting(Torrent.groupOrder))")
        },

        TestEntry("model/display-fraction-follows-metadata") { t in
            t.close(try torrent(#"{"status":4,"metadataPercentComplete":0.25,"percentDone":0}"#)
                .displayFraction, 0.25)
            t.close(try torrent(#"{"status":4,"percentDone":0.75}"#).displayFraction, 0.75)
        },

        TestEntry("model/completion-helpers") { t in
            t.equal(try torrent(#"{"status":0,"percentDone":1}"#).isComplete, true)
            t.equal(try torrent(#"{"percentDone":1,"metadataPercentComplete":0.5}"#).isComplete,
                    false, "complete data with unfinished metadata isn't complete")
            t.equal(try torrent(#"{"status":0}"#).isPaused, true)
            t.equal(try torrent(#"{"status":4}"#).isPaused, false)
        },

        TestEntry("model/missing-fields-decode-to-defaults") { t in
            let bare = try torrent("{}")
            t.equal(bare.eta, -1, "-1 means \"unknown\", not 0")
            t.equal(bare.metadataPercentComplete, 1, "assume complete unless told otherwise")
            t.equal(bare.name, "")
            t.isNil(bare.files, "detail-only fields stay absent after a list poll")
        },

        TestEntry("model/file-stats-wanted-accepts-both-spellings") { t in
            t.equal(try JSONDecoder().decode(TorrentFileStats.self,
                                             from: Data(#"{"wanted":0}"#.utf8)).wanted, false)
            t.equal(try JSONDecoder().decode(TorrentFileStats.self,
                                             from: Data(#"{"wanted":true}"#.utf8)).wanted, true)
        },

        TestEntry("model/stats-block-ratio") { t in
            let json = #"{"uploadedBytes":10,"downloadedBytes":20}"#
            let block = try JSONDecoder().decode(StatsBlock.self, from: Data(json.utf8))
            t.equal(block.ratioText, "0.50")
            t.equal(StatsBlock().ratioText, "—", "no downloads yet → no ratio, not a divide by zero")
        },

        TestEntry("model/json-value-encodes-rpc-shapes") { t in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload: JSONValue = .object(["ids": .ints([1, 2]),
                                              "move": .bool(true),
                                              "location": .string("/data/tv")])
            let encoded = String(decoding: try encoder.encode(payload), as: UTF8.self)
            t.equal(encoded, #"{"ids":[1,2],"location":"\/data\/tv","move":true}"#)
        },
    ]
}
#endif
