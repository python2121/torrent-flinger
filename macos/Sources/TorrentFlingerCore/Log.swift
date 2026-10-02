import Foundation
import os

/// Unified-log channel for the app.
///
/// A menu-bar accessory has nowhere to print: it has no terminal, and a
/// LaunchServices-started `.app` has no stdout attached. Without this, a
/// connection failure showed up as the word "Disconnected" and nothing else —
/// no way to tell a wrong port from a DNS failure from a denied Local Network
/// permission. Failures go in at `.error` so they persist in the log store:
///
///     log show --last 10m --predicate 'subsystem == "io.github.python2121.TorrentFlinger"'
public enum Log: Sendable {
    private static let logger = Logger(subsystem: "io.github.python2121.TorrentFlinger",
                                       category: "app")

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
