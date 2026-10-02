import Foundation

/// The refresh cadences offered in the General tab, key-for-key with the Linux
/// build's `POLL_CHOICES`. A free enum rather than a member of the `@MainActor`
/// view model so the self-tests, which don't run on the main actor, can reach
/// the rules below.
public enum PollChoices: Sendable {
    public static let menu: [(ms: Int, label: String)] =
        [(1000, "1s"), (2000, "2s"), (3000, "3s"), (5000, "5s"),
         (7000, "7s"), (10000, "10s"), (15000, "15s"), (20000, "20s"),
         (30000, "30s"), (45000, "45s"), (60000, "1m"), (120000, "2m")]

    /// Where an unusable interval lands. Matches `Config`'s own default, so
    /// saving writes a sane value back over the bad one.
    public static let fallback = 3000

    /// Seconds without trailing zeroes, the same shape Python's `:g` gives:
    /// 4500 → "4.5s".
    public static func label(ms: Int) -> String {
        String(format: "%gs", Double(ms) / 1000)
    }

    /// `menu`, plus `current` when it isn't already on it. A config edited by
    /// hand can hold an interval the menu doesn't offer; it's offered as-is
    /// rather than silently rounded to a neighbour the user didn't pick. Zero
    /// and negative intervals are not offered — they'd spin the poll timer.
    public static func offered(current: Int) -> [(ms: Int, label: String)] {
        guard current > 0, !menu.contains(where: { $0.ms == current }) else { return menu }
        return (menu + [(ms: current, label: label(ms: current))]).sorted { $0.ms < $1.ms }
    }

    /// The interval the picker should start on. An unusable one must not leave
    /// the picker on a value nothing in the list carries — SwiftUI would draw
    /// it blank, and this window is the only place to correct it from.
    public static func selection(current: Int) -> Int {
        current > 0 ? current : fallback
    }
}
