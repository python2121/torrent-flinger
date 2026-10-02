import SwiftUI
import TorrentFlingerCore
import UniformTypeIdentifiers

/// Server, behaviour and download-folder settings — the Mac Options window's
/// Server / General / Download tabs as one Form, plus a link to the server
/// limits. Also the first-run screen (`.setup`), with an introduction on top.
///
/// Edits go into a draft and land on Save, so typing a hostname doesn't
/// rebuild the client on every keystroke.
struct SettingsView: View {
    enum Mode { case setup, settings }

    @Environment(PhoneStore.self) private var store
    let mode: Mode

    @State private var draft = Config()
    @State private var loaded = false
    @State private var testResult = ""
    @State private var testing = false
    @State private var showingAddDir = false
    @State private var showingImporter = false

    var body: some View {
        Form {
            if mode == .setup { intro }
            serverSection
            testSection
            behaviourSection
            directoriesSection
            if mode == .settings {
                Section {
                    NavigationLink {
                        LimitsView()
                    } label: {
                        Label("Server speed limits", systemImage: "tortoise")
                    }
                }
            }
            importSection
            if mode == .settings { aboutSection }
        }
        .navigationTitle(mode == .setup ? "Torrent Flinger" : "Settings")
        .navigationBarTitleDisplayMode(mode == .setup ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .setup ? "Connect" : "Save") { save() }
                    .bold()
                    .disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = store.config
            draft.pollIntervalMs = PollChoices.selection(current: draft.pollIntervalMs)
            // The shared default points at localhost, which means nothing on
            // a phone; start the first-run form blank instead.
            if mode == .setup, !store.hasConfig { draft.host = "" }
        }
        .sheet(isPresented: $showingAddDir) {
            AddDirectorySheet { label, dir, tv in
                guard let entry = CustomDir.make(label: label, dir: dir, tv: tv) else { return }
                draft.customDirs.append(entry)
                if tv { draft.customDirs = CustomDir.markingTV(entry.dir, in: draft.customDirs) }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            importConfig(from: url)
        }
    }

    // MARK: Sections

