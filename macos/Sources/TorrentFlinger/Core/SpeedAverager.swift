import Foundation

/// Smooths the speeds the menu bar shows.
///
/// A swarm's throughput swings wildly second to second, and Transmission's
/// `downloadSpeed` is itself computed over only a couple of seconds of
/// history — so a raw reading in the menu bar reads as noise: it halves and
/// doubles between repaints while the transfer is, in aggregate, perfectly
/// steady. What you want from the corner of your eye is "about 3 MB/s", not a
/// number that's technically true for the last two seconds.
///
/// So the readout widens as a transfer settles in:
///
/// | activity age | averaged over | recomputed every |
/// |--------------|---------------|------------------|
/// | 0–15 s       | the live reading | every sample  |
/// | 15–30 s      | the last 15 s | 5 s              |
/// | 30 s +       | the last 30 s | 10 s             |
///
/// Both halves of each tier matter. A wider window stops the *value* jumping;
/// the slower refresh stops the *text* twitching, which is its own kind of
/// unreadable even when every number shown is accurate. The first 15 s stay
/// live because there's nothing to average over yet and because a transfer
/// spinning up is the one moment you do want to watch it move.
///
/// Age is measured from when the transfer started, not from launch, so every
/// new download gets the responsive tier again.
///
/// Pure, and the clock is the caller's — `record` takes the timestamp — so the
/// tiers are testable without a timer, per this build's rule that logic the UI
/// leans on lives in `Core` as plain values.
struct SpeedAverager {
    struct Speeds: Equatable {
        var download: Int = 0
        var upload: Int = 0

        static let zero = Speeds()

        /// Whether anything is moving — what decides if the menu bar shows
        /// numbers at all, and whether we keep sampling quickly.
        var isActive: Bool { download > 0 || upload > 0 }
    }

    struct Tier: Equatable {
        /// Activity age at which this tier takes over.
        let age: TimeInterval
        /// Trailing window to average. Zero means "show the live reading".
        let window: TimeInterval
        /// How often the displayed value is recomputed. Zero means every sample.
        let refresh: TimeInterval
    }

    /// Ordered by `age`; the last one whose age has passed wins.
    static let tiers: [Tier] = [
        Tier(age: 0, window: 0, refresh: 0),
        Tier(age: 15, window: 15, refresh: 5),
        Tier(age: 30, window: 30, refresh: 10),
    ]

    /// How long everything has to read zero before the transfer counts as over
    /// and the tiers start again from live.
    ///
    /// Not one sample: torrents stall for a few seconds constantly, and riding
    /// out a stall is half of what the average is for. But not never, either —
    /// a finished download would otherwise leave a decaying ghost in the menu
    /// bar for a full window, and the glyph keys off the same numbers.
    static let idleGrace: TimeInterval = 5

    /// The value to display. Holds still between refreshes by design.
    private(set) var displayed = Speeds.zero

    private struct Sample {
        let time: Date
        let download: Int
        let upload: Int
        let downloadedBytes: Int64
        let uploadedBytes: Int64
    }

    /// Ascending by time, pruned to the longest window (plus the one reading
    /// before it — see `prune`).
    private var samples: [Sample] = []
    private var activityStart: Date?
    private var lastRefresh: Date?
    private var lastTier: Tier?
    private var zeroSince: Date?

    private static let longestWindow = tiers.map(\.window).max() ?? 0

    /// How much wider than its nominal window a measurement may span before the
    /// anchor reading is abandoned as too old to be part of it.
    private static let spanTolerance = 1.5

    init() {}

    /// Which tier a transfer of this age falls in.
    static func tier(forAge age: TimeInterval) -> Tier {
        tiers.last { age >= $0.age } ?? tiers[0]
    }

    /// How the current readout is derived, for the tooltip — nil while it's a
    /// live reading, since that needs no explanation.
    var windowDescription: String? {
        guard let window = lastTier?.window, window > 0 else { return nil }
        return "\(Int(window)) s average"
    }

    /// Whether a transfer is currently being tracked. Distinct from
    /// `displayed.isActive`: the average can still be non-zero for a moment
    /// after everything stops.
    var isTracking: Bool { activityStart != nil }

