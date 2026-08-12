#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// The single source of truth: server state, polling cadence, selection, and
/// every mutating action. The macOS counterpart of `linux/flinger/ui/app.py`'s
/// polling half — the window/dialog half lives in `AppDelegate`.
@MainActor
final class TorrentStore: ObservableObject {
    /// Poll cadence while the panel is closed. The visible cadence comes from
    /// `config.pollIntervalMs`, exactly as on Linux.
    static let hiddenPollInterval: TimeInterval = 30

    /// Cadence for the speeds-only tick. Fast enough that a 15 s window has
    /// half a dozen readings in it, slow enough to be invisible next to the
    /// traffic a torrent client is already making.
    static let speedSampleInterval: TimeInterval = 2.5

    @Published private(set) var torrents: [Torrent] = []
    @Published private(set) var stats = SessionStats()

    /// The smoothed speeds the menu bar draws. `stats` keeps the raw readings
    /// for everything that's looking at the numbers deliberately — the popover
    /// footer, the tooltip, the statistics window. See `SpeedAverager` for why
    /// the menu bar can't use them directly.
    @Published private(set) var menubarSpeeds = SpeedAverager.Speeds.zero
    @Published private(set) var freeSpace: Int64 = -1
    @Published private(set) var connected = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var config: Config

    /// Live search text. One of the Escape targets: with nothing selected an
    /// Escape clears it, and a further one closes the panel.
    @Published var searchText = ""
    @Published var selectedIDs: Set<Int> = []
    @Published var expandedIDs: Set<Int> = []

    /// Row the list should scroll into view — set by keyboard navigation and
    /// cleared by the list once it has obliged.
    @Published private(set) var scrollTarget: Int?

    /// A `magnet:` link sitting in the clipboard that we haven't offered (or
    /// been told to stop offering) yet — drives the popover's clipboard banner.
    @Published var clipboardOffer: String?

    /// True for `TrayIcon.addedDuration` after a torrent is accepted, which is
    /// what puts the "+" in the menu bar. A notification rather than a status,
    /// so it outranks everything else while it lasts.
    @Published private(set) var recentlyAdded = false
    private var addedExpiry: DispatchWorkItem?

    private(set) var client: TransmissionClient

    /// Server's default download dir plus the resolved remote prefix, used for
    /// free-space readouts and "Reveal in Finder" path mapping.
    private(set) var serverDownloadDir = ""
    private(set) var remotePrefix = ""

    private var timer: Timer?
    private var speedTimer: Timer?
    private var speedAverager = SpeedAverager()
    private var isPolling = false
    private var isSamplingSpeeds = false
    private var panelVisible = false
    /// nil until the first successful poll, so we don't announce every
    /// already-finished torrent at launch.
    private var finishedIDs: Set<Int>?
    private var dismissedClipboard = ""
    /// Anchor for shift-click range selection.
    private var anchorID: Int?

    /// The moving end of the selection — the row last clicked or arrowed onto.
    /// Shift-arrowing walks this while `anchorID` stays put.
    private var cursorID: Int?

    /// Injectable for tests; the real one hits the filesystem.
    var directoryExists: (String) -> Bool = { path in
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    var pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// `client` is the injection seam the debug windows use to run against
    /// canned data (`DemoRPC`) instead of a live server — the same reason
    /// `directoryExists` and `pathExists` are injectable. In the app it's
    /// always nil and the client comes from config.
    init(config: Config = Config.load(), client: TransmissionClient? = nil) {
        self.config = config
        self.client = client ?? TransmissionClient(config: config)
        Log.info("starting — server \(config.rpcURL), config \(Config.fileURL.path)")
        startTimer()
        poll()
    }

    // MARK: Polling

    private var pollInterval: TimeInterval {
        panelVisible ? Double(config.pollIntervalMs) / 1000 : Self.hiddenPollInterval
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = pollInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = interval * 0.1
        self.timer = timer
    }

    /// Called by `AppDelegate` when the panel opens/closes: an open panel wants
    /// second-by-second numbers, a closed one only needs enough to keep the
    /// menubar honest.
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        startTimer()
        updateSpeedTimer()
        if visible {
            refreshClipboardOffer()
            poll()
        } else {
            // Selection and expansion are per-viewing state; a reopened panel
            // should look freshly opened rather than resuming a stale session.
            clearSelection()
        }
    }

