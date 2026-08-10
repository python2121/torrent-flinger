import Foundation

/// One entry in the "custom directories" list offered by the add dialog.
///
/// Serialized exactly as the Linux app writes it (`{"label", "dir", "tv"}`),
/// with `tv` omitted when false — the two apps read and write the same
/// `config.json`, so a shared home directory keeps them in sync.
struct CustomDir: Codable, Hashable, Identifiable {
    var label: String = ""
    var dir: String = ""
    var tv: Bool = false

    var id: String { dir }

    /// What the add dialog shows: the label if set, else the bare path.
    var displayLabel: String { label.isEmpty ? dir : label }

    enum CodingKeys: String, CodingKey { case label, dir, tv }

    /// Flag exactly one directory as the TV location, clearing any other — the
    /// radio semantics `TVDetect.findTVDir` relies on (it returns the *first*
    /// flagged entry, so two flags would make the destination depend on list
    /// order). Pass nil to clear them all.
    static func markingTV(_ dir: String?, in dirs: [CustomDir]) -> [CustomDir] {
        dirs.map { entry in
            var updated = entry
            updated.tv = (dir != nil && entry.dir == dir)
            return updated
        }
    }

    /// Build an entry the way the "Add Directory…" sheet does: trim, and fall
    /// back to the folder's own name when no label is given.
    static func make(label: String, dir: String, tv: Bool) -> CustomDir? {
        let path = dir.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let name = trimmedLabel.isEmpty
            ? String(path.split(separator: "/").last ?? "")
            : trimmedLabel
        return CustomDir(label: name, dir: path, tv: tv)
    }

    init(label: String = "", dir: String = "", tv: Bool = false) {
        self.label = label
        self.dir = dir
        self.tv = tv
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 } ?? ""
        dir = (try? c.decodeIfPresent(String.self, forKey: .dir)).flatMap { $0 } ?? ""
        tv = (try? c.decodeIfPresent(Bool.self, forKey: .tv)).flatMap { $0 } ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(dir, forKey: .dir)
        if tv { try c.encode(true, forKey: .tv) }   // omitted when false, as Python does
    }
}

/// App configuration, persisted as JSON at
/// `~/Library/Application Support/torrent-flinger/config.json` — the same path
/// and the same key names the Python app uses on macOS, so the file is
/// interchangeable. Unknown keys are ignored on load (and dropped on save),
/// which is also how the Python loader behaves.
struct Config: Codable, Equatable {
    var scheme: String = "http"
    var host: String = "localhost"
    var port: Int = 9091
    var rpcPath: String = "/transmission/rpc"
    var webPath: String = "/transmission/web/"
    var username: String = ""
    var password: String = ""
    var verifyTLS: Bool = true

    var notifyOnAdd: Bool = true
    var notifyOnFinish: Bool = true
    var pollIntervalMs: Int = 3000

    var startPaused: Bool = false
    var showAddDialog: Bool = true
    var customDirs: [CustomDir] = []
    var lastDownloadDir: String = ""

    /// Remote→local path mapping for "Reveal in Finder": where the server's
    /// download share is mounted locally. An empty `mountRemote` means "use the
    /// common root of the server's download dirs" (computed at poll time).
    var mountRemote: String = ""
    var mountLocal: String = ""

    /// macOS-only: draw the aggregate transfer speeds next to the menu-bar
    /// icon. Ignored by the Linux app, which keeps them in the tray tooltip.
    var menubarShowSpeeds: Bool = true

    enum CodingKeys: String, CodingKey {
        case scheme = "protocol"
        case host
        case port
        case rpcPath = "rpc_path"
        case webPath = "web_path"
        case username
        case password
        case verifyTLS = "verify_tls"
        case notifyOnAdd = "notify_on_add"
        case notifyOnFinish = "notify_on_finish"
        case pollIntervalMs = "poll_interval_ms"
        case startPaused = "start_paused"
        case showAddDialog = "show_add_dialog"
        case customDirs = "custom_dirs"
        case lastDownloadDir = "last_download_dir"
        case mountRemote = "mount_remote"
        case mountLocal = "mount_local"
        case menubarShowSpeeds = "menubar_show_speeds"
    }

    init() {}

    /// Lenient decode: every key falls back to its default, so a config written
    /// by an older (or newer, or Linux) build never fails to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys, _ fallback: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        func int(_ k: CodingKeys, _ fallback: Int) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        func bool(_ k: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        scheme = str(.scheme, "http")
        host = str(.host, "localhost")
        port = int(.port, 9091)
        rpcPath = str(.rpcPath, "/transmission/rpc")
        webPath = str(.webPath, "/transmission/web/")
        username = str(.username, "")
        password = str(.password, "")
        verifyTLS = bool(.verifyTLS, true)
        notifyOnAdd = bool(.notifyOnAdd, true)
        notifyOnFinish = bool(.notifyOnFinish, true)
        pollIntervalMs = int(.pollIntervalMs, 3000)
        startPaused = bool(.startPaused, false)
        showAddDialog = bool(.showAddDialog, true)
        customDirs = (try? c.decodeIfPresent([CustomDir].self, forKey: .customDirs)).flatMap { $0 } ?? []
        lastDownloadDir = str(.lastDownloadDir, "")
        mountRemote = str(.mountRemote, "")
        mountLocal = str(.mountLocal, "")
        menubarShowSpeeds = bool(.menubarShowSpeeds, true)
    }

    // MARK: Derived

    var rpcURL: String { "\(scheme)://\(host):\(port)\(rpcPath)" }
    var webURL: String { "\(scheme)://\(host):\(port)\(webPath)" }

    // MARK: Persistence

    static let appName = "torrent-flinger"

    /// `TORRENT_FLINGER_CONFIG_DIR` overrides the location, matching the Python
    /// build — it's how a test or a sandbox redirects the config away from the
    /// real one. Unset (the normal case) means the standard location.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["TORRENT_FLINGER_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load(from url: URL = Config.fileURL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    func save(to url: URL = Config.fileURL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        // The password lives in here, so keep it owner-only like Python does.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
