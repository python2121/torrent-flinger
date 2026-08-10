import Foundation

/// Detect whether a torrent name looks like a TV show — a direct port of
/// `flinger/core/tvdetect.py`.
///
/// Marker-based and precision-first:
/// 1. episode markers (S01E02 / 3x07)   — near-certain, catches any show
/// 2. air-date naming (Show.2026.01.15) — daily shows; movies use bare years
/// 3. season-pack markers (S01, Season 2, Complete Series, Seasons 1-6)
///
/// Real-world TV releases essentially always carry one of these markers, so no
/// title list is needed. Movies default elsewhere, so a missed detection just
/// means picking the folder manually — same as having no detection.
enum TVDetect {
    enum Reason: String {
        case episode
        case airDate = "air-date"
        case season
    }

    private static let episode = regex(#"\b[Ss]\d{1,2}[._ ]?[Ee]\d{1,3}\b|\b\d{1,2}x\d{2,3}\b"#)
    private static let airDate = regex(#"\b(?:19|20)\d{2}[._ -]\d{2}[._ -]\d{2}\b"#)
    private static let seasonPack = regex(
        #"\b[Ss]\d{1,2}\b"#
        + #"|\b[Ss]eason[._ -]?\d{1,2}\b"#
        + #"|\b[Ss]easons?[._ -]?\d{1,2}[-–][._ ]?\d{1,2}\b"#
        + #"|\b[Cc]omplete[._ -]([Ss]eries|[Ss]eason)\b"#
        + #"|\b[Mm]ini[._ -]?[Ss]eries\b"#
    )

    /// `(isTV, reason)` — reason is nil when it isn't TV.
    static func looksLikeTV(_ name: String) -> (isTV: Bool, reason: Reason?) {
        if matches(episode, name) { return (true, .episode) }
        if matches(airDate, name) { return (true, .airDate) }
        if matches(seasonPack, name) { return (true, .season) }
        return (false, nil)
    }

    /// The custom dir flagged as the final TV location, or nil. At most one
    /// entry carries the flag (enforced by the options UI).
    static func findTVDir(_ customDirs: [CustomDir]) -> String? {
        customDirs.first(where: { $0.tv })?.dir
    }

    // MARK: Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants — a failure here is a programmer
        // error, not a runtime condition.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
