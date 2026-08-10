#if os(macOS)
import AppKit
import SwiftUI

/// A titled, ordinary `NSWindow` hosting a SwiftUI view — the Options, Stats,
/// Details and Add windows all sit in one of these rather than in the
/// borderless popover panel, so they're movable, closable and stick around
/// across popover open/close.
///
/// Built lazily on first `present` and reused afterwards.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Called when the user closes the window (not when we hide it ourselves).
    var onClose: (() -> Void)?

    func present<Content: View>(
        title: String,
        size: NSSize,
        resizable: Bool = true,
        root: Content
    ) {
        if window == nil {
            let hosting = NSHostingController(rootView: AnyView(root))
            var style: NSWindow.StyleMask = [.titled, .closable]
            if resizable { style.insert(.resizable) }
            let created = KeyCloseableWindow(contentViewController: hosting)
            created.title = title
            created.styleMask = style
            created.isReleasedWhenClosed = false
            created.setContentSize(size)
            created.center()
            created.delegate = self
            window = created
        }
        // Accessory apps aren't active, so without this the window opens
        // behind and unfocused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// As an accessory app we have no menu bar, so there's no Close menu item to
/// give ⌘W its key equivalent — handle it (and Escape) on the window itself.
private final class KeyCloseableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Escape reaches the window as cancelOperation(_:) via the responder chain.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
#endif
