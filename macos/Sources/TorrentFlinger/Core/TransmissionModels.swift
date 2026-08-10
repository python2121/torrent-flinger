import Foundation

// torrent-get "status" values, per the RPC spec.
enum TorrentStatus {
    static let stopped = 0
    static let checkWait = 1
    static let checking = 2
    static let downloadWait = 3
    static let downloading = 4
    static let seedWait = 5
    static let seeding = 6
}

/// One torrent as `torrent-get` returns it.
///
/// A single struct covers both the list and the details view: fields only
/// requested by `Transmission.detailFields` stay nil after a list poll. Every
/// property decodes leniently (missing → default), because Transmission 3.x,
/// 4.x and the various reimplementations disagree about which keys they emit.
struct Torrent: Codable, Identifiable, Equatable {
    var id: Int = 0
    var name: String = ""
    var status: Int = 0
    var percentDone: Double = 0
    var metadataPercentComplete: Double = 1
    var rateDownload: Int = 0
    var rateUpload: Int = 0
    var totalSize: Int64 = 0
    var downloadedEver: Int64 = 0
    var uploadedEver: Int64 = 0
    var uploadRatio: Double = 0
    var eta: Int = -1
    var peersConnected: Int = 0
    var peersSendingToUs: Int = 0
    var peersGettingFromUs: Int = 0
    var isFinished: Bool = false
    var error: Int = 0
    var errorString: String = ""
    var addedDate: Int = 0
    var queuePosition: Int = 0
    var sizeWhenDone: Int64 = 0
    var leftUntilDone: Int64 = 0
    var magnetLink: String = ""
    var downloadDir: String = ""