    /// Feeds in one `session-stats` reading, returning true if `displayed`
    /// changed — so the caller can leave the published copy (and anything
    /// observing it) alone on the samples that only feed the average.
    @discardableResult
    mutating func record(_ stats: SessionStats, at now: Date) -> Bool {
        let live = Speeds(download: stats.downloadSpeed, upload: stats.uploadSpeed)

        // What the caller is showing right now. Every exit below reports
        // against this, never against `.zero`, because `reset()` empties
        // `displayed` on its own — from the gap check immediately below, or
        // from a caller reaching for it directly. Comparing against `.zero`
        // instead means a readout that was emptied by a reset reports "nothing
        // changed", and a caller that only republishes on a change goes on
        // drawing the last speed it ever heard.
        let before = displayed

        // A gap wider than the widest window breaks continuity: the lid was
        // shut, App Nap throttled the timer, the server went away for a minute.
        // The readings either side aren't one picture, and averaging across the
        // gap would report its idle stretch as this transfer's speed — a laptop
        // waking from four hours asleep would read a few kB/s while pulling
        // megabytes. A clock that steps backwards (NTP correcting a bad RTC
        // after boot) is the same discontinuity, and would additionally put the
        // samples out of order and yield a negative rate. Start over: a live
        // reading is the only honest answer on the far side of a hole.
        if let last = samples.last,
           now < last.time || now.timeIntervalSince(last.time) > Self.longestWindow {
            reset()
        }

        if live.isActive {
            zeroSince = nil
        } else {
            let since = zeroSince ?? now
            zeroSince = since
            // While nothing is being tracked, a zero reading is just the idle
            // state: reset rather than start a clock, or a machine that sat
            // idle all afternoon would open its next download in the widest,
            // slowest tier.
            if samples.isEmpty || now.timeIntervalSince(since) >= Self.idleGrace {
                reset()
                return displayed != before
            }
        }

        if activityStart == nil { activityStart = now }
        samples.append(Sample(time: now,
                              download: stats.downloadSpeed,
                              upload: stats.uploadSpeed,
                              downloadedBytes: stats.currentStats.downloadedBytes,
                              uploadedBytes: stats.currentStats.uploadedBytes))
        prune(before: now.addingTimeInterval(-Self.longestWindow))

        let age = now.timeIntervalSince(activityStart ?? now)
        let tier = Self.tier(forAge: age)
        // A tier change refreshes immediately: crossing 15 s should show the
        // average right away rather than sitting on the last live reading for
        // another five seconds.
        let due = tier != lastTier || tier.refresh <= 0
            || lastRefresh.map { now.timeIntervalSince($0) >= tier.refresh } ?? true
        guard due else { return displayed != before }

        lastTier = tier
        lastRefresh = now
        let value = tier.window <= 0 ? live : average(over: tier.window, endingAt: now)
        displayed = value
        return displayed != before
    }

    /// Drops everything — a disconnect, or a transfer that's over. The next
    /// reading starts the tiers again from live.
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        activityStart = nil
        lastRefresh = nil
        lastTier = nil
        zeroSince = nil
        displayed = .zero
    }

    private func average(over window: TimeInterval, endingAt now: Date) -> Speeds {
        guard !samples.isEmpty else { return .zero }
        let cutoff = now.addingTimeInterval(-window)
        // Anchor on the newest reading at or before the cutoff so the window
        // spans its full length; samples land on their own cadence, and
        // starting at the oldest one *inside* the window would quietly measure
        // "the last 30 s minus one poll gap" instead.
        var start = samples.lastIndex { $0.time <= cutoff } ?? 0
        // …but not an anchor stranded far behind the cutoff, which would
        // measure something much wider than the window it's labelled with. A
        // sparse cadence gets that: with readings 29 s apart the nearest anchor
        // to a 30 s cutoff is 58 s old. Past half a window of slack, measure
        // only what's inside instead.
        if now.timeIntervalSince(samples[start].time) > window * Self.spanTolerance {
            start = samples.firstIndex { $0.time >= cutoff } ?? samples.count - 1
        }
        let slice = samples[start...]
        return Speeds(download: Self.average(slice, rate: \.download, counter: \.downloadedBytes),
                      upload: Self.average(slice, rate: \.upload, counter: \.uploadedBytes))
    }

    private static func average(_ slice: ArraySlice<Sample>,
                                rate: KeyPath<Sample, Int>,
                                counter: KeyPath<Sample, Int64>) -> Int {
        guard let first = slice.first, let last = slice.last else { return 0 }
        let span = last.time.timeIntervalSince(first.time)
        guard span > 0 else { return last[keyPath: rate] }

        // Preferred: the session's own byte counter. Bytes over wall time is
        // the window's exact average, where a mean of rate readings can only
        // approximate one — a late timer or a dropped sample doesn't distort
        // it. (A gap big enough to break continuity isn't handled here at all;
        // `record` starts over instead.)
        //
        // Only a counter that actually moved, though. A delta of zero means
        // either a stall or a server that doesn't report `current-stats` — the
        // latter leaves it pinned, and a pinned counter would have us report
        // 0 B/s straight through a download. A negative delta is a daemon
        // restart winding it back. Both fall through to the readings, which are
        // always there, and which agree with the counter on a genuine stall
        // anyway.
        let delta = last[keyPath: counter] - first[keyPath: counter]
        if delta > 0 {
            return Int((Double(delta) / span).rounded())
        }

        // Fallback: a time-weighted mean, each reading credited to the interval
        // it ends. Weighting by time rather than by count keeps an irregular
        // cadence from over-counting the samples that happen to bunch up.
        var weighted = 0.0
        var previous = first
        for sample in slice.dropFirst() {
            weighted += Double(sample[keyPath: rate]) * sample.time.timeIntervalSince(previous.time)
            previous = sample
        }
        return Int((weighted / span).rounded())
    }

    private mutating func prune(before cutoff: Date) {
        guard let firstInside = samples.firstIndex(where: { $0.time >= cutoff }) else {
            samples = Array(samples.suffix(1))
            return
        }
        // Keep the one reading before the cutoff — it's the anchor that lets
        // the widest window measure a full 30 s.
        let drop = max(0, firstInside - 1)
        if drop > 0 { samples.removeFirst(drop) }
    }
}
