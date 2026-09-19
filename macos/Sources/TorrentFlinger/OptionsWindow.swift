#if os(macOS)
import AppKit
import SwiftUI

/// Settings window — a port of `linux/flinger/ui/options_dialog.py`, same five tabs
/// (Server / General / Download / Local / Limits) so the two builds stay
/// conceptually identical. Non-modal, like the details windows.
@MainActor
final class OptionsWindowController {
    private let window = HostedWindow()
    private let store: TorrentStore
    private var model: OptionsViewModel?

    init(store: TorrentStore) { self.store = store }

    func show() {
        // Rebuild the model on each open so the form reflects the live config
        // (and re-reads the server's limits) rather than a stale edit session.
        if !window.isOpen {
            let model = OptionsViewModel(store: store)
            model.onFinish = { [weak self] in self?.window.close() }
            self.model = model
            window.onClose = { [weak self] in self?.model = nil }
        }
        guard let model else { return }
        window.present(title: "Torrent Flinger — Options",
                       size: NSSize(width: 600, height: 520),
                       root: OptionsView(model: model))
        Task { await model.loadSessionLimits() }
    }
}

/// The refresh cadences offered in the General tab, key-for-key with the Linux
/// build's `POLL_CHOICES`. A free enum rather than a member of the `@MainActor`
/// view model so the self-tests, which don't run on the main actor, can reach
/// the rules below.
enum PollChoices {
    static let menu: [(ms: Int, label: String)] =
        [(1000, "1s"), (2000, "2s"), (3000, "3s"), (5000, "5s"),
         (7000, "7s"), (10000, "10s"), (15000, "15s"), (20000, "20s"),
         (30000, "30s"), (45000, "45s"), (60000, "1m"), (120000, "2m")]

    /// Where an unusable interval lands. Matches `Config`'s own default, so
    /// saving writes a sane value back over the bad one.
    static let fallback = 3000

    /// Seconds without trailing zeroes, the same shape Python's `:g` gives:
    /// 4500 → "4.5s".
    static func label(ms: Int) -> String {
        String(format: "%gs", Double(ms) / 1000)
    }

    /// `menu`, plus `current` when it isn't already on it. A config edited by
    /// hand can hold an interval the menu doesn't offer; it's offered as-is
    /// rather than silently rounded to a neighbour the user didn't pick. Zero
    /// and negative intervals are not offered — they'd spin the poll timer.
    static func offered(current: Int) -> [(ms: Int, label: String)] {
        guard current > 0, !menu.contains(where: { $0.ms == current }) else { return menu }
        return (menu + [(ms: current, label: label(ms: current))]).sorted { $0.ms < $1.ms }
    }

    /// The interval the picker should start on. An unusable one must not leave
    /// the picker on a value nothing in the list carries — SwiftUI would draw
    /// it blank, and this window is the only place to correct it from.
    static func selection(current: Int) -> Int {
        current > 0 ? current : fallback
    }
}

@MainActor
final class OptionsViewModel: ObservableObject {
    /// Fixed at init rather than recomputed per redraw: picking a listed value
    /// mustn't make an off-menu one disappear out from under the picker.
    let pollChoices: [(ms: Int, label: String)]

    /// The `session-get` keys the Limits tab reads and writes.
    static let sessionKeys = [
        "speed-limit-down", "speed-limit-down-enabled",
        "speed-limit-up", "speed-limit-up-enabled",
        "alt-speed-enabled", "alt-speed-down", "alt-speed-up",
        "seedRatioLimit", "seedRatioLimited",
    ]

    /// Which tab is showing. A binding rather than TabView's implicit state so
    /// the window can be opened straight to a given tab.
    @Published var selectedTab = Tab.server

    enum Tab: Int, CaseIterable {
        case server, general, download, local, limits
    }

    @Published var draft: Config
    @Published var dirs: [CustomDir]
    @Published var testResult = ""
    @Published var showingAddDir = false

    // Server-side limits, loaded live via session-get.
    @Published private(set) var limitsLoaded = false
    @Published var limitsStatus = "Loading from server…"
    @Published var downloadLimited = false
    @Published var downloadLimit = 100
    @Published var uploadLimited = false
    @Published var uploadLimit = 100
    @Published var altEnabled = false
    @Published var altDownload = 50
    @Published var altUpload = 50
    @Published var ratioLimited = false
    @Published var ratioLimit = 2.0

    private let store: TorrentStore
    var onFinish: () -> Void = {}

    init(store: TorrentStore) {
        self.store = store
        var draft = store.config
        draft.pollIntervalMs = PollChoices.selection(current: draft.pollIntervalMs)
        self.draft = draft
        self.dirs = store.config.customDirs
        self.pollChoices = PollChoices.offered(current: draft.pollIntervalMs)
    }

    // MARK: Custom directories

    func addDir(label: String, dir: String, tv: Bool) {
        guard let entry = CustomDir.make(label: label, dir: dir, tv: tv) else { return }
        dirs.append(entry)
        if tv { markTVDir(entry.dir) }
    }