    // Detail-only fields (nil after a plain list poll).
    var hashString: String?
    var comment: String?
    var creator: String?
    var dateCreated: Int?
    var doneDate: Int?
    var activityDate: Int?
    var pieceCount: Int?
    var pieceSize: Int64?
    var isPrivate: Bool?
    var haveValid: Int64?
    var haveUnchecked: Int64?
    var corruptEver: Int64?
    var desiredAvailable: Int64?
    var secondsDownloading: Int?
    var secondsSeeding: Int?
    var seedRatioLimit: Double?
    var seedRatioMode: Int?
    var uploadLimit: Int?
    var uploadLimited: Bool?
    var downloadLimit: Int?
    var downloadLimited: Bool?
    var peerLimit: Int?
    var files: [TorrentFile]?
    var fileStats: [TorrentFileStats]?
    var peers: [TorrentPeer]?
    var trackerStats: [TrackerStat]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, percentDone, metadataPercentComplete
        case rateDownload, rateUpload, totalSize, downloadedEver, uploadedEver
        case uploadRatio, eta, peersConnected, peersSendingToUs, peersGettingFromUs
        case isFinished, error, errorString, addedDate, queuePosition
        case sizeWhenDone, leftUntilDone, magnetLink, downloadDir
        case hashString, comment, creator, dateCreated, doneDate, activityDate
        case pieceCount, pieceSize, isPrivate, haveValid, haveUnchecked
        case corruptEver, desiredAvailable, secondsDownloading, secondsSeeding
        case seedRatioLimit, seedRatioMode, uploadLimit, uploadLimited
        case downloadLimit, downloadLimited
        case peerLimit = "peer-limit"   // kebab oddball inside a camelCase object
        case files, fileStats, peers, trackerStats
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        func o<T: Decodable>(_ k: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 }
        }
        id = d(.id, 0)
        name = d(.name, "")
        status = d(.status, 0)
        percentDone = d(.percentDone, 0)
        metadataPercentComplete = d(.metadataPercentComplete, 1)
        rateDownload = d(.rateDownload, 0)
        rateUpload = d(.rateUpload, 0)
        totalSize = d(.totalSize, 0)
        downloadedEver = d(.downloadedEver, 0)
        uploadedEver = d(.uploadedEver, 0)
        uploadRatio = d(.uploadRatio, 0)
        eta = d(.eta, -1)
        peersConnected = d(.peersConnected, 0)
        peersSendingToUs = d(.peersSendingToUs, 0)
        peersGettingFromUs = d(.peersGettingFromUs, 0)
        isFinished = d(.isFinished, false)
        error = d(.error, 0)
        errorString = d(.errorString, "")
        addedDate = d(.addedDate, 0)
        queuePosition = d(.queuePosition, 0)
        sizeWhenDone = d(.sizeWhenDone, 0)
        leftUntilDone = d(.leftUntilDone, 0)
        magnetLink = d(.magnetLink, "")
        downloadDir = d(.downloadDir, "")
        hashString = o(.hashString)
        comment = o(.comment)
        creator = o(.creator)
        dateCreated = o(.dateCreated)
        doneDate = o(.doneDate)
        activityDate = o(.activityDate)
        pieceCount = o(.pieceCount)
        pieceSize = o(.pieceSize)
        isPrivate = o(.isPrivate)
        haveValid = o(.haveValid)
        haveUnchecked = o(.haveUnchecked)
        corruptEver = o(.corruptEver)
        desiredAvailable = o(.desiredAvailable)
        secondsDownloading = o(.secondsDownloading)
        secondsSeeding = o(.secondsSeeding)
        seedRatioLimit = o(.seedRatioLimit)
        seedRatioMode = o(.seedRatioMode)
        uploadLimit = o(.uploadLimit)
        uploadLimited = o(.uploadLimited)
        downloadLimit = o(.downloadLimit)
        downloadLimited = o(.downloadLimited)
        peerLimit = o(.peerLimit)
        files = o(.files)
        fileStats = o(.fileStats)
        peers = o(.peers)
        trackerStats = o(.trackerStats)
    }

    // MARK: Derived

    /// Visual/grouping state, mirroring `flinger/ui/style.py: torrent_state`.
    enum State: String, CaseIterable {
        case error, magnetizing, complete, paused, verifying, queued, downloading, seeding
    }

    /// Order the popover renders status sections in — errors first, because
    /// they're the only ones that need you. Every value `group` can return must
    /// appear here or those rows would have nowhere to render.
    static let groupOrder = ["Error", "Downloading", "Verifying", "Seeding", "Paused", "Finished"]

    /// Apply the search filter, then bucket by status into `groupOrder`,
    /// preserving server order within a group and omitting groups that end up
    /// empty. Pure, so the popover's list content can be tested without a store.
    static func grouped(_ torrents: [Torrent],
                        matching search: String = "") -> [(name: String, torrents: [Torrent])] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = needle.isEmpty
            ? torrents
            : torrents.filter { $0.name.lowercased().contains(needle) }
        var buckets: [String: [Torrent]] = [:]
        for torrent in visible { buckets[torrent.group, default: []].append(torrent) }
        return groupOrder.compactMap { name in buckets[name].map { (name, $0) } }
    }

    var state: State {
        if !errorString.isEmpty { return .error }
        if metadataPercentComplete < 1 { return .magnetizing }
        switch status {
        case TorrentStatus.stopped:
            return percentDone >= 1 ? .complete : .paused
        case TorrentStatus.checkWait, TorrentStatus.checking:
            return .verifying
        case TorrentStatus.downloadWait:
            return .queued
        case TorrentStatus.downloading:
            return .downloading
        default:
            return .seeding
        }
    }

    /// Section header this torrent sorts under in the popover.
    var group: String {
        switch state {
        case .downloading, .magnetizing, .queued: return "Downloading"
        case .verifying: return "Verifying"
        case .seeding: return "Seeding"
        case .error: return "Error"
        case .paused: return "Paused"
        case .complete: return "Finished"
        }
    }

    /// Fraction to render in the progress bar: metadata progress while
    /// magnetizing, download progress otherwise.
    var displayFraction: Double {
        state == .magnetizing ? metadataPercentComplete : percentDone
    }

    var isComplete: Bool { percentDone >= 1 && metadataPercentComplete >= 1 }
    var isPaused: Bool { status == TorrentStatus.stopped }
}

struct TorrentFile: Codable, Equatable {
    var name: String = ""
    var length: Int64 = 0
    var bytesCompleted: Int64 = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? ""
        length = (try? c.decodeIfPresent(Int64.self, forKey: .length)).flatMap { $0 } ?? 0
        bytesCompleted = (try? c.decodeIfPresent(Int64.self, forKey: .bytesCompleted)).flatMap { $0 } ?? 0
    }
}

struct TorrentFileStats: Codable, Equatable {
    var bytesCompleted: Int64 = 0
    /// Serialized as 0/1, not a boolean — decoded through `JSONValue` so both
    /// spellings work.
    var wanted: Bool = true
    var priority: Int = 0

    enum CodingKeys: String, CodingKey { case bytesCompleted, wanted, priority }

    /// Stand-in when the server sends fewer `fileStats` than `files` (seen on
    /// some reimplementations mid-metadata-fetch).
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytesCompleted = (try? c.decodeIfPresent(Int64.self, forKey: .bytesCompleted)).flatMap { $0 } ?? 0
        priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)).flatMap { $0 } ?? 0
        let raw = (try? c.decodeIfPresent(JSONValue.self, forKey: .wanted)).flatMap { $0 }
        wanted = raw?.boolValue ?? true
    }
}

