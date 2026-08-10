// swift-tools-version: 5.9
import PackageDescription

// Single target. The test suite is not a separate module: this machine class
// (Command Line Tools, no full Xcode) ships neither XCTest nor swift-testing,
// so the suite is hand-rolled and lives under Sources/TorrentFlinger/SelfTest,
// wrapped in `#if DEBUG` and dispatched by `TorrentFlinger --self-test`. A
// release build (what build-app.sh produces) compiles none of it.
let package = Package(
    name: "TorrentFlinger",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TorrentFlinger",
            path: "Sources/TorrentFlinger"
        )
    ]
)
