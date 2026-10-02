#if DEBUG
import Foundation
@testable import TorrentFlingerCore

/// A Transmission server made of invented data, so the debug windows can be
/// screenshotted without publishing anything real.
///
/// `--show-window` normally runs against the live `config.json`, which is what
/// makes it useful for development and exactly what makes it unusable for
/// documentation: the popover would carry the reader's hostname, torrent names
/// and download paths into a public repository. `--demo` swaps in this
/// `URLProtocol` and a throwaway `Config`, so nothing leaves the machine and
/// nothing about the machine ends up in a screenshot.
///
/// Separate from `MockRPC`, which answers the *minimum* each test asserts on.
/// This one answers with a plausible, full session — every list section
/// occupied, a nested file tree worth expanding, peers and trackers — because
/// its job is to look like a real afternoon's downloading. Everything in it is
/// open-licensed or public-domain material, since it's going on the internet.
enum DemoRPC {
    /// A config that points nowhere real. `DemoTransport` intercepts every
    /// request, so the host is only ever seen, never dialed — which is the
    /// point: it's what the Options window puts on screen.
    static func config() -> Config {
        var config = Config()
        config.host = "transmission.example.lan"
        config.port = 9091
        config.username = "flinger"
        config.password = "hunter2"
        config.scheme = "http"
        config.rpcPath = "/transmission/rpc"
        config.lastDownloadDir = "/srv/torrents/complete"
        config.mountLocal = "/Volumes/torrents"
        config.mountRemote = "/srv/torrents"
        config.customDirs = [
            CustomDir(label: "TV", dir: "/srv/torrents/tv", tv: true),
            CustomDir(label: "Films", dir: "/srv/torrents/films"),
            CustomDir(label: "Archives", dir: "/srv/torrents/archives"),
        ]
        return config
    }

