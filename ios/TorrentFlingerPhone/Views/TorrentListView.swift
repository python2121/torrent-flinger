import SwiftUI
import TorrentFlingerCore
import UIKit
import UniformTypeIdentifiers

/// The status-grouped torrent list — the phone's main screen. Swipe a row to
/// pause, resume or remove it; tap it for the detail screen; Select for
/// batch actions. The footer mirrors the Mac popover's: aggregate speeds,
/// count and free space, or the connection error.
struct TorrentListView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var path = NavigationPath()
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int>()
    /// The torrents a remove is being confirmed for.
    @State private var removing: [Int]?
    @State private var showingMagnetEntry = false
    @State private var magnetDraft = ""
    @State private var showingFilePicker = false

    private static let torrentType = UTType(importedAs: "org.bittorrent.torrent")

    /// Screens reachable from the overflow menu, pushed onto this stack.
    enum Screen: Hashable {
        case stats, settings
    }

    /// Named struct rather than the `(name:, torrents:)` tuple so `ForEach`
    /// can see a section's contents change.
    private struct GroupItem: Identifiable, Equatable {
        let name: String
        let torrents: [Torrent]
        var id: String { name }
    }

    private var groups: [GroupItem] {
        store.groups.map { GroupItem(name: $0.name, torrents: $0.torrents) }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            list
        }
    }

    private var list: some View {
        @Bindable var store = store
        // The selection binding is only handed over in Select mode. Outside
        // it, a selectable List takes the tap itself — the row highlights and
        // the NavigationLink never fires.
        return List(selection: editMode == .active ? $selection : nil) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.torrents) { torrent in
                        NavigationLink(value: torrent.id) {
                            TorrentRowView(torrent: torrent)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if torrent.isPaused {
                                Button("Resume", systemImage: "play.fill") { store.start([torrent.id]) }
                                    .tint(StateColor.positive)
                            } else {
                                Button("Pause", systemImage: "pause.fill") { store.stop([torrent.id]) }
                                    .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                removing = [torrent.id]
                            }
                        }
                        .tag(torrent.id)
                    }
                } header: {
                    Text("\(group.name) · \(group.torrents.count)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Torrents")
        .navigationDestination(for: Int.self) { id in
            TorrentDetailView(torrentID: id)
        }
        .navigationDestination(for: Screen.self) { screen in
            switch screen {
            case .stats: StatsView()
            case .settings: SettingsView(mode: .settings)
            }
        }
        .onAppear(perform: applyDebugScreen)
        .onChange(of: store.hasPolled) { _, polled in
            if polled { applyDebugScreen() }
        }
        .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search torrents")
        .refreshable { await store.poll() }
        .overlay { if groups.isEmpty { placeholder } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode != .active { footer }
        }
        .toolbar { toolbarContent }
        .environment(\.editMode, $editMode)
        .onChange(of: store.torrents.map(\.id)) { _, ids in
            // Drop selections for torrents that vanished server-side.
            selection = selection.filter { ids.contains($0) }
        }
        .confirmationDialog(removeTitle, isPresented: removeBinding, titleVisibility: .visible) {
            Button("Remove torrent", role: .destructive) { commitRemove(deleteData: false) }
            Button("Remove and delete data", role: .destructive) { commitRemove(deleteData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeNames)
        }
        .alert("Add magnet link", isPresented: $showingMagnetEntry) {
            TextField("magnet:?xt=urn:btih:…", text: $magnetDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { submitMagnet(magnetDraft) }
            Button("Cancel", role: .cancel) { magnetDraft = "" }
        }
        .fileImporter(isPresented: $showingFilePicker,
                      allowedContentTypes: [Self.torrentType, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.receive(fileURL: url) }
        }
    }

    /// Debug builds honour `-debugScreen stats|settings|detail|detail:<tab>`
    /// as a launch argument (`simctl launch … -debugScreen detail:files`) so
    /// screens can be captured without driving the simulator by hand. `detail`
    /// opens the largest torrent once the first poll has landed. No-op in
    /// release.
    private func applyDebugScreen() {
        #if DEBUG
        guard let screen = UserDefaults.standard.string(forKey: "debugScreen"), path.isEmpty else { return }
        switch screen {
        case "stats": path.append(Screen.stats)
        case "settings": path.append(Screen.settings)
        default:
            guard screen.hasPrefix("detail"),
                  let largest = store.torrents.max(by: { $0.totalSize < $1.totalSize })
            else { return }
            path.append(largest.id)
        }
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(editMode == .active ? "Done" : "Select") {
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                    selection = []
                }
            }
            .disabled(store.torrents.isEmpty && editMode != .active)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Paste magnet link", systemImage: "doc.on.clipboard") { pasteMagnet() }
                Button("Enter magnet link…", systemImage: "link") { showingMagnetEntry = true }
                Button("Choose .torrent file…", systemImage: "doc") { showingFilePicker = true }
            } label: {
                Label("Add torrent", systemImage: "plus")
            }
            Menu {
                Button("Start all", systemImage: "play") { store.startAll() }
                Button("Pause all", systemImage: "pause") { store.stopAll() }
                Divider()
                Button("Open web interface", systemImage: "globe") {
                    if let url = URL(string: store.config.webURL) { openURL(url) }
                }
                Divider()
                Button("Statistics", systemImage: "chart.bar") { path.append(Screen.stats) }
                Button("Settings", systemImage: "gearshape") { path.append(Screen.settings) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        if editMode == .active {
            ToolbarItemGroup(placement: .bottomBar) {
                let ids = selectedInVisualOrder
                let picked = ids.compactMap { store.torrent(id: $0) }
                Button("Resume", systemImage: "play.fill") { store.start(ids) }
                    .disabled(!picked.contains(where: \.isPaused))
                Spacer()
                Text(ids.isEmpty ? "Select torrents" : "\(ids.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Pause", systemImage: "pause.fill") { store.stop(ids) }
                    .disabled(!picked.contains(where: { !$0.isPaused }))
                Button("Remove", systemImage: "trash", role: .destructive) { removing = ids }
                    .disabled(ids.isEmpty)
            }
        }
    }

    /// The selection in the order the list shows it, so a batch reads the
    /// way the user sees it.
    private var selectedInVisualOrder: [Int] {
        groups.flatMap { $0.torrents.map(\.id) }.filter { selection.contains($0) }
    }

    // MARK: Footer & placeholder

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.connected ? StateColor.positive : StateColor.negative)
                .frame(width: 7, height: 7)
            Text(store.connected ? store.summary : (store.errorMessage ?? "Connecting…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !store.hasPolled {
            ProgressView("Connecting…")
        } else if let error = store.errorMessage, !store.connected, store.torrents.isEmpty {
            ContentUnavailableView {
                Label("Disconnected", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await store.poll() } }
                    .buttonStyle(.bordered)
            }
        } else if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else {
            ContentUnavailableView {
                Label("No torrents", systemImage: "tray")
            } description: {
                Text("Tap + to add a magnet link or a .torrent file, or open one from Safari.")
            }
        }
    }

    // MARK: Adding

    private func pasteMagnet() {
        let board = UIPasteboard.general
        guard board.hasStrings || board.hasURLs else {
            store.show(.init(title: "Clipboard is empty", isError: true))
            return
        }
        let text = (board.string ?? board.url?.absoluteString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("magnet:") else {
            store.show(.init(title: "No magnet link on the clipboard", isError: true))
            return
        }
        store.receive(magnet: text)
    }

    private func submitMagnet(_ text: String) {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        magnetDraft = ""
        guard link.lowercased().hasPrefix("magnet:") else {
            store.show(.init(title: "That isn't a magnet link", isError: true))
            return
        }
        store.receive(magnet: link)
    }

    // MARK: Removing

    private var removeBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var removeTitle: String {
        let count = removing?.count ?? 0
        return count == 1 ? "Remove this torrent?" : "Remove \(count) torrents?"
    }

    private var removeNames: String {
        let names = (removing ?? []).compactMap { store.torrent(id: $0)?.name }
        if names.count <= 3 { return names.joined(separator: "\n") }
        return names.prefix(3).joined(separator: "\n") + "\n…and \(names.count - 3) more"
    }

    private func commitRemove(deleteData: Bool) {
        guard let ids = removing else { return }
        removing = nil
        store.remove(ids, deleteData: deleteData)
        if editMode == .active {
            withAnimation { editMode = .inactive }
            selection = []
        }
    }
}