    func removeDir(_ id: CustomDir.ID) {
        dirs.removeAll { $0.id == id }
    }

    /// Only one directory may be the final TV location (radio semantics).
    func markTVDir(_ dir: String) {
        dirs = CustomDir.markingTV(dir, in: dirs)
    }

    func clearTVDir() {
        dirs = CustomDir.markingTV(nil, in: dirs)
    }

    // MARK: Server limits

    func loadSessionLimits() async {
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
            limitsLoaded = true
            limitsStatus = ""
        } catch {
            limitsStatus = "✗ \((error as? TransmissionError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// `session-set` payload, or nil if the server values never loaded (in
    /// which case we must not overwrite them with our defaults).
    var sessionArgs: [String: JSONValue]? {
        guard limitsLoaded else { return nil }
        return [
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
    }

    // MARK: Actions

    func testConnection() async {
        testResult = "Testing…"
        let probe = TransmissionClient(config: normalizedConfig())
        do {
            let session = try await probe.sessionGet(["version"])
            testResult = "✓ Connected — Transmission \(session.version ?? "?")"
        } catch {
            testResult = "✗ \((error as? TransmissionError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func browseLocalFolder() {
        if let path = Dialogs.chooseDirectory(
            title: "Local folder where the share is mounted",
            startingAt: draft.mountLocal) {
            draft.mountLocal = path
        }
    }

    private func normalizedConfig() -> Config {
        var config = draft
        config.host = config.host.trimmingCharacters(in: .whitespaces)
        config.rpcPath = config.rpcPath.trimmingCharacters(in: .whitespaces)
        if config.rpcPath.isEmpty { config.rpcPath = "/transmission/rpc" }
        config.webPath = config.webPath.trimmingCharacters(in: .whitespaces)
        if config.webPath.isEmpty { config.webPath = "/transmission/web/" }
        config.mountRemote = config.mountRemote.trimmingCharacters(in: .whitespaces)
        config.mountLocal = config.mountLocal.trimmingCharacters(in: .whitespaces)
        config.customDirs = dirs.filter { !$0.dir.isEmpty }
        return config
    }

    func save() {
        let config = normalizedConfig()
        store.apply(config)
        if let args = sessionArgs {
            store.perform("Couldn't apply server limits") { try await $0.sessionSet(args) }
        }
        onFinish()
    }

    func cancel() { onFinish() }
}

struct OptionsView: View {
    @ObservedObject var model: OptionsViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.selectedTab) {
                serverTab.tabItem { Text("Server") }.tag(OptionsViewModel.Tab.server)
                generalTab.tabItem { Text("General") }.tag(OptionsViewModel.Tab.general)
                downloadTab.tabItem { Text("Download") }.tag(OptionsViewModel.Tab.download)
                localTab.tabItem { Text("Local") }.tag(OptionsViewModel.Tab.local)
                limitsTab.tabItem { Text("Limits") }.tag(OptionsViewModel.Tab.limits)
            }
            .padding(12)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .sheet(isPresented: $model.showingAddDir) {
            AddDirectorySheet { label, dir, tv in
                model.addDir(label: label, dir: dir, tv: tv)
            }
        }
    }

    // MARK: Server

    private var serverTab: some View {
        Form {
            // Every row is LabeledContent + an explicitly bordered field. A
            // bare `TextField("Label", …)` inside a grouped Form renders as
            // right-aligned borderless text with no edit affordance, and one
            // placed inside an HStack renders its title as a stray inline
            // label — which is what made this tab unreadable.
            LabeledContent("Address") {
                HStack(spacing: 6) {
                    Picker("", selection: $model.draft.scheme) {
                        Text("http").tag("http")
                        Text("https").tag("https")
                    }
                    .labelsHidden()
                    .fixedSize()

                    field(text: $model.draft.host, prompt: "host or IP address")

                    Text(":").foregroundStyle(.secondary)

                    TextField("", value: $model.draft.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onChange(of: model.draft.port) { _, new in
                            // Ports are 1–65535; a spinner enforced this on Linux.
                            model.draft.port = min(max(new, 1), 65535)
                        }
                }
            }

            LabeledContent("RPC path") {
                field(text: $model.draft.rpcPath, prompt: "/transmission/rpc")
            }
            LabeledContent("Web path") {
                field(text: $model.draft.webPath, prompt: "/transmission/web/")
            }
            LabeledContent("Username") {
                field(text: $model.draft.username, prompt: "optional")
            }
            LabeledContent("Password") {
                SecureField("", text: $model.draft.password, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            }

            // Greyed out on plain http, where it does nothing — with the reason
            // in the label, so it doesn't read as an inexplicably dead control.
            Toggle(model.draft.scheme == "https"
                   ? "Verify TLS certificate"
                   : "Verify TLS certificate (https only)",
                   isOn: $model.draft.verifyTLS)
                .disabled(model.draft.scheme != "https")
                .help("Untick for a server with a self-signed certificate.")

            LabeledContent("Connection") {
                VStack(alignment: .leading, spacing: 6) {
                    // The assembled URL, so it's obvious what the fields above
                    // actually build before you spend a round trip on it.
                    Text(model.draft.rpcURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Test Connection") { Task { await model.testConnection() } }
                        Text(model.testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    /// A bordered text field that fills its row — the shape every editable
    /// field in this window uses.
    private func field(text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            // A grouped Form right-aligns its trailing content, which reads
            // wrong for paths and hostnames — you want to see the start.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity)
    }

    /// A bordered numeric field, right-aligned like a spinner's value.
    private func numberField(_ value: Binding<Int>, width: CGFloat = 90) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Toggle("Desktop notification when adding new torrents", isOn: $model.draft.notifyOnAdd)
            Toggle("Desktop notification when a torrent finishes", isOn: $model.draft.notifyOnFinish)
            Toggle("Show transfer speeds in the menu bar", isOn: $model.draft.menubarShowSpeeds)
            Picker("Popup refresh interval", selection: $model.draft.pollIntervalMs) {
                ForEach(model.pollChoices, id: \.ms) { choice in
                    Text(choice.label).tag(choice.ms)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Download

    private var downloadTab: some View {
        Form {
            Section {
                Toggle("Add torrents in paused state", isOn: $model.draft.startPaused)
                Toggle("Show download dialog when adding", isOn: $model.draft.showAddDialog)
            }

            Section {
                // Rows live directly in the Section rather than in a nested
                // List: an empty List inside a Form draws no container at all,
                // which reads as a hole in the window. Each row carries its own
                // delete button, so there's no selection state to explain.
                if model.dirs.isEmpty {
                    Text("None yet. Add one and it appears as a destination in the add dialog.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                } else {
                    ForEach(model.dirs) { entry in
                        directoryRow(entry)
                    }
                }
                Button("Add Directory…") { model.showingAddDir = true }
            } header: {
                Text("Custom directories")
            } footer: {
                Text("Flag one as the TV location and torrents whose names look like TV shows suggest it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func directoryRow(_ entry: CustomDir) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayLabel)
                Text(entry.dir)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("TV", isOn: Binding(
                get: { entry.tv },
                set: { on in on ? model.markTVDir(entry.dir) : model.clearTVDir() }))
                .toggleStyle(.checkbox)
                .help("The final TV location — at most one directory can hold this flag")
            Button {
                model.removeDir(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this directory")
        }
    }

    // MARK: Local

    private var localTab: some View {
        Form {
            Section {
                LabeledContent("Remote prefix") {
                    field(text: $model.draft.mountRemote, prompt: "auto — common root of the server's dirs")
                }
                LabeledContent("Local folder") {
                    HStack(spacing: 6) {
                        field(text: $model.draft.mountLocal, prompt: "e.g. /Volumes/nas/torrents")
                        Button("Browse…") { model.browseLocalFolder() }
                    }
                }
            } footer: {
                Text("Where the server's downloads are mounted on this Mac. Setting this enables “Reveal in Finder” on a torrent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Limits

    private var limitsTab: some View {
        Form {
            Section {
                LabeledContent("Download limit") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $model.downloadLimited).labelsHidden()
                        numberField($model.downloadLimit)
                            .disabled(!model.downloadLimited)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Upload limit") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $model.uploadLimited).labelsHidden()
                        numberField($model.uploadLimit)
                            .disabled(!model.uploadLimited)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Global speed limits")
            }

            Section {
                Toggle("Turtle mode (use the alternative limits)", isOn: $model.altEnabled)
                LabeledContent("Turtle download") {
                    HStack(spacing: 8) {
                        numberField($model.altDownload)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Turtle upload") {
                    HStack(spacing: 8) {
                        numberField($model.altUpload)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Alternative (turtle) limits")
            }

            Section {
                LabeledContent("Stop seeding at ratio") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $model.ratioLimited).labelsHidden()
                        TextField("", value: $model.ratioLimit,
                                  format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .disabled(!model.ratioLimited)
                    }
                }
            } footer: {
                Text(model.limitsLoaded
                     ? "Applied live on the server when you save."
                     : (model.limitsStatus.isEmpty ? "Loading from server…" : model.limitsStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Until the server's real values arrive, the fields hold our defaults —
        // editable ones would let a failed load overwrite the server's settings.
        .disabled(!model.limitsLoaded)
    }
}

/// Small Save/Cancel sheet for adding a custom download directory.
struct AddDirectorySheet: View {
    var onSave: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @ViewState private var label = ""
    @ViewState private var dir = ""
    @ViewState private var tv = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add custom directory").font(.headline)
            Form {
                TextField("Label", text: $label,
                          prompt: Text("Optional — defaults to folder name"))
                TextField("Directory", text: $dir,
                          prompt: Text("Absolute path on the server, e.g. /data/tv"))
                Toggle("Final TV location (auto-suggested for TV shows)", isOn: $tv)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(label, dir, tv)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(dir.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
#endif
