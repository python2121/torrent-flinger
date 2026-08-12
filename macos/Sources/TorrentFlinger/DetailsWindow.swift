#if os(macOS)
import AppKit
import SwiftUI

/// Per-torrent administration window: Info / Files / Peers / Trackers /
/// Options — a port of `linux/flinger/ui/details_dialog.py`, whose feature set
/// follows the consensus of Tremotesf, transmission-remote-gtk and
/// transmission-qt.
@MainActor
final class DetailsWindowController {
    private let window = HostedWindow()
    private let model: DetailsViewModel
    private let name: String

    /// Called when the user closes the window, so `AppDelegate` can forget it.
    var onClose: (() -> Void)?

    init(store: TorrentStore, torrentID: Int, name: String) {
        self.name = name
        self.model = DetailsViewModel(store: store, torrentID: torrentID)
        model.onGone = { [weak self] in self?.window.close() }
        window.onClose = { [weak self] in
            self?.model.stop()
            self?.onClose?()
        }
    }

    func show() {
        window.present(title: name,
                       size: NSSize(width: 720, height: 560),
                       root: DetailsView(model: model))
        model.start()
    }
}

@MainActor
final class DetailsViewModel: ObservableObject {
    static let refreshInterval: TimeInterval = 3

    @Published private(set) var torrent: Torrent?
    @Published private(set) var errorText = ""

    // Options tab — edited locally, pushed with Apply.
    @Published var downloadLimited = false
    @Published var downloadLimit = 100
    @Published var uploadLimited = false
    @Published var uploadLimit = 100
    @Published var ratioMode = 0
    @Published var ratioLimit = 2.0
    @Published var peerLimit = 50
    /// Suppresses the poll overwriting fields the user is mid-edit on.
    @Published var editingOptions = false

    @Published var showingSetLocation = false
    @Published var locationDraft = ""
    @Published var moveData = true

    enum Tab: String, CaseIterable {
        case info, files, peers, trackers, options
    }

    @Published var selectedTab: Tab = .info

    /// Selected rows, by `FileNode.id` — a row can be a directory, so this
    /// isn't a set of file indices; `FileNode.indices(for:in:)` resolves it.
    @Published var selectedFiles: Set<String> = []

    /// The file list as a tree, rebuilt on each poll. Held rather than computed
    /// per render because a large torrent is a few hundred nodes and the view
    /// reads it on every pass.
    @Published private(set) var fileTree: [FileNode] = []

    let torrentID: Int
    private let store: TorrentStore
    private var timer: Timer?
    private var inflight = false
    var onGone: () -> Void = {}

    init(store: TorrentStore, torrentID: Int) {
        self.store = store
        self.torrentID = torrentID
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !inflight else { return }
        inflight = true
        let client = store.client
        let id = torrentID
        Task { [weak self] in
            do {
                let torrent = try await client.torrentDetails(id)
                await MainActor.run { self?.apply(torrent) }
            } catch {
                let message = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
                let gone = (error as? TransmissionError) == .notFound(id)
                await MainActor.run { self?.applyError(message, gone: gone) }
            }
        }
    }

    private func apply(_ torrent: Torrent) {
        inflight = false
        self.torrent = torrent
        errorText = torrent.errorString
        if let files = torrent.files {
            fileTree = FileNode.tree(files: files, stats: torrent.fileStats ?? [])
        }
        guard !editingOptions else { return }
        downloadLimited = torrent.downloadLimited ?? false
        downloadLimit = torrent.downloadLimit ?? 100
        uploadLimited = torrent.uploadLimited ?? false
        uploadLimit = torrent.uploadLimit ?? 100
        ratioMode = torrent.seedRatioMode ?? 0
        ratioLimit = torrent.seedRatioLimit ?? 2.0
        peerLimit = torrent.peerLimit ?? 50
    }

    private func applyError(_ message: String, gone: Bool) {
        inflight = false
        // Removed on the server — nothing left to administer.
        if gone { stop(); onGone(); return }
        errorText = message
    }

    // MARK: File rows

