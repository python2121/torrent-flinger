#if os(macOS)
import AppKit
import TorrentFlingerCore

/// The handful of modal confirmations the app needs, as `NSAlert`s so they
/// look native and work from an accessory app (which has no key window of its
/// own most of the time).
enum Dialogs {
    /// "Remove … from Transmission?" with the Linux build's
    /// "Also delete downloaded data" checkbox.
    /// Returns nil when the user cancels, otherwise the checkbox state.
    @MainActor
    static func confirmRemove(what: String) -> Bool? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove"
        alert.informativeText = "Remove \(what) from Transmission?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let checkbox = NSButton(checkboxWithTitle: "Also delete downloaded data", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        // Accessory apps aren't active, so the modal would otherwise open
        // unfocused and behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return checkbox.state == .on
    }

    /// The label the confirmation uses for a set of torrents.
    static func describe(_ names: [String]) -> String {
        if names.count == 1, let only = names.first { return "“\(only)”" }
        return "\(names.count) torrents"
    }

    /// Folder picker for the "local mount" setting in Options.
    @MainActor
    static func chooseDirectory(title: String, startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
#endif
