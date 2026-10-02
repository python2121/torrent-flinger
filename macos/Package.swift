// swift-tools-version: 5.9
import PackageDescription

// Two targets. `TorrentFlingerCore` is the Foundation-only layer — the RPC
// client, models, config, formatting, TV detection, the file tree — shared
// by the macOS menu-bar app here and the iPhone app in ../ios, which
// consumes this package as a local dependency. `TorrentFlinger` is the Mac
// executable.
//
// The test suite is not a separate module: this machine class (Command Line
// Tools, no full Xcode) ships neither XCTest nor swift-testing, so the suite
// is hand-rolled and lives under Sources/TorrentFlinger/SelfTest, wrapped in
// `#if DEBUG` and dispatched by `TorrentFlinger --self-test`. A release build
// (what build-app.sh produces) compiles none of it.
let package = Package(
    name: "TorrentFlinger",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TorrentFlingerCore", targets: ["TorrentFlingerCore"]),
    ],
    targets: [
        .target(
            name: "TorrentFlingerCore",
            path: "Sources/TorrentFlingerCore"
        ),
        .executableTarget(
            name: "TorrentFlinger",
            dependencies: ["TorrentFlingerCore"],
            path: "Sources/TorrentFlinger"
        ),
    ]
)