    static let priorityNames: [Int: String] = [-1: "Low", 0: "Normal", 1: "High"]
    static let priorityArgs: [Int: String] = [-1: "priority-low", 0: "priority-normal", 1: "priority-high"]

    /// File indices behind the rows the context menu should act on: the
    /// right-clicked rows, or the standing selection when the click landed
    /// outside it.
    func fileIndices(for clicked: Set<String>) -> [Int] {
        FileNode.indices(for: clicked.isEmpty ? selectedFiles : clicked, in: fileTree)
    }

    // MARK: Actions

    private func act(_ description: String, _ operation: @escaping (TransmissionClient) async throws -> Void) {
        let client = store.client
        Task { [weak self] in
            do {
                try await operation(client)
                await MainActor.run { self?.refresh(); self?.store.poll() }
            } catch {
                let message = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.errorText = "\(description): \(message)" }
            }
        }
    }

    func pause() { act("Pause failed") { try await $0.stop([self.torrentID]) } }
    func resume() { act("Resume failed") { try await $0.start([self.torrentID]) } }
    func verify() { act("Verify failed") { try await $0.verify([self.torrentID]) } }
    func reannounce() { act("Reannounce failed") { try await $0.reannounce([self.torrentID]) } }

    func queueMove(_ direction: TransmissionClient.QueueDirection) {
        act("Queue move failed") { try await $0.queueMove([self.torrentID], direction) }
    }

    func setWanted(_ indices: [Int], wanted: Bool) {
        guard !indices.isEmpty else { return }
        let key = wanted ? "files-wanted" : "files-unwanted"
        act("File update failed") {
            try await $0.torrentSet([self.torrentID], [key: .ints(indices)])
        }
    }

    func setPriority(_ indices: [Int], priority: Int) {
        guard !indices.isEmpty, let key = Self.priorityArgs[priority] else { return }
        act("Priority update failed") {
            try await $0.torrentSet([self.torrentID], [key: .ints(indices)])
        }
    }

    func applyOptions() {
        let args: [String: JSONValue] = [
            "downloadLimited": .bool(downloadLimited),
            "downloadLimit": .int(downloadLimit),
            "uploadLimited": .bool(uploadLimited),
            "uploadLimit": .int(uploadLimit),
            "seedRatioMode": .int(ratioMode),
            "seedRatioLimit": .double(ratioLimit),
            "peer-limit": .int(peerLimit),
        ]
        editingOptions = false
        act("Apply failed") { try await $0.torrentSet([self.torrentID], args) }
    }

    func beginSetLocation() {
        locationDraft = torrent?.downloadDir ?? ""
        moveData = true
        showingSetLocation = true
    }

    func commitSetLocation() {
        let path = locationDraft.trimmingCharacters(in: .whitespaces)
        showingSetLocation = false
        guard !path.isEmpty else { return }
        let move = moveData
        act("Set location failed") {
            try await $0.setLocation([self.torrentID], location: path, move: move)
        }
    }

    func copyMagnet() {
        store.copyMagnets(for: [torrentID])
    }

    func remove() {
        let name = torrent?.name ?? ""
        guard let deleteData = Dialogs.confirmRemove(what: Dialogs.describe([name])) else { return }
        store.remove([torrentID], deleteData: deleteData)
        stop()
        onGone()
    }
}