    // MARK: The speeds-only tick
    //
    // The menu bar needs readings far more often than the idle 30 s poll
    // provides: a 15 s average refreshed every 5 s can't be built out of one
    // number every half minute. It doesn't need the torrent list to do it,
    // though — so while the panel is closed and something is actually moving,
    // a second timer calls `session-stats` on its own. One round trip, no
    // list, no free-space probe.
    //
    // While the panel is open the ordinary poll already runs at the config's
    // cadence and carries the same numbers, so this stays off and the averager
    // feeds off those instead.

    private func updateSpeedTimer() {
        // Nothing transferring means no numbers in the menu bar, so there's
        // nothing to smooth and no reason to be talking to the server; the
        // 30 s poll picks the next transfer up. Same for speeds switched off.
        let wanted = !panelVisible && connected && config.menubarShowSpeeds
            && (stats.downloadSpeed > 0 || stats.uploadSpeed > 0 || speedAverager.isTracking)
        guard wanted != (speedTimer != nil) else { return }

        guard wanted else {
            speedTimer?.invalidate()
            speedTimer = nil
            return
        }
        let interval = Self.speedSampleInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSpeeds() }
        }
        timer.tolerance = interval * 0.1
        speedTimer = timer
    }

    private func sampleSpeeds() {
        // A full poll is about to deliver the same numbers; don't race it. And
        // don't race ourselves either: a server slower to answer than the tick
        // would otherwise have a new request started on top of every unfinished
        // one, and out-of-order replies would walk the readings backwards.
        guard !isPolling, !isSamplingSpeeds else { return }
        isSamplingSpeeds = true
        let client = self.client
        Task { [weak self] in
            // Errors here are the poll's business — a dropped sample just means
            // the average coasts on the readings either side of it.
            let stats = try? await client.sessionStats()
            self?.isSamplingSpeeds = false
            if let stats { self?.applyStats(stats) }
        }
    }

    /// Adopts a `session-stats` reading from either timer: the raw numbers for
    /// the detailed surfaces, the smoothed ones for the menu bar.
    private func applyStats(_ stats: SessionStats) {
        self.stats = stats
        let previousWindow = speedAverager.windowDescription
        if speedAverager.record(stats, at: Date()) {
            menubarSpeeds = speedAverager.displayed
        }
        // Only on a change — two or three lines per transfer. Which window the
        // bar is on is otherwise invisible from the outside, and "the number
        // looks wrong" is impossible to chase without it.
        if speedAverager.windowDescription != previousWindow {
            Log.info("menubar speeds: \(speedAverager.windowDescription ?? "live")")
        }
        updateSpeedTimer()
    }

    func poll() {
        guard !isPolling else { return }
        isPolling = true
        let client = self.client
        let customDirs = config.customDirs.map(\.dir)
        let configuredPrefix = config.mountRemote

        // Inherits this actor, so the `apply*` calls below are already on the
        // main actor; only the client (an actor of its own) needs awaiting.
        Task { [weak self] in
            do {
                let session = try await client.sessionGet(["download-dir"])
                var free: Int64 = -1
                if let dir = session.downloadDir, !dir.isEmpty {
                    // Free space is decoration; never fail the poll over it.
                    free = (try? await client.freeSpace(path: dir)) ?? -1
                }
                let torrents = try await client.torrents()
                let stats = try await client.sessionStats()
                self?.applyPoll(session: session, torrents: torrents, stats: stats,
                                freeSpace: free, customDirs: customDirs,
                                configuredPrefix: configuredPrefix)
            } catch {
                self?.applyPollError(error)
            }
        }
    }

    private func applyPoll(session: SessionSettings, torrents: [Torrent], stats: SessionStats,
                           freeSpace: Int64, customDirs: [String], configuredPrefix: String) {
        isPolling = false
        self.torrents = torrents
        self.freeSpace = freeSpace
        self.serverDownloadDir = session.downloadDir ?? ""
        let wasConnected = self.connected
        self.connected = true
        // After `connected`, which decides whether the speed tick may run.
        applyStats(stats)
        self.errorMessage = nil
        self.lastUpdated = Date()
        self.localNetworkRetries = 0
        if !wasConnected {
            Log.info("connected to \(self.config.rpcURL) — \(torrents.count) torrents")
        }

        // Remote prefix for path mapping: the explicit setting, else the common
        // root of the default download dir and all custom dirs (so torrents in
        // /data/complete and /data/tv both map through /data).
        if !configuredPrefix.isEmpty {
            remotePrefix = configuredPrefix
        } else {
            let candidates = [serverDownloadDir] + customDirs
            remotePrefix = Format.commonRemoteRoot(candidates) ?? serverDownloadDir
        }

        // Drop selections for torrents that no longer exist.
        let live = Set(torrents.map(\.id))
        selectedIDs.formIntersection(live)
        expandedIDs.formIntersection(live)

        notifyNewlyFinished(torrents)
    }

    /// How many times a launch-time local-network block has been retried.
    private var localNetworkRetries = 0
    private static let maxLocalNetworkRetries = 4

    private func applyPollError(_ error: Error) {
        isPolling = false
        let wasConnected = connected
        connected = false

        // Every launch races the Local Network permission: the first poll fires
        // before the Bonjour browse has established access, so it comes back
        // blocked and then works a fraction of a second later. Retry quietly
        // instead of flashing "Disconnected" — but give up after a few tries so
        // a genuinely denied permission still surfaces its actionable message.
        if (error as? TransmissionError) == .localNetworkBlocked,
           localNetworkRetries < Self.maxLocalNetworkRetries {
            localNetworkRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.poll()
            }
            return
        }

        // A real disconnect ends the transfer as far as the menu bar is
        // concerned: drop the window rather than let a stale average sit there,
        // and let the reconnect start again from live.
        speedAverager.reset()
        menubarSpeeds = .zero
        updateSpeedTimer()

        let reason = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
        let message = "Can't reach \(config.host) — \(reason)"
        // The popover has room for one line; the log gets the whole story,
        // including the underlying NSError domain/code that distinguishes DNS
        // failure from connection refused from a denied Local Network grant.
        // Only on a change, though: an unreachable server polls forever, and a
        // line every 30 s would bury whatever you're actually looking for.
        if wasConnected || errorMessage != message {
            Log.error("poll failed against \(config.rpcURL): \(reason) [\(String(describing: error))]")
        }
        errorMessage = message
    }

    private func notifyNewlyFinished(_ torrents: [Torrent]) {
        let finished = Set(torrents.filter { $0.percentDone >= 1 }.map(\.id))
        if let previous = finishedIDs, config.notifyOnFinish {
            for torrent in torrents where finished.contains(torrent.id) && !previous.contains(torrent.id) {
                Notifier.post(title: "Download complete", body: torrent.name)
            }
        }
        finishedIDs = finished
    }

    // MARK: Derived views of the data

    /// Torrents matching the current search, grouped and ordered exactly like
    /// the Linux popup: Error first, then Downloading / Verifying / Seeding /
    /// Paused / Finished, server order within each group.
    var groups: [(name: String, torrents: [Torrent])] {
        Torrent.grouped(torrents, matching: searchText)
    }

    /// Flattened visual order — what shift-click ranges walk over.
    var visualOrder: [Int] { groups.flatMap { $0.torrents.map(\.id) } }

    var selectedInVisualOrder: [Int] { visualOrder.filter { selectedIDs.contains($0) } }

    func torrent(id: Int) -> Torrent? { torrents.first { $0.id == id } }

    /// How the menu bar's numbers are being derived right now, or nil while
    /// they're live readings. The tooltip says it out loud, because the bar and
    /// the footer will otherwise disagree with no explanation.
    var menubarWindowDescription: String? { speedAverager.windowDescription }

    /// Aggregate footer line: speeds, count, and the server's free space.
    var footerSummary: String {
        var parts = ["↓ \(Format.speed(stats.downloadSpeed))",
                     "↑ \(Format.speed(stats.uploadSpeed))",
                     "\(torrents.count) torrent\(torrents.count == 1 ? "" : "s")"]
        if freeSpace >= 0 { parts.append("\(Format.size(freeSpace)) free") }
        return parts.joined(separator: "   ")
    }

    // MARK: Selection

    func select(id: Int, modifiers: EventModifiers) {
        let gesture: Selection.Gesture
        if modifiers.contains(.shift) {
            gesture = .extend
        } else if modifiers.contains(.command) {
            gesture = .toggle
        } else {
            gesture = .replace
        }
        let result = Selection.apply(gesture, to: id, current: selectedIDs,
                                     anchor: anchorID, order: visualOrder)
        selectedIDs = result.selection
        anchorID = result.anchor
        // Every click moves the cursor, including a shift-click: arrowing on
        // from a shift-clicked row continues from where the click landed.
        cursorID = id
    }

    /// Keyboard navigation: Up (-1) / Down (+1) walk the visible list. A plain
    /// arrow lands on exactly what a plain click would produce; with `extend`
    /// (Shift held) the anchor stays put and the range grows or shrinks toward
    /// the new row, exactly as a shift-click on it would.
    func moveSelection(_ direction: Int, extend: Bool = false) {
        guard let id = Selection.step(direction, current: selectedIDs,
                                      cursor: cursorID, order: visualOrder) else { return }
        select(id: id, modifiers: extend ? [.shift] : [])
        scrollTarget = id
    }

    /// Consumed by the list once it has scrolled the row into view.
    func clearScrollTarget() { scrollTarget = nil }

    /// Drop the selection along with the anchor and cursor that go with it, so
    /// the next arrow key starts from the top (Down) or bottom (Up) again.
    func clearSelection() {
        selectedIDs.removeAll()
        anchorID = nil
        cursorID = nil
    }

    /// A right-click acts on the selection when the clicked row is part of it,
    /// otherwise it selects that row first — standard list-view behavior.
    func contextTargets(clicked id: Int) -> [Int] {
        if !selectedIDs.contains(id) {
            selectedIDs = [id]
            anchorID = id
        }
        return selectedInVisualOrder
    }

    func toggleExpanded(_ id: Int) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    // MARK: Actions

    /// Run one RPC action, then re-poll so the UI reflects it immediately.
    /// Failures surface as a notification rather than blocking the popover.
    func perform(_ description: String, _ operation: @escaping (TransmissionClient) async throws -> Void) {
        let client = self.client
        Task { [weak self] in
            do {
                try await operation(client)
                await MainActor.run { self?.poll() }
            } catch {
                let reason = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { Notifier.post(title: description, body: reason) }
            }
        }
    }

    func start(_ ids: [Int]) { perform("Couldn't resume") { try await $0.start(ids) } }
    func stop(_ ids: [Int]) { perform("Couldn't pause") { try await $0.stop(ids) } }
    func startAll() { perform("Couldn't start all") { try await $0.start(nil) } }
    func stopAll() { perform("Couldn't pause all") { try await $0.stop(nil) } }
    func verify(_ ids: [Int]) { perform("Couldn't verify") { try await $0.verify(ids) } }
    func reannounce(_ ids: [Int]) { perform("Couldn't reannounce") { try await $0.reannounce(ids) } }

    func remove(_ ids: [Int], deleteData: Bool) {
        selectedIDs.subtract(ids)
        perform("Couldn't remove") { try await $0.remove(ids, deleteData: deleteData) }
    }

    /// Add a magnet URI or a local `.torrent` path, announcing the outcome the
    /// way the Linux tray does.
    /// Flash the "added" glyph. Re-adding within the window restarts the clock
    /// rather than stacking timers, so a batch of dropped files shows one
    /// continuous "+" instead of flickering.
    private func flashAdded() {
        addedExpiry?.cancel()
        recentlyAdded = true
        let expiry = DispatchWorkItem { [weak self] in self?.recentlyAdded = false }
        addedExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + TrayIcon.addedDuration, execute: expiry)
    }

    func add(link: String, downloadDir: String?, paused: Bool) {
        let client = self.client
        let fallbackName = Format.linkDisplayName(link)
        let announce = config.notifyOnAdd
        Task { [weak self] in
            do {
                let outcome = try await client.add(link, downloadDir: downloadDir, paused: paused)
                await MainActor.run {
                    if announce {
                        let title = outcome.kind == .added ? "Torrent added" : "Already in Transmission"
                        Notifier.post(title: title,
                                      body: outcome.name.isEmpty ? fallbackName : outcome.name)
                    }
                    // Only a genuinely new torrent flashes the "+". A duplicate
                    // changed nothing, so claiming otherwise would be a lie.
                    if outcome.kind == .added { self?.flashAdded() }
                    self?.poll()
                }
            } catch {
                let reason = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    Notifier.post(title: "Failed to add torrent", body: "\(fallbackName)\n\(reason)")
                }
            }
        }
    }

    // MARK: Configuration

    /// Adopt an edited config: persist it, rebuild the client, and re-poll.
    func apply(_ newConfig: Config) {
        config = newConfig
        config.save()
        client = TransmissionClient(config: config)
        finishedIDs = nil          // don't announce the existing backlog
        connected = false
        // A new server means new numbers; the old window describes nothing.
        speedAverager.reset()
        menubarSpeeds = .zero
        startTimer()
        updateSpeedTimer()
        poll()
    }

    /// Persist a single field without disturbing the connection (used by the
    /// add dialog remembering its last destination).
    func updateConfig(_ mutate: (inout Config) -> Void) {
        var updated = config
        mutate(&updated)
        guard updated != config else { return }
        config = updated
        config.save()
    }

    // MARK: Clipboard magnet offer

    private var clipboardText: String {
        NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Open the panel with a magnet link copied and it offers to add it —
    /// Fragments' trick, ported.
    func refreshClipboardOffer() {
        let text = clipboardText
        clipboardOffer = (text.hasPrefix("magnet:") && text != dismissedClipboard) ? text : nil
    }

    func dismissClipboardOffer() {
        dismissedClipboard = clipboardOffer ?? clipboardText
        clipboardOffer = nil
    }

    /// The "Add magnet from clipboard" action, shared by the banner, the add
    /// menu and the status-item context menu.
    func clipboardMagnet() -> String? {
        let text = clipboardText
        return text.hasPrefix("magnet:") ? text : nil
    }

    func copyMagnets(for ids: [Int]) {
        let links = ids.compactMap { torrent(id: $0)?.magnetLink }.filter { !$0.isEmpty }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        Notifier.post(title: "Copied",
                      body: "\(links.count) magnet link\(links.count == 1 ? "" : "s")")
    }

    // MARK: Reveal in Finder

    /// Where this torrent's data lives on *this* Mac, or nil when the share
    /// isn't mounted / mapped. Only ever returns a path that exists.
    func localDirectory(for id: Int) -> String? {
        guard let torrent = torrent(id: id) else { return nil }
        return Format.resolveLocalPath(remoteDir: torrent.downloadDir,
                                       remotePrefix: remotePrefix,
                                       localPrefix: config.mountLocal,
                                       exists: directoryExists)
    }

    /// Reveal the torrent's own file/folder in Finder, falling back to opening
    /// the containing directory when the item isn't there (yet).
    func revealInFinder(_ id: Int) {
        guard let dir = localDirectory(for: id) else { return }
        let name = torrent(id: id)?.name ?? ""
        let item = name.isEmpty ? "" : "\(dir)/\(name)"
        if !item.isEmpty, pathExists(item) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    func canReveal(_ id: Int) -> Bool { localDirectory(for: id) != nil }

    func openWebInterface() {
        guard let url = URL(string: config.webURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
