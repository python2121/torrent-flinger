#if DEBUG
import Foundation

/// `TransmissionClient` against `MockRPC` — the Swift counterpart of the Python
/// suite's `TestTransmissionClient`. These assert on the *wire format* as much
/// as the return values: the RPC spec's quirks (409 handshake, `ids` omitted to
/// mean "all", kebab-case keys) are exactly what silently breaks against a real
/// server, and nothing else in the app checks them.
enum ClientTests {
    static let all: [TestEntry] = [
        TestEntry("client/csrf-handshake-and-torrent-get") { t in
            MockRPC.reset()
            let torrents = try await MockRPC.client().torrents()
            t.equal(torrents.first?.name, "test.iso")
            t.equal(MockRPC.calls.count, 1,
                    "the 409 handshake is two HTTP round trips but one logical call")
        },

        TestEntry("client/add-magnet") { t in
            MockRPC.reset()
            let outcome = try await MockRPC.client().add("magnet:?xt=urn:btih:abc&dn=new.iso")
            t.equal(outcome.kind, .added)
            t.equal(outcome.name, "new.iso")
            t.equal(MockRPC.lastCall?.arguments["filename"] as? String,
                    "magnet:?xt=urn:btih:abc&dn=new.iso")
        },

        TestEntry("client/add-duplicate") { t in
            MockRPC.reset()
            let outcome = try await MockRPC.client().add("magnet:?xt=urn:btih:dup")
            t.equal(outcome.kind, .duplicate,
                    "a duplicate arrives under a different key and must not read as a fresh add")
            t.equal(outcome.name, "test.iso")
        },

        TestEntry("client/add-torrent-file") { t in
            MockRPC.reset()
            let path = NSTemporaryDirectory() + "flinger-test-\(UUID().uuidString).torrent"
            try Data("d8:announce3:urle".utf8).write(to: URL(fileURLWithPath: path))
            defer { try? FileManager.default.removeItem(atPath: path) }

            let outcome = try await MockRPC.client().add(path)
            t.equal(outcome.kind, .added)
            // Local files go over the wire base64-encoded under `metainfo`.
            guard let args = t.unwrap(MockRPC.lastCall?.arguments) else { return }
            t.expect(args["metainfo"] as? String != nil, "expected a base64 metainfo payload")
            t.isNil(args["filename"], "a file path must not be sent as `filename`")
        },

        TestEntry("client/add-missing-file-is-a-request-error") { t in
            MockRPC.reset()
            var thrown: Error?
            do {
                _ = try await MockRPC.client().add("/definitely/not/here.torrent")
            } catch {
                thrown = error
            }
            if case .badRequest = (thrown as? TransmissionError) {
                t.expect(true, "")
            } else {
                t.fail("expected badRequest, got \(thrown.map(String.init(describing:)) ?? "success")")
            }
            t.equal(MockRPC.calls.count, 0, "an unreadable file must not reach the server")
        },

        TestEntry("client/auth-failure") { t in
            MockRPC.reset()
            MockRPC.requireAuth = true
            defer { MockRPC.requireAuth = false }

            do {
                _ = try await MockRPC.client(username: "user", password: "wrong").torrents()
                t.fail("expected authFailed")
            } catch {
                t.equal(error as? TransmissionError, .authFailed)
            }
            // Correct credentials still get through.
            let torrents = try await MockRPC.client(username: "user", password: "pass").torrents()
            t.equal(torrents.count, 1)
        },

        TestEntry("client/session-get-and-stats") { t in
            MockRPC.reset()
            let client = MockRPC.client()
            t.equal(try await client.sessionGet(["version"]).version, "4.0.5")
            let stats = try await client.sessionStats()
            t.equal(stats.downloadSpeed, 1000)
            t.equal(stats.uploadSpeed, 500)
            t.equal(stats.cumulativeStats.sessionCount, 9)
            t.equal(stats.currentStats.downloadedBytes, 20)
        },

        TestEntry("client/details") { t in
            MockRPC.reset()
            let details = try await MockRPC.client().torrentDetails(1)
            t.equal(details.hashString, "abc123")
            t.equal(details.fileStats?.first?.wanted, true, "0/1 on the wire, Bool once decoded")
            t.equal(details.peerLimit, 50, "kebab-case oddball inside a camelCase object")
            t.equal(details.peers?.first?.clientName, "qBittorrent/4.6")
            t.equal(details.trackerStats?.first?.seederCount, 12)

            guard let args = t.unwrap(MockRPC.lastCall?.arguments) else { return }
            t.equal(args["ids"] as? [Int], [1])
            t.expect((args["fields"] as? [String] ?? []).contains("trackerStats"),
                     "the detail field list must ask for trackerStats")
        },

        TestEntry("client/details-of-a-missing-torrent") { t in
            MockRPC.reset()
            // The mock always returns torrent id 1; asking the client to unwrap
            // an empty list is what a server-side removal looks like.
            let empty = TransmissionClient(urlString: "http://127.0.0.1:9091/transmission/rpc",
                                           session: EmptyTorrentListRPC.session())
            do {
                _ = try await empty.torrentDetails(7)
                t.fail("expected notFound")
            } catch {
                t.equal(error as? TransmissionError, .notFound(7))
            }
        },

        TestEntry("client/torrent-set-files") { t in
            MockRPC.reset()
            try await MockRPC.client().torrentSet([1], ["files-unwanted": .ints([0]),
                                                        "priority-high": .ints([2])])
            guard let call = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(call.method, "torrent-set")
            t.equal(call.arguments["ids"] as? [Int], [1])
            t.equal(call.arguments["files-unwanted"] as? [Int], [0])
            t.equal(call.arguments["priority-high"] as? [Int], [2])
        },

        TestEntry("client/set-location") { t in
            MockRPC.reset()
            try await MockRPC.client().setLocation([1], location: "/data/tv", move: true)
            guard let call = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(call.method, "torrent-set-location")
            t.equal(call.arguments["ids"] as? [Int], [1])
            t.equal(call.arguments["location"] as? String, "/data/tv")
            t.equal(call.arguments["move"] as? Bool, true)
        },

        TestEntry("client/verify-reannounce-queue") { t in
            MockRPC.reset()
            let client = MockRPC.client()
            try await client.verify([1])
            t.equal(MockRPC.lastCall?.method, "torrent-verify")
            try await client.reannounce([1])
            t.equal(MockRPC.lastCall?.method, "torrent-reannounce")
            for direction in TransmissionClient.QueueDirection.allCases {
                try await client.queueMove([1], direction)
                t.equal(MockRPC.lastCall?.method, "queue-move-\(direction.rawValue)")
                t.equal(MockRPC.lastCall?.arguments["ids"] as? [Int], [1])
            }
        },

        TestEntry("client/start-stop-semantics") { t in
            MockRPC.reset()
            let client = MockRPC.client()

            // nil → all torrents → `ids` omitted from the call entirely.
            try await client.start(nil)
            guard let allCall = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(allCall.method, "torrent-start")
            t.isNil(allCall.arguments["ids"], "omitting ids is how the spec spells \"all\"")

            // Empty list → no-op, no RPC call at all (never "all by accident").
            let before = MockRPC.calls.count
            try await client.start([])
            t.equal(MockRPC.calls.count, before, "an empty selection must not hit the server")
            try await client.stop([])
            t.equal(MockRPC.calls.count, before)

            try await client.stop([1])
            guard let oneCall = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(oneCall.method, "torrent-stop")
            t.equal(oneCall.arguments["ids"] as? [Int], [1])
        },

        TestEntry("client/remove-wire-format") { t in
            MockRPC.reset()
            try await MockRPC.client().remove([1], deleteData: true)
            guard let call = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(call.method, "torrent-remove")
            t.equal(call.arguments["ids"] as? [Int], [1])
            t.equal(call.arguments["delete-local-data"] as? Bool, true)

            let before = MockRPC.calls.count
            try await MockRPC.client().remove([], deleteData: true)
            t.equal(MockRPC.calls.count, before, "removing nothing must not remove everything")
        },

        TestEntry("client/free-space-and-port-test") { t in
            MockRPC.reset()
            let client = MockRPC.client()
            t.equal(try await client.freeSpace(path: "/data"), 123_456_789)
            t.equal(try await client.portTest(), true)
        },

        TestEntry("client/session-set") { t in
            MockRPC.reset()
            let client = MockRPC.client()
            // Turtle mode rides along in the same payload as the other limits —
            // the Options window writes them all in one session-set.
            try await client.sessionSet(["speed-limit-down": .int(500),
                                         "speed-limit-down-enabled": .bool(true),
                                         "alt-speed-enabled": .bool(true)])
            guard let setCall = t.unwrap(MockRPC.lastCall) else { return }
            t.equal(setCall.method, "session-set")
            t.equal(setCall.arguments["speed-limit-down"] as? Int, 500)
            t.equal(setCall.arguments["speed-limit-down-enabled"] as? Bool, true)
            t.equal(setCall.arguments["alt-speed-enabled"] as? Bool, true)
        },

        TestEntry("client/unreachable-server-is-a-connection-error") { t in
            // Port 1 on the loopback refuses instantly; no network round trip.
            let client = TransmissionClient(urlString: "http://127.0.0.1:1/transmission/rpc",
                                            timeout: 2)
            var thrown: Error?
            do {
                _ = try await client.torrents()
            } catch {
                thrown = error
            }
            if case .connectionFailed = (thrown as? TransmissionError) {
                t.expect(true, "")
            } else {
                t.fail("expected connectionFailed, got \(thrown.map(String.init(describing:)) ?? "success")")
            }
        },

        // macOS reports a connection blocked by the Local Network privacy gate
        // as NSURLErrorNotConnectedToInternet, identical to having no Wi-Fi.
        // Taking that at face value cost an evening of debugging a working
        // network, so the mapping to actionable guidance is pinned here.
        TestEntry("client/blocked-local-network-is-recognised") { t in
            let blocked = NSError(domain: NSURLErrorDomain,
                                  code: NSURLErrorNotConnectedToInternet)
            var thrown: Error?
            do {
                _ = try await MockRPC.failingClient(with: blocked).torrents()
            } catch {
                thrown = error
            }
            t.equal(thrown as? TransmissionError, .localNetworkBlocked)
            let message = (thrown as? TransmissionError)?.errorDescription ?? ""
            t.expect(message.contains("Local Network"),
                     "the message must name the Settings pane; got \"\(message)\"")
            t.expect(!message.lowercased().contains("offline"),
                     "must not repeat URLSession's misleading \"offline\" wording")
        },

        TestEntry("client/other-transport-failures-pass-through") { t in
            // Only -1009 gets the local-network treatment; a refused connection
            // or a timeout must keep its own (accurate) description.
            for code in [NSURLErrorCannotConnectToHost,
                         NSURLErrorTimedOut,
                         NSURLErrorCannotFindHost,
                         NSURLErrorNetworkConnectionLost] {
                let error = NSError(domain: NSURLErrorDomain, code: code)
                var thrown: Error?
                do {
                    _ = try await MockRPC.failingClient(with: error).torrents()
                } catch {
                    thrown = error
                }
                guard case .connectionFailed = (thrown as? TransmissionError) else {
                    t.fail("code \(code) should map to connectionFailed, got \(thrown as Any)")
                    continue
                }
                t.expect(true, "")
            }
        },

        TestEntry("client/non-url-domain-1009-is-not-mistaken-for-a-block") { t in
            // -1009 only means "local network blocked" inside NSURLErrorDomain;
            // the same number in another domain is unrelated.
            let error = NSError(domain: NSPOSIXErrorDomain, code: NSURLErrorNotConnectedToInternet)
            var thrown: Error?
            do {
                _ = try await MockRPC.failingClient(with: error).torrents()
            } catch {
                thrown = error
            }
            guard case .connectionFailed = (thrown as? TransmissionError) else {
                return t.fail("expected connectionFailed, got \(thrown as Any)")
            }
            t.expect(true, "")
        },

        TestEntry("client/malformed-url-fails-cleanly") { t in
            // The options dialog can hand us anything; construction must not trap.
            let client = TransmissionClient(urlString: "not a url at all", timeout: 2)
            do {
                _ = try await client.torrents()
                t.fail("expected an error, not a successful call")
            } catch {
                t.expect(error is TransmissionError, "expected a TransmissionError, got \(error)")
            }
        },
    ]
}

/// A stand-in server that answers `torrent-get` with an empty list, so the
/// "torrent removed on the server" path can be exercised.
private final class EmptyTorrentListRPC: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptyTorrentListRPC.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(string: "http://127.0.0.1/")!
        guard request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == MockRPC.sessionID else {
            let response = HTTPURLResponse(
                url: url, statusCode: 409, httpVersion: "HTTP/1.1",
                headerFields: ["X-Transmission-Session-Id": MockRPC.sessionID])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Data(#"{"result":"success","arguments":{"torrents":[]}}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
