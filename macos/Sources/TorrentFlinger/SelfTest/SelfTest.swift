#if DEBUG
import Foundation
@testable import TorrentFlingerCore

/// The suite registry and its entry point.
///
/// Dispatched from `App.main` before `NSApplication` exists (and before the
/// single-instance lock), so running the tests never disturbs an installed
/// copy in the menu bar:
///
///     swift run TorrentFlinger --self-test
///     swift run TorrentFlinger --self-test client/    # filter by name
///
/// The whole SelfTest directory is `#if DEBUG`, so `swift build -c release` —
/// what `build-app.sh` runs — compiles none of it into the shipping app.
enum SelfTest {
    static let entries: [TestEntry] =
        FormatTests.all + ConfigTests.all + TorrentModelTests.all
        + UILogicTests.all + FileTreeTests.all + SpeedAveragerTests.all + ClientTests.all

    /// Returns true if the arguments requested a test run (in which case it has
    /// already run them and exited).
    static func runIfRequested(_ arguments: [String]) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: "--self-test") else { return false }
        // An optional trailing word filters by test-name substring.
        let filter = arguments.dropFirst(flagIndex + 1).first { !$0.hasPrefix("--") }

        // main() isn't async, so drive the async suite from a semaphore-gated
        // detached task. This process does nothing else, so blocking is fine.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = 1
        Task.detached {
            status = await TestRunner.run(entries, filter: filter)
            done.signal()
        }
        done.wait()
        exit(status)
    }
}
#endif
