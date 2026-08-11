#if DEBUG
import Foundation

/// The menu bar's speed smoothing: which tier a transfer is in, how often the
/// displayed value is allowed to move, and how the average over the window is
/// computed. All of it is pure with an injected clock, so a whole minute of a
/// download runs in no time at all and without a server.
enum SpeedAveragerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A `session-stats` reading. `downloaded`/`uploaded` are the session byte
    /// counters — left at zero for the servers that don't report them, which is
    /// what puts the averager on its rate-mean fallback.
    private static func stats(down: Int, up: Int = 0,
                              downloaded: Int64 = 0, uploaded: Int64 = 0) -> SessionStats {
        var s = SessionStats()
        s.downloadSpeed = down
        s.uploadSpeed = up
        var block = StatsBlock()
        block.downloadedBytes = downloaded
        block.uploadedBytes = uploaded
        s.currentStats = block
        return s
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    static let all: [TestEntry] = [
        TestEntry("speed/tiers-by-age") { t in
            t.equal(SpeedAverager.tier(forAge: 0).window, 0, "a fresh transfer shows live readings")
            t.equal(SpeedAverager.tier(forAge: 14.9).window, 0)
            t.equal(SpeedAverager.tier(forAge: 15).window, 15, "15 s in, a 15 s window")
            t.equal(SpeedAverager.tier(forAge: 15).refresh, 5)
            t.equal(SpeedAverager.tier(forAge: 29.9).window, 15)
            t.equal(SpeedAverager.tier(forAge: 30).window, 30, "30 s in, a 30 s window")
            t.equal(SpeedAverager.tier(forAge: 30).refresh, 10)
            t.equal(SpeedAverager.tier(forAge: 3600).window, 30, "the widest tier is the last one")
        },

        TestEntry("speed/first-15-seconds-pass-through-live") { t in
            var averager = SpeedAverager()
            // Wildly bouncy readings: every one of them should show, because
            // there's nothing to average yet and a transfer spinning up is the
            // moment you want to watch it move.
            for (index, speed) in [1_000, 9_000, 2_000, 8_000, 3_000].enumerated() {
                let changed = averager.record(stats(down: speed), at: at(Double(index) * 2.5))
                t.expect(changed, "reading \(index) should reach the menu bar")
                t.equal(averager.displayed.download, speed)
            }
            t.isNil(averager.windowDescription, "live readings need no explaining")
        },

        TestEntry("speed/15s-window-holds-still-between-refreshes") { t in
            var averager = SpeedAverager()
            // A steady 1 MB/s for 15 s, sampled every 2.5 s.
            for step in stride(from: 0.0, through: 15.0, by: 2.5) {
                averager.record(stats(down: 1_000_000), at: at(step))
            }
            t.equal(averager.displayed.download, 1_000_000)
            t.equal(averager.windowDescription, "15 s average")

            // A spike two seconds later must not reach the bar: the tier
            // refreshed at 15 s and isn't due again until 20 s.
            let spike = averager.record(stats(down: 9_000_000), at: at(17.5))
            t.expect(!spike, "a reading inside the refresh interval is absorbed")
            t.equal(averager.displayed.download, 1_000_000, "the text holds still")

            // At 20 s it's due, and the spike shows up averaged down rather
            // than at face value.
            let refreshed = averager.record(stats(down: 9_000_000), at: at(20))
            t.expect(refreshed, "5 s on, the value refreshes")
            t.expect(averager.displayed.download > 1_000_000, "the spike moved the average")
            t.expect(averager.displayed.download < 4_000_000,
                     "…but nothing like the 9 MB/s a live reading would have shown")
        },

        TestEntry("speed/30s-window-refreshes-every-10s") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 30.0, by: 2.5) {
                averager.record(stats(down: 1_000_000), at: at(step))
            }
            t.equal(averager.windowDescription, "30 s average", "past 30 s, the widest window")

            t.equal(averager.displayed.download, 1_000_000, "and the number itself is right")

            let early = averager.record(stats(down: 5_000_000), at: at(35))
            t.expect(!early, "5 s into a 10 s refresh interval, nothing moves")
            t.equal(averager.displayed.download, 1_000_000, "the text holds still")

            let due = averager.record(stats(down: 5_000_000), at: at(40))
            t.expect(due, "10 s on, it refreshes")
            t.expect(averager.displayed.download > 1_000_000 && averager.displayed.download < 3_000_000,
                     "averaged toward the faster readings, not jumped to them, "
                     + "got \(averager.displayed.download)")
        },

        TestEntry("speed/tier-change-refreshes-immediately") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 12.5, by: 2.5) {
                averager.record(stats(down: 1_000_000), at: at(step))
            }
            // The reading that crosses 15 s must publish the average there and
            // then, rather than sitting on the last live number for another
            // refresh interval.
            let crossing = averager.record(stats(down: 3_000_000), at: at(15))
            t.expect(crossing, "crossing into a tier refreshes on the spot")
            t.equal(averager.windowDescription, "15 s average")
            t.expect(averager.displayed.download < 3_000_000, "and it's averaged, not live")
        },

        TestEntry("speed/byte-counter-beats-the-rate-readings") { t in
            var averager = SpeedAverager()
            // The counter says a flat 1 MB/s for 20 s; the rate readings are
            // deliberate nonsense. The counter is the exact answer, so it wins.
            for step in stride(from: 0.0, through: 20.0, by: 2.5) {
                let bogus = step.truncatingRemainder(dividingBy: 5) == 0 ? 50_000_000 : 0
                averager.record(stats(down: bogus, downloaded: Int64(step * 1_000_000)),
                                at: at(step))
            }
            t.equal(averager.displayed.download, 1_000_000,
                    "bytes over wall time, not a mean of the readings")
        },

        TestEntry("speed/falls-back-to-a-time-weighted-mean") { t in
            var averager = SpeedAverager()
            // No byte counter (a server that doesn't report current-stats), and
            // a deliberately lumpy cadence: 2 MB/s covering 12 s of the window
            // and 500 kB/s covering 3 s. Weighting by count would say 1.25 MB/s;
            // weighting by time says 1.7 MB/s, which is what actually happened.
            averager.record(stats(down: 2_000_000), at: at(0))
            averager.record(stats(down: 2_000_000), at: at(12))
            averager.record(stats(down: 500_000), at: at(15))
            t.equal(averager.windowDescription, "15 s average")
            t.expect(abs(averager.displayed.download - 1_700_000) < 50_000,
                     "expected ≈1.7 MB/s, got \(averager.displayed.download)")
        },

        TestEntry("speed/survives-a-counter-that-winds-backwards") { t in
            var averager = SpeedAverager()
            // A daemon restart resets current-stats to nothing. A raw delta
            // would go negative; the readings are still good, so use those.
            averager.record(stats(down: 1_000_000, downloaded: 900_000_000), at: at(0))
            averager.record(stats(down: 1_000_000, downloaded: 1_000_000), at: at(7.5))
            averager.record(stats(down: 1_000_000, downloaded: 2_000_000), at: at(15))
            t.equal(averager.displayed.download, 1_000_000,
                    "the rate readings carry it through the restart")
        },

        TestEntry("speed/window-spans-its-full-length") { t in
            var averager = SpeedAverager()
            // Readings land every 6 s, so none sits on the 15 s boundary (at
            // 3 s). Averaging only the ones strictly inside the window would
            // measure the last 12 s — here, all of the fast half and none of
            // the slow one, reporting the full 2 MB/s. Anchoring on the reading
            // before the cutoff keeps the slow start in view.
            averager.record(stats(down: 100_000), at: at(0))
            averager.record(stats(down: 100_000), at: at(6))
            averager.record(stats(down: 2_000_000), at: at(12))
            averager.record(stats(down: 2_000_000), at: at(18))
            t.equal(averager.windowDescription, "15 s average")
            t.expect(averager.displayed.download < 1_500_000,
                     "the slow start is still inside the window, got \(averager.displayed.download)")
        },

        TestEntry("speed/idle-does-not-start-the-clock") { t in
            var averager = SpeedAverager()
            // An hour of sitting there doing nothing.
            for step in stride(from: 0.0, through: 3600.0, by: 30.0) {
                averager.record(stats(down: 0), at: at(step))
            }
            t.expect(!averager.isTracking, "an idle session tracks nothing")
            t.equal(averager.displayed, .zero)

            // …so when a download finally starts, it starts responsive rather
            // than in the widest, slowest tier.
            let first = averager.record(stats(down: 4_000_000), at: at(3630))
            t.expect(first, "the first reading of a new transfer shows immediately")
            t.equal(averager.displayed.download, 4_000_000)
            t.isNil(averager.windowDescription)
        },

        TestEntry("speed/a-stall-does-not-reset-the-window") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 30.0, by: 2.5) {
                averager.record(stats(down: 2_000_000), at: at(step))
            }
            t.equal(averager.windowDescription, "30 s average")

            // Torrents stall for a few seconds constantly. Riding that out is
            // half of what the average is for, so a couple of zero readings
            // must not drop us back to live.
            averager.record(stats(down: 0), at: at(32.5))
            averager.record(stats(down: 0), at: at(35))
            t.expect(averager.isTracking, "a brief stall is still the same transfer")
            t.equal(averager.windowDescription, "30 s average")
            t.expect(averager.displayed.download > 0, "the menu bar doesn't blink out")
        },

        TestEntry("speed/a-finished-transfer-clears-out") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 30.0, by: 2.5) {
                averager.record(stats(down: 2_000_000), at: at(step))
            }
            // Zero for longer than the grace period: it's over. Clear rather
            // than leave a decaying ghost of a finished download in the bar —
            // the glyph reads the same numbers, so a lingering average would
            // keep the app claiming to be downloading.
            for step in stride(from: 32.5, through: 40.0, by: 2.5) {
                averager.record(stats(down: 0), at: at(step))
            }
            t.equal(averager.displayed, .zero)
            t.expect(!averager.isTracking, "the transfer is no longer tracked")
            t.isNil(averager.windowDescription)
        },

        TestEntry("speed/upload-is-smoothed-the-same-way") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 15.0, by: 2.5) {
                averager.record(stats(down: 0, up: 400_000, uploaded: Int64(step * 400_000)),
                                at: at(step))
            }
            t.equal(averager.displayed.upload, 400_000)
            t.expect(averager.displayed.isActive, "seeding alone still counts as activity")

            let spike = averager.record(stats(down: 0, up: 9_000_000), at: at(17.5))
            t.expect(!spike, "and it holds still between refreshes too")
        },

        TestEntry("speed/a-sleep-does-not-average-across-the-gap") { t in
            var averager = SpeedAverager()
            // A minute of 10 MB/s, byte counter keeping up…
            for step in stride(from: 0.0, through: 60.0, by: 2.5) {
                averager.record(stats(down: 10_000_000, downloaded: Int64(step * 10_000_000)),
                                at: at(step))
            }
            t.equal(averager.displayed.download, 10_000_000)

            // …then the lid shuts for four hours, and the first reading on the
            // far side is another 10 MB/s. Measuring from the last pre-sleep
            // anchor would divide an hour's worth of nothing into the counter
            // and report a few kB/s while the bar claims a 30 s average — and
            // the glyph, reading the same number, would say idle. The gap
            // breaks continuity, so the tiers start over instead.
            let wake = 60.0 + 4 * 3600
            averager.record(stats(down: 10_000_000, downloaded: 600_000_000), at: at(wake))
            t.equal(averager.displayed.download, 10_000_000, "the reading after a sleep is live")
            t.isNil(averager.windowDescription, "and honestly labelled as live")

            averager.record(stats(down: 10_000_000, downloaded: 625_000_000), at: at(wake + 2.5))
            t.equal(averager.displayed.download, 10_000_000, "and it stays right afterwards")
        },

        TestEntry("speed/a-backward-clock-step-starts-over") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 30.0, by: 2.5) {
                averager.record(stats(down: 2_000_000), at: at(step))
            }
            // NTP corrects a bad RTC and time jumps back 10 s. Out-of-order
            // samples give the time-weighted mean a negative interval to credit
            // — here a 10 s one against the newest reading, enough to drag the
            // whole window below zero. A negative speed reads as inactive, so
            // the menu bar would blank out mid-download. It's also what stops
            // `prune` pruning, since every cutoff is now behind every sample.
            averager.record(stats(down: 8_000_000), at: at(20))
            t.expect(averager.displayed.download > 0,
                     "never a negative speed, got \(averager.displayed.download)")
            t.equal(averager.displayed.download, 8_000_000, "the jump starts the tiers over")
            t.isNil(averager.windowDescription)

            // And it picks the tiers back up from the new clock rather than
            // hoarding the samples from the old one.
            for step in stride(from: 22.5, through: 40.0, by: 2.5) {
                averager.record(stats(down: 8_000_000), at: at(step))
            }
            t.equal(averager.displayed.download, 8_000_000)
            t.equal(averager.windowDescription, "15 s average")
        },

        TestEntry("speed/a-pinned-byte-counter-falls-back-to-the-readings") { t in
            var averager = SpeedAverager()
            // A server that reports `current-stats` but never advances it.
            // Trusting the delta would report a flat 0 B/s through a download —
            // no numbers in the bar and an idle glyph, mid-transfer.
            for step in stride(from: 0.0, through: 20.0, by: 2.5) {
                averager.record(stats(down: 5_000_000, downloaded: 500_000_000), at: at(step))
            }
            t.equal(averager.displayed.download, 5_000_000, "the readings carry it")
            t.equal(averager.windowDescription, "15 s average")
        },

        TestEntry("speed/a-sparse-cadence-still-measures-its-window") { t in
            var averager = SpeedAverager()
            // Readings 29 s apart — what a long configured poll interval looks
            // like. The nearest anchor to a 30 s cutoff is then 58 s old, so
            // anchoring blindly would measure nearly double the window it's
            // labelled with: here it would drag the 1 MB/s stretch that ended
            // at 58 s into a window that starts at 57 s, and report 2 MB/s for
            // a half-minute that was all but entirely spent at 3.
            averager.record(stats(down: 1_000_000), at: at(0))
            averager.record(stats(down: 1_000_000), at: at(29))
            averager.record(stats(down: 1_000_000), at: at(58))
            averager.record(stats(down: 3_000_000), at: at(87))
            t.equal(averager.windowDescription, "30 s average")
            t.equal(averager.displayed.download, 3_000_000,
                    "the last 30 s is all at the new rate")
        },

        TestEntry("speed/reset-starts-over-from-live") { t in
            var averager = SpeedAverager()
            for step in stride(from: 0.0, through: 30.0, by: 2.5) {
                averager.record(stats(down: 2_000_000), at: at(step))
            }
            averager.reset()
            t.equal(averager.displayed, .zero)
            t.expect(!averager.isTracking, "reset drops the tracked transfer")

            // A reconnect is a fresh start: the first reading through shows
            // whole, in the live tier.
            averager.record(stats(down: 7_000_000), at: at(40))
            t.equal(averager.displayed.download, 7_000_000)
            t.isNil(averager.windowDescription)
        },
    ]
}
#endif
