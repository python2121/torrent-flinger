import SwiftUI
import TorrentFlingerCore
import UIKit

/// Per-torrent administration: Info / Files / Peers / Trackers / Options,
/// refreshed every 3 s while on screen, with the actions in a toolbar menu.
/// Closes itself when the torrent disappears server-side.
@Observable
@MainActor
final class DetailModel {
    static let refreshInterval: Duration = .seconds(3)
    static let priorityNames: [Int: String] = [-1: "Low", 0: "Normal", 1: "High"]
    static let priorityArgs: [Int: String] = [-1: "priority-low", 0: "priority-normal", 1: "priority-high"]

    let torrentID: Int
    private(set) var torrent: Torrent?
    private(set) var fileTree: [FileNode] = []
    private(set) var errorText = ""
    private(set) var gone = false

    /// The Options tab's fields. Edited locally, pushed with Apply.
    struct OptionValues: Equatable {
        var downloadLimited = false
        var downloadLimit = 100
        var uploadLimited = false
        var uploadLimit = 100
        var ratioMode = 0
        var ratioLimit = 2.0
        var peerLimit = 50

        init() {}

        init(_ t: Torrent) {
            downloadLimited = t.downloadLimited ?? false
            downloadLimit = t.downloadLimit ?? 100
            uploadLimited = t.uploadLimited ?? false
            uploadLimit = t.uploadLimit ?? 100
            ratioMode = t.seedRatioMode ?? 0
            ratioLimit = t.seedRatioLimit ?? 2.0
            peerLimit = t.peerLimit ?? 50
        }
    }

    var options = OptionValues()
    /// What the server last reported. The fields diverging from it is what
    /// "mid-edit" means — tracked by value rather than by `onChange`, because
    /// the poll filling the fields in would otherwise count as an edit and
    /// freeze them on their first values.
    private(set) var serverOptions = OptionValues()
    var editingOptions: Bool { options != serverOptions }

    @ObservationIgnored private weak var store: PhoneStore?
    @ObservationIgnored private var inflight = false

    init(torrentID: Int) { self.torrentID = torrentID }

    func attach(_ store: PhoneStore) { self.store = store }