    static func client() -> TransmissionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoTransport.self]
        return TransmissionClient(config: config(),
                                  session: URLSession(configuration: configuration))
    }

    // MARK: The session

    /// Seconds since the epoch for the "added" and "done" dates. Fixed rather
    /// than relative to now, so a screenshot retaken next year looks the same.
    private static let day: Double = 86_400
    private static let now: Double = 1_786_000_000

    /// One torrent in the list, with only the fields `torrentFields` asks for.
    private static func listItem(
        id: Int, name: String, status: Int, percentDone: Double,
        size: Int64, down: Int = 0, up: Int = 0, eta: Int = -1,
        ratio: Double = 0, peers: Int = 0, sending: Int = 0, getting: Int = 0,
        error: Int = 0, errorString: String = "", queue: Int = 0,
        addedDaysAgo: Double = 1, dir: String = "/srv/torrents/complete"
    ) -> [String: Any] {
        [
            "id": id, "name": name, "status": status, "percentDone": percentDone,
            "metadataPercentComplete": 1.0,
            "rateDownload": down, "rateUpload": up,
            "totalSize": size, "sizeWhenDone": size,
            "leftUntilDone": Int64(Double(size) * (1 - percentDone)),
            "downloadedEver": Int64(Double(size) * percentDone),
            "uploadedEver": Int64(Double(size) * ratio),
            "uploadRatio": ratio, "eta": eta,
            "peersConnected": peers, "peersSendingToUs": sending,
            "peersGettingFromUs": getting,
            "isFinished": percentDone >= 1 && status == TorrentStatus.stopped,
            "error": error, "errorString": errorString,
            "addedDate": now - addedDaysAgo * day,
            "queuePosition": queue,
            "magnetLink": "magnet:?xt=urn:btih:\(String(repeating: String(id), count: 8))",
            "downloadDir": dir,
        ]
    }

    /// Every section the popover can draw, occupied: an error at the top, three
    /// downloading, one verifying, two seeding, one paused, one finished.
    static let torrents: [[String: Any]] = [
        listItem(id: 11, name: "Sintel-2010-1080p-OpenMovie.mkv",
                 status: TorrentStatus.downloading, percentDone: 0.62,
                 size: 4_800_000_000, peers: 0, error: 3,
                 errorString: "Tracker gone away: connection refused",
                 queue: 4, addedDaysAgo: 2.5, dir: "/srv/torrents/films"),
        listItem(id: 12, name: "debian-13.1.0-amd64-DVD-1.iso",
                 status: TorrentStatus.downloading, percentDone: 0.46,
                 size: 4_400_000_000, down: 6_800_000, up: 210_000, eta: 349,
                 ratio: 0.31, peers: 34, sending: 22, getting: 6,
                 queue: 0, addedDaysAgo: 0.02, dir: "/srv/torrents/archives"),
        listItem(id: 13, name: "Sprite-Fright-Production-Files",
                 status: TorrentStatus.downloading, percentDone: 0.71,
                 size: 18_600_000_000, down: 2_100_000, up: 640_000, eta: 2_571,
                 ratio: 0.08, peers: 18, sending: 9, getting: 4,
                 queue: 1, addedDaysAgo: 0.4, dir: "/srv/torrents/films"),
        listItem(id: 14, name: "NASA-Apollo-11-Restoration-4K",
                 status: TorrentStatus.downloadWait, percentDone: 0.08,
                 size: 62_000_000_000, peers: 3, queue: 2, addedDaysAgo: 0.1,
                 dir: "/srv/torrents/films"),
        listItem(id: 15, name: "wikipedia-2026-07-multistream.xml.bz2",
                 status: TorrentStatus.checking, percentDone: 0.99,
                 size: 22_400_000_000, peers: 5, queue: 3, addedDaysAgo: 6,
                 dir: "/srv/torrents/archives"),
        listItem(id: 16, name: "archlinux-2026.08.01-x86_64.iso",
                 status: TorrentStatus.seeding, percentDone: 1,
                 size: 1_180_000_000, up: 1_240_000, ratio: 3.42,
                 peers: 41, getting: 12, queue: 5, addedDaysAgo: 14,
                 dir: "/srv/torrents/archives"),
        listItem(id: 17, name: "Big-Buck-Bunny-4K-Open-Content.mp4",
                 status: TorrentStatus.seeding, percentDone: 1,
                 size: 8_900_000_000, up: 210_000, ratio: 1.18,
                 peers: 12, getting: 3, queue: 6, addedDaysAgo: 21,
                 dir: "/srv/torrents/films"),
        listItem(id: 18, name: "librivox-moby-dick-unabridged-mp3",
                 status: TorrentStatus.stopped, percentDone: 0.34,
                 size: 1_600_000_000, queue: 7, addedDaysAgo: 9,
                 dir: "/srv/torrents/archives"),
        listItem(id: 19, name: "ubuntu-24.04.3-desktop-amd64.iso",
                 status: TorrentStatus.stopped, percentDone: 1,
                 size: 6_100_000_000, ratio: 2.06, queue: 8, addedDaysAgo: 30,
                 dir: "/srv/torrents/archives"),
    ]

    /// The details view's torrent: the multi-file one, so the Files tab has a
    /// directory tree worth expanding rather than a single row.
    static func detail(id: Int) -> [String: Any] {
        var torrent = torrents.first { $0["id"] as? Int == id } ?? torrents[1]
        // Deliberately several entries at the top level rather than one folder
        // wrapping everything: SwiftUI's `Table(children:)` owns its disclosure
        // state, so a screenshot can only ever show the tree as it first opens,
        // and one collapsed row would say nothing about the tab. Plenty of real
        // torrents are laid out this way.
        let files: [(String, Int64, Double)] = [
            ("00_README.txt", 4_100, 1),
            ("01_storyboards/sb_act1.png", 42_000_000, 1),
            ("01_storyboards/sb_act2.png", 39_400_000, 1),
            ("01_storyboards/sb_act3.png", 44_800_000, 1),
            ("02_scenes/forest/forest_master.blend", 2_400_000_000, 1),
            ("02_scenes/forest/forest_props.blend", 890_000_000, 1),
            ("02_scenes/camp/camp_master.blend", 1_900_000_000, 0.82),
            ("02_scenes/camp/camp_lighting.blend", 640_000_000, 0.4),
            ("03_renders/act1/frames_0001_0480.exr", 4_100_000_000, 1),
            ("03_renders/act2/frames_0481_0960.exr", 4_300_000_000, 0.61),
            ("03_renders/act3/frames_0961_1440.exr", 3_900_000_000, 0),
            ("04_audio/dialogue_stems.wav", 310_000_000, 1),
            ("04_audio/score_final.wav", 180_000_000, 1),
        ]
        torrent["files"] = files.map { name, length, done in
            ["name": name, "length": length, "bytesCompleted": Int64(Double(length) * done)]
        }
        // `wanted` is 0/1 on the wire, not a boolean — the same quirk the tests
        // pin down. The two unstarted render passes are deselected, so the tab
        // shows a mixed-state folder.
        torrent["fileStats"] = files.enumerated().map { index, file in
            ["bytesCompleted": Int64(Double(file.1) * file.2),
             "wanted": index == 10 ? 0 : 1,
             "priority": index == 8 ? 1 : (index == 10 ? -1 : 0)]
        }
        torrent["hashString"] = "9f1c2d4ab7e05836c1d9f4a2b8e73c05d6a1f284"
        torrent["comment"] = "Blender Studio open movie — production files (CC BY 4.0)"
        torrent["creator"] = "mktorrent 1.1"
        torrent["dateCreated"] = now - 40 * day
        torrent["doneDate"] = 0
        torrent["activityDate"] = now - 12
        torrent["pieceCount"] = 8_868
        torrent["pieceSize"] = 2_097_152
        torrent["isPrivate"] = false
        torrent["haveValid"] = 13_200_000_000
        torrent["haveUnchecked"] = 0
        torrent["corruptEver"] = 1_048_576
        torrent["desiredAvailable"] = 5_400_000_000
        torrent["secondsDownloading"] = 34_500
        torrent["secondsSeeding"] = 0
        torrent["seedRatioLimit"] = 2.0
        torrent["seedRatioMode"] = 0
        torrent["uploadLimit"] = 500
        torrent["uploadLimited"] = false
        torrent["downloadLimit"] = 0
        torrent["downloadLimited"] = false
        torrent["peer-limit"] = 60
        torrent["peers"] = [
            ["address": "203.0.113.44", "clientName": "qBittorrent 4.6.5", "progress": 1.0,
             "rateToClient": 840_000, "rateToPeer": 0, "flagStr": "TDEH",
             "isEncrypted": true, "port": 51413],
            ["address": "198.51.100.17", "clientName": "Transmission 4.0.6", "progress": 0.94,
             "rateToClient": 610_000, "rateToPeer": 120_000, "flagStr": "TDEHX",
             "isEncrypted": true, "port": 51413],
            ["address": "192.0.2.203", "clientName": "Deluge 2.1.1", "progress": 0.71,
             "rateToClient": 0, "rateToPeer": 340_000, "flagStr": "TUE",
             "isEncrypted": true, "port": 6881],
            ["address": "203.0.113.91", "clientName": "libtorrent 2.0.10", "progress": 0.38,
             "rateToClient": 210_000, "rateToPeer": 0, "flagStr": "TDE",
             "isEncrypted": false, "port": 51820],
        ]
        torrent["trackerStats"] = [
            ["host": "tracker.example.org",
             "announce": "https://tracker.example.org:443/announce",
             "lastAnnounceResult": "Success", "lastAnnounceSucceeded": true,
             "seederCount": 214, "leecherCount": 38, "tier": 0,
             "nextAnnounceTime": now + 1_140],
            ["host": "open.demo-tracker.invalid",
             "announce": "udp://open.demo-tracker.invalid:6969/announce",
             "lastAnnounceResult": "Connection failed", "lastAnnounceSucceeded": false,
             "seederCount": -1, "leecherCount": -1, "tier": 1,
             "nextAnnounceTime": now + 300],
        ]
        return torrent
    }

    static func result(for method: String, args: [String: Any]) -> [String: Any]? {
        switch method {
        case "torrent-get":
            // With ids it's the details view; without, the list poll.
            if let ids = args["ids"] as? [Int], let id = ids.first {
                return ["torrents": [detail(id: id)]]
            }
            return ["torrents": torrents]
        case "session-get":
            return ["version": "4.0.6", "rpc-version": 17,
                    "download-dir": "/srv/torrents/complete",
                    "alt-speed-enabled": false, "alt-speed-down": 2_000, "alt-speed-up": 500,
                    "speed-limit-down": 25_000, "speed-limit-down-enabled": false,
                    "speed-limit-up": 4_000, "speed-limit-up-enabled": true,
                    "seedRatioLimit": 2.0, "seedRatioLimited": true]
        case "session-stats":
            return ["downloadSpeed": 8_900_000, "uploadSpeed": 2_090_000,
                    "torrentCount": torrents.count, "activeTorrentCount": 6,
                    "pausedTorrentCount": 2,
                    "current-stats": ["uploadedBytes": 41_200_000_000,
                                      "downloadedBytes": 96_800_000_000,
                                      "filesAdded": 63, "sessionCount": 1,
                                      "secondsActive": 262_800],
                    "cumulative-stats": ["uploadedBytes": 3_940_000_000_000,
                                         "downloadedBytes": 5_120_000_000_000,
                                         "filesAdded": 2_184, "sessionCount": 96,
                                         "secondsActive": 21_772_800]]
        case "free-space":
            return ["path": args["path"] ?? "", "size-bytes": 812_000_000_000,
                    "total_size": 4_000_000_000_000]
        case "port-test":
            return ["port-is-open": true]
        case "torrent-add":
            return ["torrent-added": ["id": 20, "name": "new-torrent"]]
        default:
            // Every mutating call succeeds silently, so the windows stay usable
            // while being driven for a screenshot.
            return [:]
        }
    }
}

/// Serves `DemoRPC` over `URLProtocol`, CSRF handshake and all — the client
/// does the 409 dance here exactly as it does against a real server.
final class DemoTransport: URLProtocol {
    static let sessionID = "demo-session-id"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == Self.sessionID else {
            respond(status: 409, headers: ["X-Transmission-Session-Id": Self.sessionID], body: Data())
            return
        }
        let bodyData = request.httpBody ?? Self.drain(request.httpBodyStream)
        guard let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = payload["method"] as? String,
              let result = DemoRPC.result(for: method,
                                          args: payload["arguments"] as? [String: Any] ?? [:])
        else {
            respond(status: 400, headers: [:], body: Data())
            return
        }
        let body = (try? JSONSerialization.data(
            withJSONObject: ["result": "success", "arguments": result])) ?? Data()
        respond(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        let target = request.url ?? URL(string: "http://demo.invalid/")!
        let response = HTTPURLResponse(url: target, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
