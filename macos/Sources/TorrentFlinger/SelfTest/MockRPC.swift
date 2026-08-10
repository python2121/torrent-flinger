#if DEBUG
import Foundation

/// A mock Transmission RPC server as a `URLProtocol`, mirroring the Python
/// suite's `MockRPC` — including the protocol gotchas it encodes on purpose:
/// the 409 CSRF handshake, `fileStats[].wanted` as 0/1 rather than a boolean,
/// and `peer-limit` in kebab-case inside a camelCase object.
///
/// Keeps a log of `(method, arguments)` so tests can assert on the exact wire
/// format the client produces, the way `MockRPC.calls` does in Python.
final class MockRPC: URLProtocol {
    static let sessionID = "test-session-id"

    /// URLProtocol callbacks land on URLSession's queue, so the shared log and
    /// the auth switch are lock-guarded.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCalls: [(method: String, arguments: [String: Any])] = []
    nonisolated(unsafe) private static var storedRequireAuth = false

    static var calls: [(method: String, arguments: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return storedCalls
    }

    static var requireAuth: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedRequireAuth }
        set { lock.lock(); storedRequireAuth = newValue; lock.unlock() }
    }

    static var lastCall: (method: String, arguments: [String: Any])? { calls.last }

    static func reset() {
        lock.lock()
        storedCalls = []
        storedRequireAuth = false
        lock.unlock()
    }

    /// A `URLSession` wired to this protocol, for injection into the client.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockRPC.self]
        return URLSession(configuration: configuration)
    }

    /// A client pointed at the mock. The URL is never actually dialed — the
    /// protocol intercepts every request.
    static func client(username: String = "", password: String = "") -> TransmissionClient {
        TransmissionClient(urlString: "http://127.0.0.1:9091/transmission/rpc",
                           username: username, password: password,
                           session: session())
    }

    /// One realistic torrent as the pre-4.1 protocol serializes it.
    static let detailTorrent: [String: Any] = [
        "id": 1, "name": "test.iso", "status": 4, "percentDone": 0.5,
        "hashString": "abc123", "magnetLink": "magnet:?xt=urn:btih:abc123",
        "downloadDir": "/data", "comment": "", "queuePosition": 0,
        "peer-limit": 50, "seedRatioLimit": 2.0, "seedRatioMode": 0,
        "files": [["name": "test.iso", "length": 100, "bytesCompleted": 50]],
        "fileStats": [["bytesCompleted": 50, "wanted": 1, "priority": 0]],
        "peers": [["address": "10.0.0.2", "clientName": "qBittorrent/4.6",
                   "progress": 0.9, "rateToClient": 1000, "rateToPeer": 0,
                   "flagStr": "DE", "isEncrypted": true, "port": 51413]],
        "trackerStats": [["host": "tracker.example.org",
                          "announce": "http://tracker.example.org/announce",
                          "lastAnnounceResult": "Success", "lastAnnounceSucceeded": true,
                          "seederCount": 12, "leecherCount": 3, "tier": 0,
                          "nextAnnounceTime": 0]],
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if Self.requireAuth {
            let expected = "Basic " + Data("user:pass".utf8).base64EncodedString()
            guard request.value(forHTTPHeaderField: "Authorization") == expected else {
                respond(status: 401, headers: [:], body: Data())
                return
            }
        }

        guard request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == Self.sessionID else {
            respond(status: 409,
                    headers: ["X-Transmission-Session-Id": Self.sessionID],
                    body: Data())
            return
        }

        // URLSession moves an upload body into httpBodyStream, so read from
        // whichever of the two is populated.
        let bodyData = request.httpBody ?? Self.drain(request.httpBodyStream)
        guard let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = payload["method"] as? String
        else {
            respond(status: 400, headers: [:], body: Data())
            return
        }
        let args = payload["arguments"] as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.storedCalls.append((method, args))
        Self.lock.unlock()

        guard let result = Self.result(for: method, args: args) else {
            respond(status: 501, headers: [:], body: Data())
            return
        }
        let body = (try? JSONSerialization.data(
            withJSONObject: ["result": "success", "arguments": result])) ?? Data()
        respond(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    /// nil = the mock doesn't know this method (the test asked for something
    /// the real server would answer but we haven't modeled).
    private static func result(for method: String, args: [String: Any]) -> [String: Any]? {
        switch method {
        case "torrent-get":
            return ["torrents": [detailTorrent]]
        case "torrent-add":
            if let filename = args["filename"] as? String,
               filename.hasPrefix("magnet:?xt=urn:btih:dup") {
                return ["torrent-duplicate": ["id": 1, "name": "test.iso"]]
            }
            guard args["filename"] != nil || args["metainfo"] != nil else { return nil }
            return ["torrent-added": ["id": 2, "name": "new.iso"]]
        case "session-get":
            return ["version": "4.0.5", "rpc-version": 17,
                    "alt-speed-enabled": false, "download-dir": "/data",
                    "speed-limit-down": 1000, "speed-limit-down-enabled": false,
                    "speed-limit-up": 100, "speed-limit-up-enabled": true,
                    "alt-speed-down": 50, "alt-speed-up": 10,
                    "seedRatioLimit": 2.0, "seedRatioLimited": false]
        case "session-stats":
            return ["downloadSpeed": 1000, "uploadSpeed": 500,
                    "torrentCount": 1, "activeTorrentCount": 1, "pausedTorrentCount": 0,
                    "current-stats": ["uploadedBytes": 10, "downloadedBytes": 20,
                                      "filesAdded": 1, "sessionCount": 1,
                                      "secondsActive": 60],
                    "cumulative-stats": ["uploadedBytes": 100, "downloadedBytes": 200,
                                         "filesAdded": 5, "sessionCount": 9,
                                         "secondsActive": 6000]]
        case "free-space":
            return ["path": args["path"] ?? "", "size-bytes": 123_456_789,
                    "total_size": 1_000_000_000]
        case "port-test":
            return ["port-is-open": true]
        case "torrent-start", "torrent-stop", "torrent-remove", "torrent-set",
             "torrent-set-location", "torrent-verify", "torrent-reannounce",
             "session-set", "queue-move-top", "queue-move-up", "queue-move-down",
             "queue-move-bottom":
            return [:]
        default:
            return nil
        }
    }

    /// A client whose every request fails at the transport layer with `error`,
    /// for exercising the URLSession-error → `TransmissionError` mapping.
    static func failingClient(with error: NSError) -> TransmissionClient {
        FailingTransport.error = error
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingTransport.self]
        return TransmissionClient(urlString: "http://192.168.1.50:9091/transmission/rpc",
                                  session: URLSession(configuration: configuration))
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        let target = request.url ?? URL(string: "http://127.0.0.1/")!
        let response = HTTPURLResponse(url: target, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Fails every request with a preset `NSError`, reproducing what URLSession
/// hands back for a blocked or unreachable connection.
final class FailingTransport: URLProtocol {
    nonisolated(unsafe) static var error: NSError =
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: Self.error)
    }
}
#endif
