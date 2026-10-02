#if os(macOS)
import AppKit
import TorrentFlingerCore

@main
struct TorrentFlingerMain {
    // Held in a static so NSApplication's weak `delegate` reference doesn't
    // free it.
    private static let appDelegate = AppDelegate()

    static func main() {
        #if DEBUG
        // `--self-test` runs the suite and exits, before the single-instance
        // lock, so testing never disturbs an installed copy in the menu bar.
        _ = SelfTest.runIfRequested(CommandLine.arguments)
        // Show a single window on its own, for inspecting layout without
        // clicking through the menu bar.
        DebugWindow.runIfRequested(CommandLine.arguments)
        #endif

        let links = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("--") }

        // Only one menubar GUI at a time. A second launch that carries links
        // hands them to the running instance (the Linux build's local-socket
        // forwarding; on macOS LaunchServices already does the delivery) and
        // exits — the same "click a magnet twice, get one app" behavior.
        guard SingleInstance.acquire() else {
            forward(links)
            exit(0)
        }

        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        appDelegate.pendingLinks = links
        app.run()
    }

    /// Re-open the links against *our* bundle so they reach the instance that
    /// holds the lock rather than whatever else claims `magnet:`/`.torrent`.
    private static func forward(_ links: [String]) {
        let urls: [URL] = links.compactMap { link in
            link.hasPrefix("magnet:") ? URL(string: link) : URL(fileURLWithPath: link)
        }
        guard !urls.isEmpty else { return }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            NSWorkspace.shared.open(urls, withApplicationAt: bundle,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }
}
#endif