struct DetailsView: View {
    @ObservedObject var model: DetailsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionBar
            TabView(selection: $model.selectedTab) {
                infoTab.tabItem { Text("Info") }.tag(DetailsViewModel.Tab.info)
                filesTab.tabItem { Text("Files") }.tag(DetailsViewModel.Tab.files)
                peersTab.tabItem { Text("Peers") }.tag(DetailsViewModel.Tab.peers)
                trackersTab.tabItem { Text("Trackers") }.tag(DetailsViewModel.Tab.trackers)
                optionsTab.tabItem { Text("Options") }.tag(DetailsViewModel.Tab.options)
            }
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.caption)
                    .foregroundStyle(StateColor.negative)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $model.showingSetLocation) { setLocationSheet }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            if model.torrent?.isPaused ?? false {
                Button("Resume") { model.resume() }
            } else {
                Button("Pause") { model.pause() }
            }
            Button("Verify") { model.verify() }
            Button("Reannounce") { model.reannounce() }
            Button("Set location…") { model.beginSetLocation() }
            Button("Copy magnet") { model.copyMagnet() }
            Button("Remove…") { model.remove() }
            Spacer()
        }
    }

    private var setLocationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set torrent location").font(.headline)
            TextField("Location", text: $model.locationDraft)
            Toggle("Move data to the new location", isOn: $model.moveData)
            HStack {
                Spacer()
                Button("Cancel") { model.showingSetLocation = false }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { model.commitSetLocation() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: Info

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(infoRows, id: \.0) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(key)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                        Text(value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
        }
    }

    private var infoRows: [(String, String)] {
        guard let t = model.torrent else { return [("Status", "…")] }
        let done = (t.haveValid ?? 0) + (t.haveUnchecked ?? 0)
        let size = t.sizeWhenDone > 0 ? t.sizeWhenDone : t.totalSize
        let eta = Format.eta(t.eta)
        var status = Format.statusName(t.status)
        if !eta.isEmpty, t.status == TorrentStatus.downloading { status += " — \(eta) remaining" }

        var progress = String(format: "%.1f%%", t.percentDone * 100)
        if t.rateDownload > 0 || t.rateUpload > 0 {
            progress += " (DL \(Format.speed(t.rateDownload)), UL \(Format.speed(t.rateUpload)))"
        }
        var downloaded = Format.size(t.downloadedEver)
        if let corrupt = t.corruptEver, corrupt > 0 {
            downloaded += " (\(Format.size(corrupt)) corrupt)"
        }
        var created = Format.date(t.dateCreated)
        if let creator = t.creator, !creator.isEmpty { created += " by \(creator)" }

        return [
            ("Status", status),
            ("Progress", progress),
            ("Size", "\(Format.size(done)) of \(Format.size(size))"),
            ("Downloaded", downloaded),
            ("Uploaded", "\(Format.size(t.uploadedEver)) (ratio \(String(format: "%.2f", max(t.uploadRatio, 0))))"),
            ("Location", t.downloadDir),
            ("Privacy", (t.isPrivate ?? false) ? "Private torrent" : "Public torrent"),
            ("Pieces", "\(t.pieceCount ?? 0) × \(Format.size(t.pieceSize ?? 0))"),
            ("Added", Format.date(t.addedDate)),
            ("Completed", Format.date(t.doneDate)),
            ("Last activity", Format.date(t.activityDate)),
            ("Created", created),
            ("Comment", t.comment ?? ""),
            ("Hash", t.hashString ?? ""),
            ("Error", t.errorString.isEmpty ? "—" : t.errorString),
        ]
    }

    // MARK: Files

    private var filesTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The outline form of `Table`: folders get a disclosure triangle
            // and their rows aggregate everything underneath, so a 678-file
            // torrent opens as one line you can expand.
            Table(model.fileTree, children: \.children, selection: $model.selectedFiles) {
                TableColumn("") { node in
                    FileCheckbox(state: node.wanted) {
                        model.setWanted(node.indices, wanted: node.wanted.toggled)
                    }
                }
                .width(20)
                TableColumn("File") { node in
                    HStack(spacing: 5) {
                        Image(systemName: node.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                    }
                    .help(node.name)
                }
                TableColumn("Size") { Text(Format.size($0.length)) }
                    .width(80)
                TableColumn("Done") { Text($0.donePercent) }
                    .width(50)
                TableColumn("Priority") { node in
                    // A folder whose files disagree has no one priority to show.
                    Text(node.priority.flatMap { DetailsViewModel.priorityNames[$0] } ?? "Mixed")
                }
                .width(70)
            }
            .contextMenu(forSelectionType: FileNode.ID.self) { selection in
                let indices = model.fileIndices(for: selection)
                Button("High priority") { model.setPriority(indices, priority: 1) }
                Button("Normal priority") { model.setPriority(indices, priority: 0) }
                Button("Low priority") { model.setPriority(indices, priority: -1) }
                Divider()
                Button("Download") { model.setWanted(indices, wanted: true) }
                Button("Skip") { model.setWanted(indices, wanted: false) }
            }
            Text("Checkbox = download this file; on a folder it applies to everything inside. Right-click for priority.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Peers

    private var peersTab: some View {
        Table(model.torrent?.peers ?? []) {
            TableColumn("Address", value: \.address).width(min: 110)
            TableColumn("Client", value: \.clientName)
            TableColumn("Flags", value: \.flagStr).width(60)
            TableColumn("Progress") { Text(String(format: "%.0f%%", $0.progress * 100)) }
                .width(60)
            TableColumn("Down") { Text($0.rateToClient > 0 ? Format.speed($0.rateToClient) : "") }
                .width(80)
            TableColumn("Up") { Text($0.rateToPeer > 0 ? Format.speed($0.rateToPeer) : "") }
                .width(80)
        }
    }

    // MARK: Trackers

    private var trackersTab: some View {
        Table(model.torrent?.trackerStats ?? []) {
            TableColumn("Tracker") { Text($0.displayName) }
            TableColumn("Seeders") { Text("\($0.seederCount)") }.width(60)
            TableColumn("Leechers") { Text("\($0.leecherCount)") }.width(60)
            TableColumn("Last announce") { tracker in
                let text = tracker.lastAnnounceResult.isEmpty ? "—" : tracker.lastAnnounceResult
                Text(!tracker.lastAnnounceSucceeded && text != "—" ? "⚠ \(text)" : text)
            }
            TableColumn("Next announce") { Text(Format.date($0.nextAnnounceTime)) }
                .width(120)
        }
    }

    // MARK: Options

    private var optionsTab: some View {
        Form {
            HStack {
                Toggle("Limit download speed (KB/s)", isOn: $model.downloadLimited)
                TextField("", value: $model.downloadLimit, format: .number.grouping(.never))
                    .frame(width: 90)
            }
            HStack {
                Toggle("Limit upload speed (KB/s)", isOn: $model.uploadLimited)
                TextField("", value: $model.uploadLimit, format: .number.grouping(.never))
                    .frame(width: 90)
            }
            HStack {
                Picker("Seed ratio", selection: $model.ratioMode) {
                    Text("Use global setting").tag(0)
                    Text("Stop at ratio:").tag(1)
                    Text("Seed forever").tag(2)
                }
                TextField("", value: $model.ratioLimit, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
                    .disabled(model.ratioMode != 1)
            }
            TextField("Peer limit", value: $model.peerLimit, format: .number.grouping(.never))
            HStack {
                Text("Queue")
                Text("position \(model.torrent?.queuePosition ?? 0)")
                    .foregroundStyle(.secondary)
                ForEach(TransmissionClient.QueueDirection.allCases, id: \.self) { direction in
                    Button(Self.queueLabel(direction)) { model.queueMove(direction) }
                }
                Spacer()
            }
            Button("Apply") { model.applyOptions() }
        }
        .formStyle(.grouped)
        // Any keystroke in this tab means the user is mid-edit; stop the 3-second
        // poll from stomping on the fields until Apply lands.
        .onChange(of: model.downloadLimit) { _, _ in model.editingOptions = true }
        .onChange(of: model.uploadLimit) { _, _ in model.editingOptions = true }
        .onChange(of: model.ratioLimit) { _, _ in model.editingOptions = true }
        .onChange(of: model.peerLimit) { _, _ in model.editingOptions = true }
    }

    private static func queueLabel(_ direction: TransmissionClient.QueueDirection) -> String {
        switch direction {
        case .top: return "⤒ Top"
        case .up: return "↑ Up"
        case .down: return "↓ Down"
        case .bottom: return "⤓ Bottom"
        }
    }
}

/// The Files tab's check control. `Toggle` has no mixed state, and a folder
/// whose files disagree needs one, so all three states are drawn from SF
/// Symbols — using a real checkbox for files and a symbol for folders would put
/// two different controls in the same column.
struct FileCheckbox: View {
    let state: FileNode.Wanted
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state == .on ? "Skip" : "Download")
    }

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}
#endif
