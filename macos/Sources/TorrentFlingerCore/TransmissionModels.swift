import Foundation

// torrent-get "status" values, per the RPC spec.
public enum TorrentStatus: Sendable {
    public static let stopped = 0
    public static let checkWait = 1
    public static let checking = 2
    public static let downloadWait = 3
    public static let downloading = 4
    public static let seedWait = 5
    public static let seeding = 6
}

/// One torrent as `torrent-get` returns it.
///
/// A single struct covers both the list and the details view: fields only
/// requested by `Transmission.detailFields` stay nil after a list poll. Every
/// property decodes leniently (missing → default), because Transmission 3.x,
/// 4.x and the various reimplementations disagree about which keys they emit.
public struct Torrent: Codable, Identifiable, Equatable, Sendable {
    public var id: Int = 0
    public var name: String = ""
    public var status: Int = 0
    public var percentDone: Double = 0
    public var metadataPercentComplete: Double = 1
    public var rateDownload: Int = 0
    public var rateUpload: Int = 0
    public var totalSize: Int64 = 0
    public var downloadedEver: Int64 = 0
    public var uploadedEver: Int64 = 0
    public var uploadRatio: Double = 0
    public var eta: Int = -1
    public var peersConnected: Int = 0
    public var peersSendingToUs: Int = 0
    public var peersGettingFromUs: Int = 0
    public var isFinished: Bool = false
    public var error: Int = 0
    public var errorString: String = ""
    public var addedDate: Int = 0
    public var queuePosition: Int = 0
    public var sizeWhenDone: Int64 = 0
    public var leftUntilDone: Int64 = 0
    public var magnetLink: String = ""
    public var downloadDir: String = ""

    // Detail-only fields (nil after a plain list poll).
    public var hashString: String?
    public var comment: String?
    public var creator: String?
    public var dateCreated: Int?
    public var doneDate: Int?
    public var activityDate: Int?
    public var pieceCount: Int?
    public var pieceSize: Int64?
    public var isPrivate: Bool?
    public var haveValid: Int64?
    public var haveUnchecked: Int64?
    public var corruptEver: Int64?
    public var desiredAvailable: Int64?
    public var secondsDownloading: Int?
    public var secondsSeeding: Int?
    public var seedRatioLimit: Double?
    public var seedRatioMode: Int?
    public var uploadLimit: Int?
    public var uploadLimited: Bool?
    public var downloadLimit: Int?
    public var downloadLimited: Bool?
    public var peerLimit: Int?
    public var files: [TorrentFile]?
    public var fileStats: [TorrentFileStats]?
    public var peers: [TorrentPeer]?
    public var trackerStats: [TrackerStat]?

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

    public init() {}

    public init(from decoder: Decoder) throws {
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

    /// Visual/grouping state, mirroring `linux/flinger/ui/style.py: torrent_state`.
    public enum State: String, CaseIterable, Sendable {
        case error, magnetizing, complete, paused, verifying, queued, downloading, seeding
    }

    /// Order the popover renders status sections in — errors first, because
    /// they're the only ones that need you. Every value `group` can return must
    /// appear here or those rows would have nowhere to render.
    public static let groupOrder = ["Error", "Downloading", "Verifying", "Seeding", "Paused", "Finished"]

    /// Apply the search filter, then bucket by status into `groupOrder`,
    /// preserving server order within a group (queue position is meaningful)
    /// — except Finished, which reads best newest first — and omitting groups
    /// that end up empty. Pure, so the popover's list content can be tested
    /// without a store.
    public static func grouped(_ torrents: [Torrent],
                        matching search: String = "") -> [(name: String, torrents: [Torrent])] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = needle.isEmpty
            ? torrents
            : torrents.filter { $0.name.lowercased().contains(needle) }
        var buckets: [String: [Torrent]] = [:]
        for torrent in visible { buckets[torrent.group, default: []].append(torrent) }
        if let finished = buckets["Finished"] {
            // Stable, so two torrents finishing in the same second keep server order.
            buckets["Finished"] = finished.enumerated()
                .sorted { ($0.element.completionTime, $1.offset) > ($1.element.completionTime, $0.offset) }
                .map(\.element)
        }
        return groupOrder.compactMap { name in buckets[name].map { (name, $0) } }
    }

    /// When the torrent finished, for sorting the Finished group newest
    /// first. Transmission reports `doneDate` as 0 for a torrent that was
    /// already complete when it was added, and some reimplementations omit
    /// it, so those fall back to `addedDate` — when it arrived — rather than
    /// all sinking to the bottom in an arbitrary order. Mirrored in the
    /// Python core (`completion_time`).
    public var completionTime: Int {
        if let done = doneDate, done > 0 { return done }
        return addedDate
    }