    private var intro: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Transmission server, in your pocket.")
                            .font(.headline)
                        Text("Tap a magnet link anywhere and it goes straight to the server.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Enter the server below — the same details as the Mac app. Over Tailscale the host is the server's tailnet name. You can also import the Mac's config.json further down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var serverSection: some View {
        Section {
            Picker("Protocol", selection: $draft.scheme) {
                Text("http").tag("http")
                Text("https").tag("https")
            }
            .pickerStyle(.segmented)
            LabeledContent("Host") {
                TextField("nas or 100.64.0.5", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Port") {
                TextField("9091", value: $draft.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("RPC path") {
                TextField("/transmission/rpc", text: $draft.rpcPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Web path") {
                TextField("/transmission/web/", text: $draft.webPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Username") {
                TextField("optional", text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Password") {
                SecureField("optional", text: $draft.password)
                    .textContentType(.password)
                    .multilineTextAlignment(.trailing)
            }
            if draft.scheme == "https" {
                Toggle("Verify TLS certificate", isOn: $draft.verifyTLS)
            }
        } header: {
            Text("Server")
        } footer: {
            if !draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(normalized(draft).rpcURL)
                    .font(.caption.monospaced())
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testResult.hasPrefix("✓") ? StateColor.positive : StateColor.negative)
            }
        }
    }

    private var behaviourSection: some View {
        Section {
            Picker("Refresh interval", selection: $draft.pollIntervalMs) {
                ForEach(PollChoices.offered(current: draft.pollIntervalMs), id: \.ms) { choice in
                    Text(choice.label).tag(choice.ms)
                }
            }
            Toggle("Ask where to save when adding", isOn: $draft.showAddDialog)
            Toggle("Add torrents paused", isOn: $draft.startPaused)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("With “Ask where to save” off, links go straight to the server's default folder.")
        }
    }

    private var directoriesSection: some View {
        Section {
            ForEach(draft.customDirs) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.tv ? "tv" : "folder")
                        .foregroundStyle(entry.tv ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayLabel)
                        Text(entry.dir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(entry.tv ? "Not TV" : "TV folder", systemImage: "tv") {
                        draft.customDirs = CustomDir.markingTV(entry.tv ? nil : entry.dir, in: draft.customDirs)
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button(entry.tv ? "Clear TV flag" : "Use for TV shows", systemImage: "tv") {
                        draft.customDirs = CustomDir.markingTV(entry.tv ? nil : entry.dir, in: draft.customDirs)
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        draft.customDirs.removeAll { $0.id == entry.id }
                    }
                }
            }
            .onDelete { offsets in draft.customDirs.remove(atOffsets: offsets) }
            Button("Add Folder…", systemImage: "plus") { showingAddDir = true }
        } header: {
            Text("Download folders")
        } footer: {
            Text("Offered as destinations when adding. Flag one as the TV folder (swipe right) and torrents whose names look like TV shows suggest it automatically.")
        }
    }

    private var importSection: some View {
        Section {
            Button("Import config.json…", systemImage: "square.and.arrow.down") { showingImporter = true }
        } footer: {
            Text("Load the Mac or Linux app's config.json — same file, same keys. Copy it into iCloud Drive or AirDrop it to Files first, then pick it here.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: version)
            Text("Shares its Transmission client with the Torrent Flinger Mac app. Polls only while open — iOS doesn't let it run in the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: Actions

    private var canSave: Bool {
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && (mode == .setup || normalized(draft) != store.config)
    }

    /// Trim, default the paths, and drop empty folders — the same tidy-up the
    /// Mac options window does before saving.
    private func normalized(_ config: Config) -> Config {
        var config = config
        config.host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        config.port = min(max(config.port, 1), 65535)
        config.rpcPath = config.rpcPath.trimmingCharacters(in: .whitespaces)
        if config.rpcPath.isEmpty { config.rpcPath = "/transmission/rpc" }
        config.webPath = config.webPath.trimmingCharacters(in: .whitespaces)
        if config.webPath.isEmpty { config.webPath = "/transmission/web/" }
        config.customDirs = config.customDirs.filter { !$0.dir.isEmpty }
        return config
    }

    private func save() {
        let config = normalized(draft)
        draft = config
        store.save(config)
        if mode == .settings { store.show(.init(title: "Settings saved")) }
    }

    private func testConnection() async {
        testing = true
        testResult = ""
        let probe = TransmissionClient(config: normalized(draft))
        do {
            let session = try await probe.sessionGet(["version"])
            testResult = "✓ Connected — Transmission \(session.version ?? "?")"
        } catch {
            testResult = "✗ \(store.describe(error))"
        }
        testing = false
    }

    private func importConfig(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(Config.self, from: data),
              !imported.host.isEmpty
        else {
            store.show(.init(title: "Couldn't read that file", detail: "Expected a Torrent Flinger config.json", isError: true))
            return
        }
        draft = imported
        draft.pollIntervalMs = PollChoices.selection(current: draft.pollIntervalMs)
        testResult = ""
        store.show(.init(title: "Imported", detail: "Review the settings, then tap \(mode == .setup ? "Connect" : "Save")."))
    }
}

/// Add a server-side download folder.
struct AddDirectorySheet: View {
    var onSave: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var dir = ""
    @State private var tv = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (optional)", text: $label)
                    TextField("/data/tv", text: $dir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("The absolute path on the server. The label defaults to the folder's name.")
                }
                Section {
                    Toggle("TV folder", isOn: $tv)
                } footer: {
                    Text("Suggested automatically for torrents whose names look like TV shows.")
                }
            }
            .navigationTitle("Add Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(label, dir, tv)
                        dismiss()
                    }
                    .bold()
                    .disabled(dir.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
