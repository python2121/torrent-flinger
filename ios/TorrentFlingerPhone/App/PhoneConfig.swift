import Foundation
import TorrentFlingerCore

/// Where the phone keeps its settings.
///
/// The same `Config` the Mac and Linux builds use, written by the same
/// `Config.save` into the app sandbox's Application Support — so a
/// `config.json` copied over from the Mac (Files app, or Settings → Import)
/// loads as-is. The one difference: the password goes in the Keychain, and
/// the file on disk carries an empty one. A file that *does* hold a password
/// (a fresh import) is honoured and the secret migrated on the next save.
enum PhoneConfig {
    static let passwordAccount = "transmission-password"

    /// The stored config plus whether one has ever been saved — the default
    /// `Config()` points at localhost, which means nothing on a phone, so the
    /// app can't tell "unset" from "configured" by looking at the values.
    static func load() -> (config: Config, hasConfig: Bool) {
        let url = Config.fileURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        var config = Config.load(from: url)
        if let secret = Keychain.string(for: passwordAccount), !secret.isEmpty {
            config.password = secret
        }
        return (config, exists)
    }

    static func save(_ config: Config) {
        Keychain.set(config.password, for: passwordAccount)
        var stored = config
        stored.password = ""
        stored.save(to: Config.fileURL)
    }
}
