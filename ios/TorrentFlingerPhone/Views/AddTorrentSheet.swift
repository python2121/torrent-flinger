import SwiftUI
import TorrentFlingerCore

/// "Save in folder" for an incoming magnet or `.torrent` — the Mac add
/// dialog as a sheet. Starts on the server default; a TV-looking name
/// moves the selection to the flagged TV folder and says why.
struct AddTorrentSheet: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let pending: PhoneStore.PendingAdd

    /// nil = the server's default directory.
    @State private var selectedDir: String?
    @State private var paused = false
    @State private var freeSpaceText = ""
    @State private var tvHint: String?
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: isFile ? "doc.fill" : "link")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text(pending.displayName)
                            .font(.headline)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Save in", selection: $selectedDir) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Server default")
                                if !store.serverDownloadDir.isEmpty {
                                    Text(store.serverDownloadDir)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: "externaldrive") }
                        .tag(String?.none)
                        ForEach(store.config.customDirs) { entry in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(entry.displayLabel)
                                    Text(entry.dir).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: entry.tv ? "tv" : "folder") }
                            .tag(String?.some(entry.dir))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Save in")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let tvHint {
                            Label(tvHint, systemImage: "tv")
                        }
                        if !freeSpaceText.isEmpty {
                            Text(freeSpaceText)
                        }
                    }
                }

                Section {
                    Toggle("Add paused", isOn: $paused)
                }
            }
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.add(pending, downloadDir: selectedDir, paused: paused)
                        dismiss()
                    }
                    .bold()
                }
            }
            .task {
                prepare()
                await updateFreeSpace()
            }
            .onChange(of: selectedDir) { _, _ in
                Task { await updateFreeSpace() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isFile: Bool {
        if case .file = pending.source { return true }
        return false
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        paused = store.config.startPaused
        let choices = store.config.customDirs
        let (isTV, reason) = TVDetect.looksLikeTV(pending.displayName)
        if isTV, let tvDir = TVDetect.findTVDir(choices), choices.contains(where: { $0.dir == tvDir }) {
            selectedDir = tvDir
            tvHint = "Looks like a TV show (\(reason?.rawValue ?? "")) — suggested the TV folder"
        }
    }

    private func updateFreeSpace() async {
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
}
