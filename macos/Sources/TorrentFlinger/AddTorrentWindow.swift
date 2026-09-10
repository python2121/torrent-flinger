#if os(macOS)
import AppKit
import SwiftUI

/// "Save in folder" dialog shown when a magnet or `.torrent` arrives — a port
/// of `linux/flinger/ui/add_dialog.py`. One window per incoming link, so a batch of
/// dropped files doesn't queue behind a single modal.
@MainActor
final class AddTorrentWindowController {
    private let store: TorrentStore
    private var open: [UUID: HostedWindow] = [:]

    init(store: TorrentStore) { self.store = store }

    func present(link: String) {
        let token = UUID()
        let hosted = HostedWindow()
        let model = AddTorrentViewModel(store: store, link: link)
        model.onFinish = { [weak self] in
            self?.open[token]?.close()
            self?.open[token] = nil
        }
        hosted.onClose = { [weak self] in self?.open[token] = nil }
        open[token] = hosted
        hosted.present(title: "Add torrent",
                       size: NSSize(width: 460, height: 210),
                       resizable: false,
                       root: AddTorrentView(model: model))
        Task { await model.load() }
    }
}

@MainActor
final class AddTorrentViewModel: ObservableObject {
    /// nil = "< Default Directory >" (let the server decide).
    @Published var selectedDir: String?
    @Published var paused: Bool
    @Published private(set) var freeSpaceText = ""
    @Published private(set) var tvHint: String?

    let torrentName: String
    let choices: [CustomDir]

    private let store: TorrentStore
    private let link: String
    var onFinish: () -> Void = {}

    init(store: TorrentStore, link: String) {
        self.store = store
        self.link = link
        self.torrentName = Format.linkDisplayName(link)
        self.choices = store.config.customDirs
        self.paused = store.config.startPaused

        // Always start on the server default; only a TV-looking name moves the
        // selection, to the folder flagged as the final TV location.
        let (isTV, reason) = TVDetect.looksLikeTV(torrentName)
        if isTV, let tvDir = TVDetect.findTVDir(choices), choices.contains(where: { $0.dir == tvDir }) {
            selectedDir = tvDir
            tvHint = "Looks like a TV show (\(reason?.rawValue ?? "")) — suggested the TV folder"
        }
    }

    func load() async {
        await updateFreeSpace()
    }

    /// Free space for the selected destination — Tremotesf's add-dialog touch.
    func updateFreeSpace() async {
        let directory = selectedDir ?? store.serverDownloadDir
        guard !directory.isEmpty else {
            freeSpaceText = ""
            return
        }
        if let bytes = try? await store.client.freeSpace(path: directory), bytes >= 0 {
            freeSpaceText = "\(Format.size(bytes)) free"
        } else {
            freeSpaceText = ""
        }
    }

    func save() {
        store.add(link: link, downloadDir: selectedDir, paused: paused)
        onFinish()
    }

    func cancel() { onFinish() }
}

struct AddTorrentView: View {
    @ObservedObject var model: AddTorrentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.torrentName)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Picker("Save in folder:", selection: $model.selectedDir) {
                Text("< Default Directory >").tag(String?.none)
                ForEach(model.choices) { entry in
                    Text("\(entry.displayLabel) (\(entry.dir))").tag(String?.some(entry.dir))
                }
            }
            .onChange(of: model.selectedDir) { _, _ in
                Task { await model.updateFreeSpace() }
            }

            if let hint = model.tvHint {
                Label(hint, systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.freeSpaceText.isEmpty {
                Text(model.freeSpaceText).font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Add in paused state", isOn: $model.paused)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
#endif
