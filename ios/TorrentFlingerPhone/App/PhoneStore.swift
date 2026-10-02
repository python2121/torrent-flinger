import Foundation
import Observation
import TorrentFlingerCore

/// The phone's single source of truth — the counterpart of the Mac build's
/// `TorrentStore`, minus everything that only makes sense on a desktop
/// (keyboard selection, the menu-bar readout, Reveal in Finder).
///
/// Polls only while the app is in the foreground: iOS gives a backgrounded
/// app no reliable schedule, so there is no "download complete" notification
/// here — the list simply refreshes when the app comes back.
@Observable
@MainActor
final class PhoneStore {
    /// A transient banner: the add outcome, a failed action, a finished download.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String?
        var isError = false
    }

    /// A link or file waiting on the add sheet.
    struct PendingAdd: Identifiable, Equatable {
        enum Source: Equatable {
            case magnet(String)
            case file(name: String, data: Data)
        }
        let id = UUID()
        let source: Source

        var displayName: String {
            switch source {
            case .magnet(let link): return Format.linkDisplayName(link)
            case .file(let name, _): return name
            }
        }
    }

    private(set) var config: Config
    /// False until a server has been saved once — drives the first-run screen.
    private(set) var hasConfig: Bool
    private(set) var client: TransmissionClient

    private(set) var torrents: [Torrent] = []
    private(set) var stats = SessionStats()
    private(set) var serverDownloadDir = ""
    private(set) var serverVersion = ""
    private(set) var freeSpace: Int64 = -1
    private(set) var connected = false
    private(set) var errorMessage: String?
    /// Whether any poll has completed (successfully or not) since launch.
    private(set) var hasPolled = false

    var searchText = ""
    var toast: Toast?
    var pendingAdds: [PendingAdd] = []

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var inflight = false
    @ObservationIgnored private var completedIDs: Set<Int>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        let (config, hasConfig) = PhoneConfig.load()
        self.config = config
        self.hasConfig = hasConfig
        self.client = TransmissionClient(config: config)
    }

    // MARK: Lifecycle

    /// Foreground → poll at the configured interval; background → stop.
    func setActive(_ active: Bool) {
        if active { startPolling() } else { stopPolling() }
    }

    private func startPolling() {
        guard hasConfig, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                // Never faster than once a second, whatever the file says.
                let ms = max(self.config.pollIntervalMs, 1000)
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One round: session (download dir, version) → torrents → stats → free
    /// space. Free space is decoration and never fails the poll.
    func poll() async {
        guard !inflight else { return }
        inflight = true
        defer { inflight = false }
        let client = self.client
        do {
            let session = try await client.sessionGet(["download-dir", "version"])
            let list = try await client.torrents()
            let stats = try await client.sessionStats()
            serverDownloadDir = session.downloadDir ?? ""
            serverVersion = session.version ?? ""
            torrents = list
            self.stats = stats
            connected = true
            errorMessage = nil
            noteFinished(list)
            if !serverDownloadDir.isEmpty {
                freeSpace = (try? await client.freeSpace(path: serverDownloadDir)) ?? -1
            }
        } catch {
            connected = false
            errorMessage = describe(error)
        }
        hasPolled = true
    }

    /// Announce torrents that completed since the previous poll. Nil until
    /// the first successful poll so launching doesn't announce the backlog.
    private func noteFinished(_ list: [Torrent]) {
        let complete = Set(list.filter(\.isComplete).map(\.id))
        if let previous = completedIDs {
            for torrent in list where complete.contains(torrent.id) && !previous.contains(torrent.id) {
                show(Toast(title: "Download complete", detail: torrent.name))
            }
        }
        completedIDs = complete
    }

    // MARK: Derived

    var groups: [(name: String, torrents: [Torrent])] {
        Torrent.grouped(torrents, matching: searchText)
    }

    func torrent(id: Int) -> Torrent? { torrents.first { $0.id == id } }

    /// `↓ 1.2 MB/s · ↑ 300 KB/s · 12 torrents · 1.2 TB free`
    var summary: String {
        var parts: [String] = []
        if stats.downloadSpeed > 0 { parts.append("↓ \(Format.speed(stats.downloadSpeed))") }
        if stats.uploadSpeed > 0 { parts.append("↑ \(Format.speed(stats.uploadSpeed))") }
        if parts.isEmpty { parts.append("Idle") }
        parts.append(torrents.count == 1 ? "1 torrent" : "\(torrents.count) torrents")
        if freeSpace >= 0 { parts.append("\(Format.size(freeSpace)) free") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Run one RPC action, re-poll on success, surface a failure as a toast.
    func perform(_ failure: String, _ operation: @escaping (TransmissionClient) async throws -> Void) {
        let client = self.client
        Task {
            do {
                try await operation(client)
                await poll()
            } catch {
                show(Toast(title: failure, detail: describe(error), isError: true))
            }
        }
    }

    func start(_ ids: [Int]) { perform("Couldn't resume") { try await $0.start(ids) } }
    func stop(_ ids: [Int]) { perform("Couldn't pause") { try await $0.stop(ids) } }
    func startAll() { perform("Couldn't start all") { try await $0.start(nil) } }
    func stopAll() { perform("Couldn't pause all") { try await $0.stop(nil) } }

    func remove(_ ids: [Int], deleteData: Bool) {
        perform("Couldn't remove") { try await $0.remove(ids, deleteData: deleteData) }
    }

    func magnetLinks(for ids: [Int]) -> [String] {
        ids.compactMap { torrent(id: $0)?.magnetLink }.filter { !$0.isEmpty }
    }

    // MARK: Adding

    func receive(magnet link: String) {
        enqueue(PendingAdd(source: .magnet(link)))
    }

    /// A `.torrent` handed over by the system (share sheet, Files, Safari's
    /// download list). Read it now — the URL is a one-shot Inbox copy or a
    /// security-scoped reference that won't stay valid.
    func receive(fileURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            show(Toast(title: "Couldn't read \(url.lastPathComponent)", isError: true))
            return
        }
        if url.path.contains("/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        enqueue(PendingAdd(source: .file(name: url.deletingPathExtension().lastPathComponent, data: data)))
    }

    private func enqueue(_ pending: PendingAdd) {
        if config.showAddDialog {
            pendingAdds.append(pending)
        } else {
            add(pending, downloadDir: nil, paused: config.startPaused)
        }
    }

    func dismissPending(_ id: PendingAdd.ID) {
        pendingAdds.removeAll { $0.id == id }
    }

    func add(_ pending: PendingAdd, downloadDir: String?, paused: Bool) {
        let client = self.client
        Task {
            do {
                let outcome: AddOutcome
                switch pending.source {
                case .magnet(let link):
                    outcome = try await client.add(link, downloadDir: downloadDir, paused: paused)
                case .file(_, let data):
                    outcome = try await client.add(metainfo: data, downloadDir: downloadDir, paused: paused)
                }
                let name = outcome.name.isEmpty ? pending.displayName : outcome.name
                show(Toast(title: outcome.kind == .added ? "Torrent added" : "Already in Transmission",
                           detail: name))
                await poll()
            } catch {
                show(Toast(title: "Couldn't add torrent", detail: describe(error), isError: true))
            }
        }
    }

    // MARK: Config

    func save(_ newConfig: Config) {
        PhoneConfig.save(newConfig)
        config = newConfig
        client = TransmissionClient(config: newConfig)
        hasConfig = true
        completedIDs = nil
        stopPolling()
        startPolling()
    }

    // MARK: Feedback

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(toast.isError ? 5 : 3))
            if !Task.isCancelled, self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func describe(_ error: Error) -> String {
        (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
    }
}
