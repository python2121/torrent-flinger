import Foundation

/// Which glyph the menu-bar / tray item shows.
///
/// Deliberately only four states, shared with the Linux build (see
/// `flinger/core/trayicon.py`, which implements the same precedence): the icon
/// is a 16pt monochrome silhouette, and anything finer-grained than this is
/// unreadable at that size. Per-torrent detail belongs in the popover, not the
/// menu bar.
enum TrayIcon: String, CaseIterable {
    /// Nothing in flight — the horseshoe magnet.
    case idle
    /// Actively pulling bytes — a down arrow.
    case downloading
    /// Can't reach the server — an exclamation mark.
    case error
    /// A torrent was just added — a plus, shown briefly then replaced.
    case added

    /// How long the "added" glyph stays up before falling back to the real
    /// state. Matches the Linux build.
    static let addedDuration: TimeInterval = 3

    /// Asset basename, shared with the Linux build.
    var assetName: String { "tray-\(rawValue)" }

    /// Stand-in when the bundled asset can't be loaded — i.e. the `swift run`
    /// dev loop, which has no bundle. Close enough to keep the dev build
    /// legible without pretending to be the real artwork.
    var fallbackSymbol: String {
        switch self {
        case .idle: return "magnifyingglass.circle"
        case .downloading: return "arrow.down"
        case .error: return "exclamationmark"
        case .added: return "plus"
        }
    }

    /// Precedence: a fresh add wins for its three seconds (it's the only one
    /// that's a *notification* rather than a status), then failure to reach the
    /// server, then transfer activity, then idle.
    ///
    /// Note "downloading" keys off download speed alone — a seeding-only
    /// session shows the magnet, because a down arrow would be a lie.
    static func current(connected: Bool, downloadSpeed: Int, recentlyAdded: Bool) -> TrayIcon {
        if recentlyAdded { return .added }
        if !connected { return .error }
        if downloadSpeed > 0 { return .downloading }
        return .idle
    }
}
