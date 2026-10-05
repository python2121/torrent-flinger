import Foundation

/// Errors talking to the Transmission server. `errorDescription` is what the
/// popover footer and the error banners show, so keep the strings short.
public enum TransmissionError: LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case localNetworkBlocked
    case authFailed
    case http(Int, String)
    case rpc(String)
    case notFound(Int)
    case badRequest(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return reason
        case .localNetworkBlocked:
            // URLSession reports this as "The Internet connection appears to be
            // offline", which is actively misleading when the real cause is a
            // missing permission and the browser can reach the same server.
            #if os(macOS)
            return "macOS is blocking local network access — allow Torrent Flinger in "
                 + "System Settings › Privacy & Security › Local Network"
            #else
            return "iOS is blocking local network access — allow Torrent Flinger in "
                 + "Settings › Privacy & Security › Local Network"
            #endif
        case .authFailed: return "authentication failed — check username/password"
        case .http(let code, let reason): return "HTTP \(code): \(reason)"
        case .rpc(let message): return message
        case .notFound(let id): return "torrent \(id) not found"
        case .badRequest(let message): return message
        }
    }
}

/// Transmission RPC client — a port of `linux/flinger/core/transmission.py`.
///
/// Async/await over `URLSession` rather than the Python version's blocking
/// `urllib` + thread pool. An actor because the CSRF session id is mutable
/// state shared across concurrent calls.
///
/// Protocol reference:
/// https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md
public actor TransmissionClient {
    public static let torrentFields: [String] = [
        "id", "name", "status", "percentDone", "metadataPercentComplete",
        "rateDownload", "rateUpload", "totalSize", "downloadedEver",
        "uploadedEver", "uploadRatio", "eta", "peersConnected",
        "peersSendingToUs", "peersGettingFromUs", "isFinished", "error",
        "errorString", "addedDate", "doneDate", "queuePosition", "sizeWhenDone",
        "leftUntilDone", "magnetLink", "downloadDir",
    ]

    /// Extra fields fetched only for the details view of a single torrent.
    public static let detailFields: [String] = torrentFields + [
        "hashString", "comment", "creator", "dateCreated",
        "activityDate", "pieceCount", "pieceSize", "isPrivate", "haveValid",
        "haveUnchecked", "corruptEver", "desiredAvailable",
        "secondsDownloading", "secondsSeeding", "seedRatioLimit",
        "seedRatioMode", "uploadLimit", "uploadLimited", "downloadLimit",
        "downloadLimited", "peer-limit", "files", "fileStats", "peers",
        "trackerStats",
    ]

    public let url: URL
    private let username: String
    private let password: String
    private let session: URLSession
    private var sessionID = ""

    public init(urlString: String, username: String = "", password: String = "",
         timeout: TimeInterval = 10, verifyTLS: Bool = true,
         session: URLSession? = nil) {
        // A malformed URL can only come from the options dialog; fall back to
        // a well-formed placeholder so every call fails with a clean
        // "connection failed" instead of trapping at construction.
        self.url = URL(string: urlString) ?? URL(string: "http://invalid.invalid/")!
        self.username = username
        self.password = password
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.httpShouldSetCookies = false
            let insecure = urlString.hasPrefix("https") && !verifyTLS
            self.session = URLSession(
                configuration: configuration,
                delegate: insecure ? InsecureTrustDelegate() : nil,
                delegateQueue: nil
            )
        }
    }

    public init(config: Config, session: URLSession? = nil) {
        self.init(urlString: config.rpcURL, username: config.username,
                  password: config.password, verifyTLS: config.verifyTLS,
                  session: session)
    }

    // MARK: The wire

    private struct RPCResponse<T: Decodable>: Decodable {
        let result: String
        let arguments: T?

        enum CodingKeys: String, CodingKey { case result, arguments }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            result = (try? c.decode(String.self, forKey: .result)) ?? "unknown error"
            // Only decode the payload on success — error bodies put unrelated
            // shapes (or nothing) under `arguments`.
            arguments = result == "success"
                ? (try? c.decodeIfPresent(T.self, forKey: .arguments)).flatMap { $0 }
                : nil
        }
    }

    @discardableResult
    private func call<T: Decodable>(
        _ method: String,
        _ arguments: JSONValue? = nil,
        as type: T.Type,
        retried: Bool = false
    ) async throws -> T? {
        var payload: [String: JSONValue] = ["method": .string(method)]
        if let arguments { payload["arguments"] = arguments }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
        if !username.isEmpty || !password.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let ns = error as NSError
            // Keep the domain/code — "The operation couldn't be completed" on
            // its own can't be told apart from a dozen different causes.
            Log.error("transport failure \(ns.domain)/\(ns.code) for \(method) at \(url.absoluteString): \(ns.localizedDescription)")
            // A server on the LAN plus "not connected to the internet" means the
            // Local Network permission, not the network. See LocalNetwork.swift.
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet {
                throw TransmissionError.localNetworkBlocked
            }
            throw TransmissionError.connectionFailed(ns.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransmissionError.connectionFailed("malformed response")
        }

        if http.statusCode == 409, !retried {
            // CSRF handshake: the server hands us the session id to repeat the
            // call with. One retry only — a second 409 is a real failure.
            sessionID = http.value(forHTTPHeaderField: "X-Transmission-Session-Id") ?? ""
            return try await call(method, arguments, as: type, retried: true)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw TransmissionError.authFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransmissionError.http(
                http.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        let decoded: RPCResponse<T>
        do {
            decoded = try JSONDecoder().decode(RPCResponse<T>.self, from: data)
        } catch {
            throw TransmissionError.rpc("unreadable response from \(url.host ?? "server")")
        }
        guard decoded.result == "success" else {
            throw TransmissionError.rpc(decoded.result)
        }
        return decoded.arguments
    }

    /// Convenience for the many calls whose response body we ignore.
    private func call(_ method: String, _ arguments: JSONValue? = nil) async throws {
        _ = try await call(method, arguments, as: EmptyPayload.self)
    }

    private struct EmptyPayload: Decodable {}

    // MARK: Queries

    private struct TorrentList: Decodable { let torrents: [Torrent] }

    public func torrents() async throws -> [Torrent] {
        let payload = try await call(
            "torrent-get",
            .object(["fields": .strings(Self.torrentFields)]),
            as: TorrentList.self)
        return payload?.torrents ?? []
    }

    public func sessionStats() async throws -> SessionStats {
        try await call("session-stats", as: SessionStats.self) ?? SessionStats()
    }

    public func sessionGet(_ fields: [String]? = nil) async throws -> SessionSettings {
        let args: JSONValue? = fields.map { .object(["fields": .strings($0)]) }
        return try await call("session-get", args, as: SessionSettings.self) ?? SessionSettings()
    }

    public func torrentDetails(_ torrentID: Int) async throws -> Torrent {
        let payload = try await call(
            "torrent-get",
            .object(["ids": .ints([torrentID]), "fields": .strings(Self.detailFields)]),
            as: TorrentList.self)
        guard let torrent = payload?.torrents.first else {
            throw TransmissionError.notFound(torrentID)
        }
        return torrent
    }

    // MARK: Actions

    private struct AddPayload: Decodable {
        struct Entry: Decodable {
            var id: Int = 0
            var name: String = ""
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? c.decodeIfPresent(Int.self, forKey: .id)).flatMap { $0 } ?? 0
                name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? ""
            }
            enum CodingKeys: String, CodingKey { case id, name }
        }
        let added: Entry?
        let duplicate: Entry?
        enum CodingKeys: String, CodingKey {
            case added = "torrent-added"
            case duplicate = "torrent-duplicate"
        }
    }

    /// Add a magnet URI or a local `.torrent` file path.
    public func add(_ link: String, downloadDir: String? = nil, paused: Bool = false) async throws -> AddOutcome {
        if link.hasPrefix("magnet:") {
            return try await add(arguments: ["filename": .string(link)],
                                 downloadDir: downloadDir, paused: paused)
        }
        guard let data = FileManager.default.contents(atPath: link) else {
            throw TransmissionError.badRequest("can't read \(link)")
        }
        return try await add(metainfo: data, downloadDir: downloadDir, paused: paused)
    }

    /// Add a `.torrent` file already in memory — what the iOS app has after
    /// the system hands it a document, where there is no path worth keeping.
    public func add(metainfo: Data, downloadDir: String? = nil, paused: Bool = false) async throws -> AddOutcome {
        try await add(arguments: ["metainfo": .string(metainfo.base64EncodedString())],
                      downloadDir: downloadDir, paused: paused)
    }

    private func add(arguments: [String: JSONValue], downloadDir: String?, paused: Bool) async throws -> AddOutcome {
        var args = arguments
        args["paused"] = .bool(paused)
        if let downloadDir, !downloadDir.isEmpty {
            args["download-dir"] = .string(downloadDir)
        }
        let payload = try await call("torrent-add", .object(args), as: AddPayload.self)
        if let duplicate = payload?.duplicate {
            return AddOutcome(kind: .duplicate, id: duplicate.id, name: duplicate.name)
        }
        let added = payload?.added
        return AddOutcome(kind: .added, id: added?.id ?? 0, name: added?.name ?? "")
    }

    /// `ids == nil` means "all torrents" per the RPC spec; an empty array must
    /// stay a no-op rather than becoming "all".
    public func start(_ ids: [Int]? = nil) async throws {
        if let ids, ids.isEmpty { return }
        try await call("torrent-start", ids.map { .object(["ids": .ints($0)]) })
    }

    public func stop(_ ids: [Int]? = nil) async throws {
        if let ids, ids.isEmpty { return }
        try await call("torrent-stop", ids.map { .object(["ids": .ints($0)]) })
    }

    public func remove(_ ids: [Int], deleteData: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        try await call("torrent-remove",
                       .object(["ids": .ints(ids), "delete-local-data": .bool(deleteData)]))
    }

    // MARK: Administration

    /// `torrent-set` passthrough: files-wanted/-unwanted,
    /// priority-high/-normal/-low (file indices), seedRatioLimit/Mode,
    /// uploadLimit(ed), downloadLimit(ed), labels, …
    public func torrentSet(_ ids: [Int], _ args: [String: JSONValue]) async throws {
        var payload = args
        payload["ids"] = .ints(ids)
        try await call("torrent-set", .object(payload))
    }

    public func setLocation(_ ids: [Int], location: String, move: Bool = true) async throws {
        try await call("torrent-set-location",
                       .object(["ids": .ints(ids), "location": .string(location), "move": .bool(move)]))
    }

    public func verify(_ ids: [Int]) async throws {
        try await call("torrent-verify", .object(["ids": .ints(ids)]))
    }

    public func reannounce(_ ids: [Int]) async throws {
        try await call("torrent-reannounce", .object(["ids": .ints(ids)]))
    }

    public enum QueueDirection: String, CaseIterable, Sendable {
        case top, up, down, bottom
    }

    public func queueMove(_ ids: [Int], _ where_: QueueDirection) async throws {
        try await call("queue-move-\(where_.rawValue)", .object(["ids": .ints(ids)]))
    }

    private struct FreeSpacePayload: Decodable {
        let sizeBytes: Int64?
        enum CodingKeys: String, CodingKey { case sizeBytes = "size-bytes" }
    }

    public func freeSpace(path: String) async throws -> Int64 {
        let payload = try await call("free-space", .object(["path": .string(path)]),
                                     as: FreeSpacePayload.self)
        return payload?.sizeBytes ?? -1
    }

    public func sessionSet(_ args: [String: JSONValue]) async throws {
        try await call("session-set", .object(args))
    }

    private struct PortTestPayload: Decodable {
        let portIsOpen: Bool?
        enum CodingKeys: String, CodingKey { case portIsOpen = "port-is-open" }
    }

    public func portTest() async throws -> Bool {
        let payload = try await call("port-test", as: PortTestPayload.self)
        return payload?.portIsOpen ?? false
    }
}

/// Accepts any server certificate — only installed when the user has
/// explicitly unticked "Verify TLS certificate" for a self-signed NAS.
private final class InsecureTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