    public var state: State {
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
    public var group: String {
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
    public var displayFraction: Double {
        state == .magnetizing ? metadataPercentComplete : percentDone
    }

    public var isComplete: Bool { percentDone >= 1 && metadataPercentComplete >= 1 }
    public var isPaused: Bool { status == TorrentStatus.stopped }
}

public struct TorrentFile: Codable, Equatable, Sendable {
    public var name: String = ""
    public var length: Int64 = 0
    public var bytesCompleted: Int64 = 0

    /// Declaring `init(from:)` suppresses the synthesized memberwise init, and
    /// building one by hand is how the tree tests state their fixtures.
    public init(name: String = "", length: Int64 = 0, bytesCompleted: Int64 = 0) {
        self.name = name
        self.length = length
        self.bytesCompleted = bytesCompleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? ""
        length = (try? c.decodeIfPresent(Int64.self, forKey: .length)).flatMap { $0 } ?? 0
        bytesCompleted = (try? c.decodeIfPresent(Int64.self, forKey: .bytesCompleted)).flatMap { $0 } ?? 0
    }
}

public struct TorrentFileStats: Codable, Equatable, Sendable {
    public var bytesCompleted: Int64 = 0
    /// Serialized as 0/1, not a boolean — decoded through `JSONValue` so both
    /// spellings work.
    public var wanted: Bool = true
    public var priority: Int = 0

    enum CodingKeys: String, CodingKey { case bytesCompleted, wanted, priority }

    /// Stand-in when the server sends fewer `fileStats` than `files` (seen on
    /// some reimplementations mid-metadata-fetch).
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytesCompleted = (try? c.decodeIfPresent(Int64.self, forKey: .bytesCompleted)).flatMap { $0 } ?? 0
        priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)).flatMap { $0 } ?? 0
        let raw = (try? c.decodeIfPresent(JSONValue.self, forKey: .wanted)).flatMap { $0 }
        wanted = raw?.boolValue ?? true
    }
}

public struct TorrentPeer: Codable, Equatable, Identifiable, Sendable {
    public var address: String = ""
    public var clientName: String = ""
    public var flagStr: String = ""
    public var progress: Double = 0
    public var rateToClient: Int = 0
    public var rateToPeer: Int = 0
    public var port: Int = 0

    public var id: String { "\(address):\(port)" }

    public init(from decoder: Decoder) throws {
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

public struct TrackerStat: Codable, Equatable, Identifiable, Sendable {
    public var host: String = ""
    public var announce: String = ""
    public var lastAnnounceResult: String = ""
    public var lastAnnounceSucceeded: Bool = true
    public var seederCount: Int = -1
    public var leecherCount: Int = -1
    public var nextAnnounceTime: Int = 0
    public var tier: Int = 0

    public var id: String { announce.isEmpty ? host : announce }
    public var displayName: String { host.isEmpty ? announce : host }

    public init(from decoder: Decoder) throws {
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
public struct SessionStats: Codable, Equatable, Sendable {
    public var downloadSpeed: Int = 0
    public var uploadSpeed: Int = 0
    public var torrentCount: Int = 0
    public var activeTorrentCount: Int = 0
    public var pausedTorrentCount: Int = 0
    public var currentStats: StatsBlock = StatsBlock()
    public var cumulativeStats: StatsBlock = StatsBlock()

    enum CodingKeys: String, CodingKey {
        case downloadSpeed, uploadSpeed, torrentCount, activeTorrentCount, pausedTorrentCount
        case currentStats = "current-stats"
        case cumulativeStats = "cumulative-stats"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
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

public struct StatsBlock: Codable, Equatable, Sendable {
    public var uploadedBytes: Int64 = 0
    public var downloadedBytes: Int64 = 0
    public var filesAdded: Int = 0
    public var sessionCount: Int = 0
    public var secondsActive: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
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
    public var ratioText: String {
        guard downloadedBytes > 0 else { return "—" }
        return String(format: "%.2f", Double(uploadedBytes) / Double(downloadedBytes))
    }
}

/// The `session-get` fields the app actually reads. Everything is optional:
/// we request narrow field lists, so most keys are absent most of the time.
public struct SessionSettings: Codable, Equatable, Sendable {
    public var version: String?
    public var rpcVersion: Int?
    public var altSpeedEnabled: Bool?
    public var downloadDir: String?
    public var speedLimitDown: Int?
    public var speedLimitDownEnabled: Bool?
    public var speedLimitUp: Int?
    public var speedLimitUpEnabled: Bool?
    public var altSpeedDown: Int?
    public var altSpeedUp: Int?
    public var seedRatioLimit: Double?
    public var seedRatioLimited: Bool?

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
public struct AddOutcome: Equatable, Sendable {
    public enum Kind: String, Sendable { case added, duplicate }
    public var kind: Kind
    public var id: Int
    public var name: String
}
