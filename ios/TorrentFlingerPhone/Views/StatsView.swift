import SwiftUI
import TorrentFlingerCore

/// Session statistics: what's happening now, this session's totals, and the
/// all-time totals — the Mac statistics window plus the live figures.
struct StatsView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        List {
            Section("Now") {
                LabeledContent("Download", value: Format.speed(store.stats.downloadSpeed))
                LabeledContent("Upload", value: Format.speed(store.stats.uploadSpeed))
                LabeledContent("Active torrents", value: "\(store.stats.activeTorrentCount)")
                LabeledContent("Paused torrents", value: "\(store.stats.pausedTorrentCount)")
                if store.freeSpace >= 0 {
                    LabeledContent("Free space", value: Format.size(store.freeSpace))
                }
            }
            block("This session", store.stats.currentStats)
            block("All time", store.stats.cumulativeStats)
            Section("Server") {
                LabeledContent("Address", value: store.config.host)
                if !store.serverVersion.isEmpty {
                    LabeledContent("Transmission", value: store.serverVersion)
                }
                if !store.serverDownloadDir.isEmpty {
                    DetailRow(key: "Download directory", value: store.serverDownloadDir)
                }
            }
            if let error = store.errorMessage, !store.connected {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(StateColor.negative)
                        .font(.footnote)
                }
            }
        }
        .monospacedDigit()
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.poll() }
    }

    private func block(_ title: String, _ block: StatsBlock) -> some View {
        Section(title) {
            LabeledContent("Downloaded", value: Format.size(block.downloadedBytes))
            LabeledContent("Uploaded", value: Format.size(block.uploadedBytes))
            LabeledContent("Ratio", value: block.ratioText)
            LabeledContent("Files added", value: "\(block.filesAdded)")
            LabeledContent("Active time",
                           value: Format.eta(block.secondsActive).isEmpty ? "0s" : Format.eta(block.secondsActive))
            LabeledContent("Sessions", value: "\(block.sessionCount)")
        }
    }
}
