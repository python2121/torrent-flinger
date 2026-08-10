#if os(macOS)
import AppKit
import SwiftUI

/// Session statistics: this session vs. cumulative totals — a port of
/// `flinger/ui/stats_dialog.py`.
@MainActor
final class StatsWindowController {
    private let window = HostedWindow()
    private let model: StatsViewModel

    init(store: TorrentStore) {
        model = StatsViewModel(store: store)
    }

    func show() {
        window.present(title: "Transmission Statistics",
                       size: NSSize(width: 340, height: 250),
                       resizable: false,
                       root: StatsView(model: model))
        Task { await model.load() }
    }
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var stats: SessionStats?
    @Published var error: String?

    private let store: TorrentStore

    init(store: TorrentStore) { self.store = store }

    func load() async {
        do {
            stats = try await store.client.sessionStats()
            error = nil
        } catch {
            self.error = (error as? TransmissionError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct StatsView: View {
    @ObservedObject var model: StatsViewModel

    private static let rows = ["Downloaded", "Uploaded", "Ratio", "Files added", "Active time", "Sessions"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("This session").font(.subheadline.bold())
                    Text("Total").font(.subheadline.bold())
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, name in
                    GridRow {
                        Text(name).foregroundStyle(.secondary)
                        Text(value(index, model.stats?.currentStats))
                            .monospacedDigit()
                        Text(value(index, model.stats?.cumulativeStats))
                            .monospacedDigit()
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(StateColor.negative)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Refresh") { Task { await model.load() } }
            }
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 230)
        .task { await model.load() }
    }

    private func value(_ index: Int, _ block: StatsBlock?) -> String {
        guard let block else { return "…" }
        switch index {
        case 0: return Format.size(block.downloadedBytes)
        case 1: return Format.size(block.uploadedBytes)
        case 2: return block.ratioText
        case 3: return "\(block.filesAdded)"
        case 4: return Format.eta(block.secondsActive).isEmpty ? "0s" : Format.eta(block.secondsActive)
        default: return "\(block.sessionCount)"
        }
    }
}
#endif
