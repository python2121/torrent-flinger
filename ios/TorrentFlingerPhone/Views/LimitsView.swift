import SwiftUI
import TorrentFlingerCore

/// Server-wide speed limits, turtle mode and the default seed ratio —
/// loaded live via `session-get`, written back with Apply. Disabled until
/// the server's values arrive so a failed load can't overwrite them.
struct LimitsView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The `session-get` keys this screen reads and writes.
    static let sessionKeys = [
        "speed-limit-down", "speed-limit-down-enabled",
        "speed-limit-up", "speed-limit-up-enabled",
        "alt-speed-enabled", "alt-speed-down", "alt-speed-up",
        "seedRatioLimit", "seedRatioLimited",
    ]

    @State private var loaded = false
    @State private var status = "Loading from server…"
    @State private var downloadLimited = false
    @State private var downloadLimit = 100
    @State private var uploadLimited = false
    @State private var uploadLimit = 100
    @State private var altEnabled = false
    @State private var altDownload = 50
    @State private var altUpload = 50
    @State private var ratioLimited = false
    @State private var ratioLimit = 2.0

    var body: some View {
        Form {
            Section("Global speed limits") {
                Toggle("Limit download", isOn: $downloadLimited)
                numberRow("Download (KB/s)", $downloadLimit).disabled(!downloadLimited)
                Toggle("Limit upload", isOn: $uploadLimited)
                numberRow("Upload (KB/s)", $uploadLimit).disabled(!uploadLimited)
            }
            Section {
                Toggle("Turtle mode", isOn: $altEnabled)
                numberRow("Turtle download (KB/s)", $altDownload)
                numberRow("Turtle upload (KB/s)", $altUpload)
            } header: {
                Text("Alternative limits")
            } footer: {
                Text("Turtle mode swaps in the alternative limits for everything, server-wide.")
            }
            Section("Seeding") {
                Toggle("Stop seeding at ratio", isOn: $ratioLimited)
                LabeledContent("Ratio") {
                    TextField("", value: $ratioLimit, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(!ratioLimited)
            }
            Section {
                Button("Apply") { apply() }
                    .frame(maxWidth: .infinity)
                    .bold()
            } footer: {
                Text(loaded ? "Applied live on the server." : status)
            }
        }
        .monospacedDigit()
        .disabled(!loaded)
        .navigationTitle("Server Limits")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func numberRow(_ title: String, _ value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func load() async {
        do {
            let session = try await store.client.sessionGet(Self.sessionKeys)
            downloadLimited = session.speedLimitDownEnabled ?? false
            downloadLimit = session.speedLimitDown ?? 100
            uploadLimited = session.speedLimitUpEnabled ?? false
            uploadLimit = session.speedLimitUp ?? 100
            altEnabled = session.altSpeedEnabled ?? false
            altDownload = session.altSpeedDown ?? 50
            altUpload = session.altSpeedUp ?? 50
            ratioLimited = session.seedRatioLimited ?? false
            ratioLimit = session.seedRatioLimit ?? 2.0
            loaded = true
        } catch {
            status = "Couldn't load: \(store.describe(error))"
        }
    }

    private func apply() {
        let args: [String: JSONValue] = [
            "speed-limit-down": .int(downloadLimit),
            "speed-limit-down-enabled": .bool(downloadLimited),
            "speed-limit-up": .int(uploadLimit),
            "speed-limit-up-enabled": .bool(uploadLimited),
            "alt-speed-enabled": .bool(altEnabled),
            "alt-speed-down": .int(altDownload),
            "alt-speed-up": .int(altUpload),
            "seedRatioLimit": .double(ratioLimit),
            "seedRatioLimited": .bool(ratioLimited),
        ]
        store.perform("Couldn't apply server limits") { try await $0.sessionSet(args) }
        store.show(.init(title: "Server limits applied"))
        dismiss()
    }
}