struct TorrentPeer: Codable, Equatable, Identifiable {
    var address: String = ""
    var clientName: String = ""
    var flagStr: String = ""
    var progress: Double = 0
    var rateToClient: Int = 0
    var rateToPeer: Int = 0
    var port: Int = 0

    var id: String { "\(address):\(port)" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        address = d(.address, "")
        clientName = d(.clientName, "")
        flagStr = d(.flagStr, "")
        progress = d(.progress, 0)
        rateToClient = d(.rateToClient, 0)
        rateToPeer = d(.rateToPeer, 0)
        port = d(.port, 0)
    }
}

struct TrackerStat: Codable, Equatable, Identifiable {
    var host: String = ""
    var announce: String = ""
    var lastAnnounceResult: String = ""
    var lastAnnounceSucceeded: Bool = true
    var seederCount: Int = -1
    var leecherCount: Int = -1
    var nextAnnounceTime: Int = 0
    var tier: Int = 0

    var id: String { announce.isEmpty ? host : announce }
    var displayName: String { host.isEmpty ? announce : host }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        host = d(.host, "")
        announce = d(.announce, "")
        lastAnnounceResult = d(.lastAnnounceResult, "")
        lastAnnounceSucceeded = d(.lastAnnounceSucceeded, true)
        seederCount = d(.seederCount, -1)
        leecherCount = d(.leecherCount, -1)
        nextAnnounceTime = d(.nextAnnounceTime, 0)
        tier = d(.tier, 0)
    }
}

/// `session-stats`: the live speeds plus the two cumulative blocks the
/// statistics window renders side by side.
struct SessionStats: Codable, Equatable {
    var downloadSpeed: Int = 0
    var uploadSpeed: Int = 0
    var torrentCount: Int = 0
    var activeTorrentCount: Int = 0
    var pausedTorrentCount: Int = 0
    var currentStats: StatsBlock = StatsBlock()
    var cumulativeStats: StatsBlock = StatsBlock()

    enum CodingKeys: String, CodingKey {
        case downloadSpeed, uploadSpeed, torrentCount, activeTorrentCount, pausedTorrentCount
        case currentStats = "current-stats"
        case cumulativeStats = "cumulative-stats"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        downloadSpeed = d(.downloadSpeed, 0)
        uploadSpeed = d(.uploadSpeed, 0)
        torrentCount = d(.torrentCount, 0)
        activeTorrentCount = d(.activeTorrentCount, 0)
        pausedTorrentCount = d(.pausedTorrentCount, 0)
        currentStats = d(.currentStats, StatsBlock())
        cumulativeStats = d(.cumulativeStats, StatsBlock())
    }
}

struct StatsBlock: Codable, Equatable {
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var filesAdded: Int = 0
    var sessionCount: Int = 0
    var secondsActive: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        uploadedBytes = d(.uploadedBytes, 0)
        downloadedBytes = d(.downloadedBytes, 0)
        filesAdded = d(.filesAdded, 0)
        sessionCount = d(.sessionCount, 0)
        secondsActive = d(.secondsActive, 0)
    }

    /// "—" when nothing has been downloaded, matching the Python dialog.
    var ratioText: String {
        guard downloadedBytes > 0 else { return "—" }
        return String(format: "%.2f", Double(uploadedBytes) / Double(downloadedBytes))
    }
}

/// The `session-get` fields the app actually reads. Everything is optional:
/// we request narrow field lists, so most keys are absent most of the time.
struct SessionSettings: Codable, Equatable {
    var version: String?
    var rpcVersion: Int?
    var altSpeedEnabled: Bool?
    var downloadDir: String?
    var speedLimitDown: Int?
    var speedLimitDownEnabled: Bool?
    var speedLimitUp: Int?
    var speedLimitUpEnabled: Bool?
    var altSpeedDown: Int?
    var altSpeedUp: Int?
    var seedRatioLimit: Double?
    var seedRatioLimited: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case rpcVersion = "rpc-version"
        case altSpeedEnabled = "alt-speed-enabled"
        case downloadDir = "download-dir"
        case speedLimitDown = "speed-limit-down"
        case speedLimitDownEnabled = "speed-limit-down-enabled"
        case speedLimitUp = "speed-limit-up"
        case speedLimitUpEnabled = "speed-limit-up-enabled"
        case altSpeedDown = "alt-speed-down"
        case altSpeedUp = "alt-speed-up"
        case seedRatioLimit = "seedRatioLimit"
        case seedRatioLimited = "seedRatioLimited"
    }
}

/// `torrent-add` outcome: the server reports a fresh add and a duplicate under
/// different keys, and the caller needs to tell them apart for the notification.
struct AddOutcome: Equatable {
    enum Kind: String { case added, duplicate }
    var kind: Kind
    var id: Int
    var name: String
}
