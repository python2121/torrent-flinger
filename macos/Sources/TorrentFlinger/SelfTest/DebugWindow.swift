#if DEBUG
import AppKit
import SwiftUI
@testable import TorrentFlingerCore

/// Opens one of the app's windows on screen and nothing else, so its layout can
/// be inspected (and screenshotted) without clicking through the menu bar —
/// driving the real status item needs an Accessibility grant a terminal session
/// doesn't have.
///
///     swift run TorrentFlinger --show-window options
///     swift run TorrentFlinger --show-window popover|add|details|stats
///     swift run TorrentFlinger --show-window popover --demo   # invented data
///
/// Offscreen snapshotting was tried first and abandoned: SwiftUI draws tab bars
/// and bottom bars into its own display list rather than into AppKit subviews,
/// so neither `cacheDisplay` nor `CALayer.render(in:)` captures them — the
/// resulting images silently omitted half the chrome. Showing the real window
/// and capturing it externally is the only faithful option.
enum DebugWindow {
    private final class Delegate: NSObject, NSApplicationDelegate {
        let which: String
        let demo: Bool
        var window: NSWindow?

        init(which: String, demo: Bool) {
            self.which = which
            self.demo = demo
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            MainActor.assumeIsolated {
                // --demo swaps the live server for invented data, which is what
                // the documentation screenshots are taken against: the real
                // config.json would put the reader's hostname, torrent names and
                // paths into a public repository.
                let store = demo
                    ? TorrentStore(config: DemoRPC.config(), client: DemoRPC.client())
                    : TorrentStore(config: Config.load())
                // Let the first poll land so the views have data to show.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: demo ? 400_000_000 : 2_000_000_000)
                    self.present(store: store)
                }
            }
        }

        @MainActor
        private func present(store: TorrentStore) {
            let content: AnyView
            let size: NSSize
            switch which {
            case "popover":
                content = AnyView(PopoverView(store: store))
                size = NSSize(width: 380, height: 560)
            case "add":
                // An invented series name that still trips the TV pattern, so
                // the dialog demonstrates the auto-suggested folder without
                // putting someone's actual downloads in a screenshot.
                let model = AddTorrentViewModel(
                    store: store,
                    link: "magnet:?xt=urn:btih:x&dn=Creative.Commons.Chronicles.S02E04.1080p.WEB")
                Task { await model.load() }
                content = AnyView(AddTorrentView(model: model))
                size = NSSize(width: 460, height: 220)
            case "stats":
                let model = StatsViewModel(store: store)
                Task { await model.load() }
                content = AnyView(StatsView(model: model))
                size = NSSize(width: 360, height: 260)
            case _ where which.hasPrefix("details"):
                // "details:26" opens that torrent; bare "details" takes the
                // first one the server lists, which for the Files tab is
                // rarely the one with an interesting directory tree.
                let parts = which.split(separator: ":").dropFirst().map(String.init)
                let wanted = parts.compactMap { Int($0) }.first
                guard let torrent = wanted.flatMap({ id in store.torrents.first { $0.id == id } })
                        ?? store.torrents.first else {
                    print("no torrents on the server to show details for")
                    exit(1)
                }
                let model = DetailsViewModel(store: store, torrentID: torrent.id)
                // "details:26:files" opens straight to that tab.
                if let tab = parts.compactMap({ DetailsViewModel.Tab(rawValue: $0) }).first {
                    model.selectedTab = tab
                }
                model.start()
                content = AnyView(DetailsView(model: model))
                size = NSSize(width: 760, height: 600)
            default:
                let model = OptionsViewModel(store: store)
                // "options:limits" opens straight to that tab.
                if let name = which.split(separator: ":").dropFirst().first,
                   let index = ["server", "general", "download", "local", "limits"]
                       .firstIndex(of: String(name)),
                   let tab = OptionsViewModel.Tab(rawValue: index) {
                    model.selectedTab = tab
                }
                Task { await model.loadSessionLimits() }
                content = AnyView(OptionsView(model: model))
                size = NSSize(width: 600, height: 520)
            }

            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: content)
            window.title = which
            window.setContentSize(size)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = window
        }
    }

    /// Held so `NSApplication`'s weak `delegate` doesn't free it.
    nonisolated(unsafe) private static var delegate: Delegate?

    static func runIfRequested(_ arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: "--show-window") else { return }
        let which = arguments.dropFirst(flagIndex + 1).first { !$0.hasPrefix("--") } ?? "options"

        let app = NSApplication.shared
        let delegate = Delegate(which: which, demo: arguments.contains("--demo"))
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}
#endif