    /// Runs until the hosting view's `.task` is cancelled.
    func run() async {
        while !Task.isCancelled && !gone {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh() async {
        guard let store, !inflight else { return }
        inflight = true
        defer { inflight = false }
        do {
            apply(try await store.client.torrentDetails(torrentID))
        } catch {
            if (error as? TransmissionError) == .notFound(torrentID) {
                gone = true
            } else {
                errorText = store.describe(error)
            }
        }
    }

    private func apply(_ torrent: Torrent) {
        self.torrent = torrent
        errorText = torrent.errorString
        if let files = torrent.files {
            fileTree = FileNode.tree(files: files, stats: torrent.fileStats ?? [])
        }
        // Leave the fields alone while the user has unapplied edits.
        let wasEditing = editingOptions
        serverOptions = OptionValues(torrent)
        if !wasEditing { options = serverOptions }
    }

    // MARK: Actions

    private func act(_ failure: String, _ operation: @escaping (TransmissionClient) async throws -> Void) {
        guard let store else { return }
        let client = store.client
        Task {
            do {
                try await operation(client)
                await refresh()
                await store.poll()
            } catch {
                errorText = "\(failure): \(store.describe(error))"
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
        act("File update failed") { try await $0.torrentSet([self.torrentID], [key: .ints(indices)]) }
    }

    func setPriority(_ indices: [Int], priority: Int) {
        guard !indices.isEmpty, let key = Self.priorityArgs[priority] else { return }
        act("Priority update failed") { try await $0.torrentSet([self.torrentID], [key: .ints(indices)]) }
    }

    func applyOptions() {
        let o = options
        let args: [String: JSONValue] = [
            "downloadLimited": .bool(o.downloadLimited),
            "downloadLimit": .int(o.downloadLimit),
            "uploadLimited": .bool(o.uploadLimited),
            "uploadLimit": .int(o.uploadLimit),
            "seedRatioMode": .int(o.ratioMode),
            "seedRatioLimit": .double(o.ratioLimit),
            "peer-limit": .int(o.peerLimit),
        ]
        // Treat the edit as landed so the next poll's values are accepted.
        serverOptions = o
        act("Apply failed") { try await $0.torrentSet([self.torrentID], args) }
    }

    func setLocation(_ path: String, move: Bool) {
        let location = path.trimmingCharacters(in: .whitespaces)
        guard !location.isEmpty else { return }
        act("Set location failed") { try await $0.setLocation([self.torrentID], location: location, move: move) }
    }

    func remove(deleteData: Bool) {
        store?.remove([torrentID], deleteData: deleteData)
        gone = true
    }
}

struct TorrentDetailView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var model: DetailModel
    @State private var tab = Tab.info
    @State private var showingSetLocation = false
    @State private var confirmingRemove = false

    enum Tab: String, CaseIterable, Identifiable {
        case info, files, peers, trackers, options
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    init(torrentID: Int) {
        _model = State(initialValue: DetailModel(torrentID: torrentID))
        #if DEBUG
        // `-debugScreen detail:files` opens straight onto a tab; see RootView.
        if let screen = UserDefaults.standard.string(forKey: "debugScreen"),
           let name = screen.split(separator: ":").dropFirst().first,
           let tab = Tab(rawValue: String(name)) {
            _tab = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        Group {
            switch tab {
            case .info: infoList
            case .files: filesList
            case .peers: peersList
            case .trackers: trackersList
            case .options: optionsForm
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(StateColor.negative)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle(model.torrent?.name ?? store.torrent(id: model.torrentID)?.name ?? "Torrent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        }
        .task {
            model.attach(store)
            await model.run()
        }
        .onChange(of: model.gone) { _, gone in
            if gone { dismiss() }
        }
        .sheet(isPresented: $showingSetLocation) {
            SetLocationSheet(current: model.torrent?.downloadDir ?? "") { path, move in
                model.setLocation(path, move: move)
            }
        }
        .confirmationDialog("Remove this torrent?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove torrent", role: .destructive) { model.remove(deleteData: false) }
            Button("Remove and delete data", role: .destructive) { model.remove(deleteData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.torrent?.name ?? "")
        }
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            if model.torrent?.isPaused ?? false {
                Button("Resume", systemImage: "play.fill") { model.resume() }
            } else {
                Button("Pause", systemImage: "pause.fill") { model.pause() }
            }
            Button("Verify local data", systemImage: "checkmark.shield") { model.verify() }
            Button("Reannounce", systemImage: "antenna.radiowaves.left.and.right") { model.reannounce() }
            Button("Set location…", systemImage: "folder") { showingSetLocation = true }
            if let magnet = model.torrent?.magnetLink, !magnet.isEmpty {
                Divider()
                Button("Copy magnet link", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = magnet
                    store.show(.init(title: "Copied magnet link"))
                }
                ShareLink(item: magnet) {
                    Label("Share magnet link", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemove = true }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Info

    private var infoList: some View {
        List {
            if let t = model.torrent {
                Section {
                    HStack(spacing: 12) {
                        StateBadge(state: t.state, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusLine(t)).font(.subheadline.weight(.medium))
                            Text(progressLine(t)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            ProgressGauge(fraction: t.displayFraction, color: StateColor.color(for: t.state))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Transfer") {
                    let done = (t.haveValid ?? 0) + (t.haveUnchecked ?? 0)
                    let size = t.sizeWhenDone > 0 ? t.sizeWhenDone : t.totalSize
                    LabeledContent("Have", value: "\(Format.size(done)) of \(Format.size(size))")
                    LabeledContent("Downloaded", value: downloadedText(t))
                    LabeledContent("Uploaded", value: Format.size(t.uploadedEver))
                    LabeledContent("Ratio", value: String(format: "%.2f", max(t.uploadRatio, 0)))
                    LabeledContent("Peers", value: "\(t.peersConnected) connected")
                    LabeledContent("Pieces", value: "\(t.pieceCount ?? 0) × \(Format.size(t.pieceSize ?? 0))")
                    LabeledContent("Privacy", value: (t.isPrivate ?? false) ? "Private" : "Public")
                }
                Section("Dates") {
                    LabeledContent("Added", value: Format.date(t.addedDate))
                    LabeledContent("Completed", value: Format.date(t.doneDate))
                    LabeledContent("Last activity", value: Format.date(t.activityDate))
                    LabeledContent("Created", value: createdText(t))
                }
                Section("Details") {
                    DetailRow(key: "Location", value: t.downloadDir)
                    if let comment = t.comment, !comment.isEmpty {
                        DetailRow(key: "Comment", value: comment)
                    }
                    DetailRow(key: "Hash", value: t.hashString ?? "")
                    if !t.errorString.isEmpty {
                        DetailRow(key: "Error", value: t.errorString)
                            .foregroundStyle(StateColor.negative)
                    }
                }
            } else {
                Section { ProgressView("Loading…").frame(maxWidth: .infinity) }
            }
        }
        .monospacedDigit()
    }

    private func statusLine(_ t: Torrent) -> String {
        var status = Format.statusName(t.status)
        let eta = Format.eta(t.eta)
        if !eta.isEmpty, t.status == TorrentStatus.downloading { status += " — \(eta) remaining" }
        return status
    }

    private func progressLine(_ t: Torrent) -> String {
        var parts = [String(format: "%.1f%%", t.percentDone * 100)]
        if t.rateDownload > 0 { parts.append("↓ \(Format.speed(t.rateDownload))") }
        if t.rateUpload > 0 { parts.append("↑ \(Format.speed(t.rateUpload))") }
        return parts.joined(separator: " · ")
    }

    private func downloadedText(_ t: Torrent) -> String {
        var text = Format.size(t.downloadedEver)
        if let corrupt = t.corruptEver, corrupt > 0 { text += " (\(Format.size(corrupt)) corrupt)" }
        return text
    }

    private func createdText(_ t: Torrent) -> String {
        var created = Format.date(t.dateCreated)
        if let creator = t.creator, !creator.isEmpty { created += " by \(creator)" }
        return created
    }

    // MARK: Files

    private var filesList: some View {
        Group {
            if model.fileTree.isEmpty {
                if model.torrent == nil {
                    ProgressView("Loading…")
                } else {
                    ContentUnavailableView("No files yet", systemImage: "doc",
                                           description: Text("The file list appears once the metadata has been fetched."))
                }
            } else {
                // Folders aggregate everything underneath and their checkbox
                // applies to the whole subtree — one call instead of hundreds.
                List(model.fileTree, children: \.children) { node in
                    fileRow(node)
                }
            }
        }
    }

    private func fileRow(_ node: FileNode) -> some View {
        HStack(spacing: 10) {
            Button {
                model.setWanted(node.indices, wanted: node.wanted.toggled)
            } label: {
                Image(systemName: checkboxSymbol(node.wanted))
                    .font(.title3)
                    .foregroundStyle(node.wanted == .off ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? Color.accentColor.opacity(0.8) : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(fileSubtitle(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contextMenu {
            Button("High priority", systemImage: "arrow.up") { model.setPriority(node.indices, priority: 1) }
            Button("Normal priority", systemImage: "minus") { model.setPriority(node.indices, priority: 0) }
            Button("Low priority", systemImage: "arrow.down") { model.setPriority(node.indices, priority: -1) }
            Divider()
            Button("Download", systemImage: "checkmark.square") { model.setWanted(node.indices, wanted: true) }
            Button("Skip", systemImage: "square") { model.setWanted(node.indices, wanted: false) }
        }
    }

    private func fileSubtitle(_ node: FileNode) -> String {
        var parts = [Format.size(node.length), node.donePercent]
        if let priority = node.priority {
            if priority != 0 { parts.append("\(DetailModel.priorityNames[priority] ?? "") priority") }
        } else {
            parts.append("mixed priority")
        }
        if node.isDirectory { parts.append(node.indices.count == 1 ? "1 file" : "\(node.indices.count) files") }
        return parts.joined(separator: " · ")
    }

    private func checkboxSymbol(_ state: FileNode.Wanted) -> String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }

    // MARK: Peers

    private var peersList: some View {
        Group {
            let peers = model.torrent?.peers ?? []
            if peers.isEmpty {
                ContentUnavailableView("No peers", systemImage: "person.2",
                                       description: Text("Nobody is connected to this torrent right now."))
            } else {
                List(peers) { peer in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(peer.address).font(.subheadline.monospaced())
                            Spacer()
                            Text(String(format: "%.0f%%", peer.progress * 100))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(peer.clientName.isEmpty ? "Unknown client" : peer.clientName)
                            if !peer.flagStr.isEmpty { Text(peer.flagStr).monospaced() }
                            Spacer()
                            if peer.rateToClient > 0 { Text("↓ \(Format.speed(peer.rateToClient))") }
                            if peer.rateToPeer > 0 { Text("↑ \(Format.speed(peer.rateToPeer))") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: Trackers

    private var trackersList: some View {
        Group {
            let trackers = model.torrent?.trackerStats ?? []
            if trackers.isEmpty {
                ContentUnavailableView("No trackers", systemImage: "antenna.radiowaves.left.and.right")
            } else {
                List(trackers) { tracker in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tracker.displayName).font(.subheadline)
                        HStack(spacing: 12) {
                            if tracker.seederCount >= 0 { Text("\(tracker.seederCount) seeders") }
                            if tracker.leecherCount >= 0 { Text("\(tracker.leecherCount) leechers") }
                            Spacer()
                            Text("next \(Format.date(tracker.nextAnnounceTime))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        let result = tracker.lastAnnounceResult
                        if !result.isEmpty {
                            Label(result, systemImage: tracker.lastAnnounceSucceeded ? "checkmark" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(tracker.lastAnnounceSucceeded ? Color.secondary : StateColor.negative)
                        }
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: Options

    private var optionsForm: some View {
        Form {
            Section("Speed limits") {
                Toggle("Limit download", isOn: $model.options.downloadLimited)
                LabeledContent("Download (KB/s)") {
                    TextField("", value: $model.options.downloadLimit, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(!model.options.downloadLimited)
                Toggle("Limit upload", isOn: $model.options.uploadLimited)
                LabeledContent("Upload (KB/s)") {
                    TextField("", value: $model.options.uploadLimit, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(!model.options.uploadLimited)
            }
            Section("Seeding") {
                Picker("Seed ratio", selection: $model.options.ratioMode) {
                    Text("Use global setting").tag(0)
                    Text("Stop at ratio").tag(1)
                    Text("Seed forever").tag(2)
                }
                LabeledContent("Stop at ratio") {
                    TextField("", value: $model.options.ratioLimit, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(model.options.ratioMode != 1)
                LabeledContent("Peer limit") {
                    TextField("", value: $model.options.peerLimit, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section {
                LabeledContent("Position", value: "\(model.torrent?.queuePosition ?? 0)")
                HStack {
                    ForEach(TransmissionClient.QueueDirection.allCases, id: \.self) { direction in
                        Button(queueLabel(direction)) { model.queueMove(direction) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text("Queue")
            }
            Section {
                Button("Apply") { model.applyOptions() }
                    .frame(maxWidth: .infinity)
                    .bold()
                    .disabled(!model.editingOptions)
            } footer: {
                Text(model.editingOptions
                     ? "Changes aren't on the server until you apply them."
                     : "Edit a value above to enable Apply.")
            }
        }
        .monospacedDigit()
    }

    private func queueLabel(_ direction: TransmissionClient.QueueDirection) -> String {
        switch direction {
        case .top: return "⤒"
        case .up: return "↑"
        case .down: return "↓"
        case .bottom: return "⤓"
        }
    }
}

/// Move a torrent's data to another directory on the server.
struct SetLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    var onSet: (String, Bool) -> Void

    @State private var path = ""
    @State private var move = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Path on the server", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Currently in \(current)")
                }
                Section {
                    Toggle("Move data to the new location", isOn: $move)
                } footer: {
                    Text("Off means the data is already there and Transmission should just look for it.")
                }
            }
            .navigationTitle("Set Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        onSet(path, move)
                        dismiss()
                    }
                    .bold()
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if path.isEmpty { path = current } }
        }
        .presentationDetents([.medium])
    }
}
