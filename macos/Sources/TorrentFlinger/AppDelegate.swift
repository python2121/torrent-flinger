#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import TorrentFlingerCore

/// Borderless panel that can still become key, so the SwiftUI controls inside
/// (search field, buttons) receive clicks and keystrokes without activating the
/// (accessory) app.
private final class PopoverPanel: NSPanel {
    /// Invoked on Escape (or Cmd+.) — a borderless panel has no close button,
    /// so this is the keyboard dismissal path.
    var onCancel: (() -> Void)?

    /// Invoked on Up (-1) / Down (+1) to walk the torrent list, with `extend`
    /// set when Shift is held.
    var onMove: ((_ direction: Int, _ extend: Bool) -> Void)?

    /// Invoked on Right (true) / Left (false) to open or close the highlighted
    /// rows. Returns whether it claimed the key: with nothing highlighted it
    /// doesn't, and the arrow goes back to the search field's caret.
    var onExpand: ((_ expand: Bool) -> Bool)?

    override var canBecomeKey: Bool { true }

    // Arrow keys drive the list, never the search field's caret. Intercepted in
    // sendEvent rather than keyDown because the field editor is first responder
    // whenever the panel is open, and it swallows (and beeps at) the arrows
    // before the window ever sees them. Up/Down do nothing in a single-line
    // field, so nothing is lost by taking them — Shift included, since
    // shift-arrow there would only select nothing.
    override func sendEvent(_ event: NSEvent) {
        let arrows: Set<UInt16> = [125, 126]   // down, up
        let claimed: NSEvent.ModifierFlags = [.command, .option, .control]
        if event.type == .keyDown, arrows.contains(event.keyCode),
           event.modifierFlags.intersection(claimed).isEmpty {
            onMove?(event.keyCode == 125 ? 1 : -1, event.modifierFlags.contains(.shift))
            return
        }
        // Left/Right open and close the highlighted rows — but only when there
        // are some. A single-line field ignores Up/Down, so those can be taken
        // outright; Left/Right move the caret, so they're only borrowed when
        // there's a selection to act on, and handed back otherwise.
        let sides: Set<UInt16> = [123, 124]    // left, right
        if event.type == .keyDown, sides.contains(event.keyCode),
           event.modifierFlags.intersection(claimed).isEmpty,
           onExpand?(event.keyCode == 124) == true {
            return
        }
        super.sendEvent(event)
    }

    // Esc reaches the window as cancelOperation(_:) via the responder chain
    // when no view inside claims it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Fallback: if a responder swallows the cancel selector but lets the raw
    // key event bubble, still treat Esc (keyCode 53) as dismiss instead of
    // letting NSWindow beep on the unhandled key.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TorrentStore()
    private var statusItem: NSStatusItem!
    private var panel: PopoverPanel!
    private var hostingController: NSHostingController<PopoverView>!
    private var cancellables: Set<AnyCancellable> = []
    private var sizeObservation: NSKeyValueObservation?
    private var clickMonitor: Any?

    private lazy var options = OptionsWindowController(store: store)
    private lazy var stats = StatsWindowController(store: store)
    private lazy var addDialog = AddTorrentWindowController(store: store)
    private var details: [Int: DetailsWindowController] = [:]

    /// Links passed on the command line, replayed once the app is up.
    var pendingLinks: [String] = []

    // Visual + motion tuning, shared with the ClaudeUsage panel this is
    // modeled on.
    private let panelWidth: CGFloat = 380
    private let cornerRadius: CGFloat = 12
    private let tintOpacity: CGFloat = 0.7
    private let slideDistance: CGFloat = 8
    private let openDuration: TimeInterval = 0.16
    private let closeDuration: TimeInterval = 0.12

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildPanel()

        // objectWillChange fires before the @Published value is written, so
        // hop to the next runloop tick to read the post-write state.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
        Notifier.requestAuthorization()
        // Must happen before (or alongside) the first poll: without it macOS
        // silently blocks every LAN request instead of asking. The launch poll
        // races it and usually loses, so re-poll the moment access is live
        // rather than leaving "Disconnected" up until the next tick.
        LocalNetwork.requestAccess { [weak self] in
            self?.store.poll()
        }
        buildMainMenu()

        let links = pendingLinks
        pendingLinks = []
        links.forEach { handleLink($0) }
    }

    /// Accessory apps have no main menu, so Cmd+V/A/C/X have no responder.
    /// Wire up a minimal Edit menu so paste works in the text fields.
    private func buildMainMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Link handling (magnet: URLs and .torrent files)

    /// LaunchServices delivers both `magnet:` URLs and dropped/opened
    /// `.torrent` files here — the macOS equivalent of the Linux build's
    /// `x-scheme-handler/magnet` + `application/x-bittorrent` registration.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleLink(url.isFileURL ? url.path : url.absoluteString)
        }
    }

    func handleLink(_ raw: String) {
        var link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.hasPrefix("file://"), let url = URL(string: link) { link = url.path }
        guard !link.isEmpty else { return }

        if store.config.showAddDialog {
            closePanel()
            addDialog.present(link: link)
        } else {
            store.add(link: link, downloadDir: nil, paused: store.config.startPaused)
        }
    }

    func addTorrentFile() {
        closePanel()
        let openPanel = NSOpenPanel()
        openPanel.title = "Add torrent"
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "torrent") {
            openPanel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard openPanel.runModal() == .OK else { return }
        openPanel.urls.forEach { handleLink($0.path) }
    }

    func addMagnetFromClipboard() {
        guard let magnet = store.clipboardMagnet() else {
            Notifier.post(title: "No magnet link",
                          body: "The clipboard doesn't contain a magnet: link.")
            return
        }
        handleLink(magnet)
    }

    // MARK: Auxiliary windows

    func showOptions() {
        closePanel()
        options.show()
    }

    func showStats() {
        closePanel()
        stats.show()
    }

    /// One details window per torrent, reused while it stays open. A nil `tab`
    /// leaves the tab alone — a second Details… shouldn't yank an open window
    /// back to Info, but "Torrent files…" should always land on Files.
    func showDetails(_ torrentID: Int, tab: DetailsViewModel.Tab? = nil) {
        closePanel()
        if let existing = details[torrentID] {
            if let tab { existing.select(tab: tab) }
            existing.show()
            return
        }
        let name = store.torrent(id: torrentID)?.name ?? "Torrent"
        let controller = DetailsWindowController(store: store, torrentID: torrentID,
                                                 name: name, tab: tab ?? .info)
        controller.onClose = { [weak self] in self?.details[torrentID] = nil }
        details[torrentID] = controller
        controller.show()
    }

    // MARK: Panel construction

    private func buildPanel() {
        hostingController = NSHostingController(rootView: PopoverView(
            store: store,
            actions: PopoverActions(
                addFile: { [weak self] in self?.addTorrentFile() },
                addClipboardMagnet: { [weak self] in self?.addMagnetFromClipboard() },
                addLink: { [weak self] link in self?.handleLink(link) },
                showDetails: { [weak self] id in self?.showDetails(id) },
                showFiles: { [weak self] id in self?.showDetails(id, tab: .files) },
                showOptions: { [weak self] in self?.showOptions() },
                showStats: { [weak self] in self?.showStats() },
                quit: { NSApp.terminate(nil) }
            )
        ))
        // Report the SwiftUI ideal size as preferredContentSize so we can size
        // the panel to the content (and resize-follow when it changes).
        hostingController.sizingOptions = [.preferredContentSize]

        // Rounded, vibrant background to replace the popover chrome we lose by
        // going borderless. `.menu` is the most opaque public material, but the
        // system Control Center panels are more opaque still, so we wash the
        // blur with a semi-opaque adaptive tint below.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Round the blur via a resizable mask image — the documented way for
        // NSVisualEffectView. (layer.cornerRadius on it is unreliable: square
        // corners poke out during animation/resize.)
        effect.maskImage = Self.roundedMaskImage(radius: cornerRadius)

        // Opacity wash: in light mode a window-background fill over the blur
        // lifts it toward the system panels' solidity. In dark mode the blur is
        // already dark enough, so the tint is clear (off).
        let opacity = tintOpacity
        let tint = NSBox()
        tint.boxType = .custom
        tint.titlePosition = .noTitle
        tint.borderWidth = 0
        tint.cornerRadius = cornerRadius
        tint.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .clear
                : NSColor.windowBackgroundColor.withAlphaComponent(opacity)
        }
        tint.translatesAutoresizingMaskIntoConstraints = false

        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none           // we animate manually
        panel.isReleasedWhenClosed = false
        // .moveToActiveSpace (not .canJoinAllSpaces) so the panel follows the
        // user to whichever Space they're currently viewing.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        // Escape peels back one layer per press — selection, then the search
        // filter, then the panel — exactly as the Linux popup does.
        panel.onCancel = { [weak self] in
            guard let self else { return }
            // The *visible* selection decides, so a press always changes
            // something on screen: rows the filter has hidden are cleared with
            // the search they're hiding behind, one press later.
            switch Selection.escape(hasSelection: !self.store.selectedInVisualOrder.isEmpty,
                                    hasSearch: !self.store.searchText.isEmpty) {
            case .clearSelection: self.store.clearSelection()
            case .clearSearch: self.store.searchText = ""
            case .close: self.closePanel()
            }
        }
        // Up/Down move through the list exactly as clicking a row does;
        // ⇧-arrow extends the range the way a ⇧-click would.
        panel.onMove = { [weak self] direction, extend in
            self?.store.moveSelection(direction, extend: extend)
        }
        panel.onExpand = { [weak self] expand in
            self?.store.setExpanded(expand) ?? false
        }
    }

    /// A resizable rounded-rect mask: the center stretches and the corners stay
    /// fixed (cap insets), so one image rounds the effect view at any size.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Show / hide

    @objc private func togglePanel(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Right-click on the status item: a native `NSMenu` mirroring the Linux
    /// tray menu. Assigned to `statusItem.menu` only for the duration of the
    /// click — a permanently assigned menu would hijack left-clicks too — and
    /// detached in `menuDidClose`.
    private func showContextMenu() {
        closePanel()

        let menu = NSMenu()
        menu.addItem(item("Show torrents", #selector(menuShowPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Add torrent file…", #selector(menuAddFile(_:))))
        menu.addItem(item("Add magnet from clipboard", #selector(menuAddClipboard(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Start all", #selector(menuStartAll(_:))))
        menu.addItem(item("Pause all", #selector(menuPauseAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Statistics…", #selector(menuStats(_:))))
        menu.addItem(item("Full web interface", #selector(menuWeb(_:))))
        menu.addItem(item("Options…", #selector(menuOptions(_:))))
        menu.addItem(.separator())
        // A local selector (not NSApplication.terminate(_:)) and no key
        // equivalent: macOS auto-decorates well-known selectors with a system
        // icon and renders a ⌘Q hint — we want neither.
        menu.addItem(item("Quit Torrent Flinger", #selector(menuQuit(_:))))
        menu.delegate = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func menuShowPanel(_ sender: Any?) { showPanel() }
    @objc private func menuAddFile(_ sender: Any?) { addTorrentFile() }
    @objc private func menuAddClipboard(_ sender: Any?) { addMagnetFromClipboard() }
    @objc private func menuStartAll(_ sender: Any?) { store.startAll() }
    @objc private func menuPauseAll(_ sender: Any?) { store.stopAll() }
    @objc private func menuStats(_ sender: Any?) { showStats() }
    @objc private func menuWeb(_ sender: Any?) { store.openWebInterface() }
    @objc private func menuOptions(_ sender: Any?) { showOptions() }
    @objc private func menuQuit(_ sender: Any?) { NSApp.terminate(nil) }

    private func showPanel() {
        store.refreshClipboardOffer()
        store.setPanelVisible(true)

        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.view.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: panelWidth, height: 300) }
        // On the very first click after launch the hosting view can report a
        // degenerate fittingSize before SwiftUI's initial layout settles; an
        // over-tall panel drives the origin math (topEdge - height) below the
        // screen. Clamp to the visible frame — followContentSize corrects the
        // size once the real preferredContentSize lands.
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame,
           size.width > visible.width || size.height > visible.height {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        panel.setContentSize(size)

        guard let finalOrigin = panelOrigin(for: panel.frame.size) else {
            // Status-item geometry unresolved (seen on the first click right
            // after launch). Never fall through to the panel's default frame —
            // its (0,0) origin puts the popover at the bottom-left corner.
            if let visible = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(
                    x: visible.maxX - panel.frame.width - 8,
                    y: visible.maxY - panel.frame.height
                ))
            }
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // Start tucked up under the menu bar and transparent, then slide down
        // and fade in. The fade masks the few px that briefly overlap the bar.
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + slideDistance))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }

        // When a refresh adds/removes a row the content height changes; keep the
        // panel pinned just under the menu bar instead of drifting.
        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.followContentSize() }
        }

        // Transient dismissal: a mouse-down anywhere outside this app closes
        // the panel. Clicks inside the panel and on our own status item are
        // local events and don't reach a global monitor, so they don't
        // double-toggle.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func followContentSize() {
        guard panel.isVisible else { return }
        let size = hostingController.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
        if let origin = panelOrigin(for: panel.frame.size) {
            panel.setFrameOrigin(origin)
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        sizeObservation?.invalidate(); sizeObservation = nil
        statusItem.button?.highlight(false)
        store.setPanelVisible(false)

        let up = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + slideDistance)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(up)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    /// Final origin: top edge just below the menu bar, centered under the status
    /// item, clamped on-screen.
    private func panelOrigin(for size: NSSize) -> NSPoint? {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen
        else { return nil }

        let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let topEdge = screen.visibleFrame.maxY          // first point below the menu bar
        var origin = NSPoint(x: buttonInScreen.midX - size.width / 2, y: topEdge - size.height)

        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - size.width
        origin.x = min(max(origin.x, minX), maxX)
        return origin
    }

    // MARK: Menubar item

    /// Menu-bar height for the state glyph. The bar gives ~18pt; 16 leaves the
    /// optical breathing room the system's own icons have.
    private static let trayIconSize: CGFloat = 16

    /// Upload only earns space in the menu bar above this. Seeding trickles
    /// along at a few kB/s more or less permanently, and a number that's always
    /// there but never interesting is just width taken from the one being
    /// watched. SI, like every other speed in both builds, so this is 1 MB/s.
    /// The tooltip and the popover footer still show upload at any speed.
    private static let uploadDisplayThreshold = 1_000_000

    private static var trayImageCache: [TrayIcon: NSImage] = [:]

    /// The state glyph, loaded from the SVG shared with the Linux build.
    ///
    /// `isTemplate` is what makes one monochrome asset work everywhere: AppKit
    /// throws the colour away and re-renders the silhouette, so it adapts to
    /// light/dark, to a tinted menu bar, and inverts while the panel is open.
    /// Qt has no equivalent, so the Linux build tints the same file by hand.
    ///
    /// Falls back to an SF Symbol when the asset is missing — that's the
    /// `swift run` dev loop, which has no bundle to load resources from.
    private static func trayImage(_ icon: TrayIcon, described: String?) -> NSImage? {
        if let cached = trayImageCache[icon] { return cached }

        let image: NSImage?
        if let url = Bundle.main.url(forResource: icon.assetName, withExtension: "svg"),
           let loaded = NSImage(contentsOf: url) {
            loaded.size = NSSize(width: trayIconSize, height: trayIconSize)
            image = loaded
        } else {
            image = NSImage(systemSymbolName: icon.fallbackSymbol,
                            accessibilityDescription: described ?? icon.rawValue)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = described ?? icon.rawValue
        if let image { trayImageCache[icon] = image }
        return image
    }

    /// Icon + (optionally) the aggregate speeds. The Linux build puts this in
    /// the tray tooltip; a menu bar has room for the numbers themselves, so the
    /// interesting state is visible without clicking.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        // Smoothed, not raw — a menu-bar number is read at a glance and out of
        // the corner of an eye, which is the worst possible audience for a
        // reading that halves and doubles every couple of seconds. The glyph
        // takes the same value so it can't disagree with the numbers beside it.
        //
        // With the numbers switched off there's nothing to agree with, and no
        // fast sampling behind it either (the speeds-only tick is off too), so
        // the glyph goes back to the raw reading rather than waiting out a
        // smoothing window it can't feed. Otherwise the arrow would outlive a
        // finished download by up to two polls instead of one.
        let showSpeeds = store.config.menubarShowSpeeds
        let speeds = showSpeeds
            ? store.menubarSpeeds
            : SpeedAverager.Speeds(download: store.stats.downloadSpeed,
                                   upload: store.stats.uploadSpeed)
        let icon = TrayIcon.current(connected: store.connected,
                                    downloadSpeed: speeds.download,
                                    recentlyAdded: store.recentlyAdded)

        var parts: [String] = []
        if showSpeeds, store.connected {
            if speeds.download > 0 {
                parts.append("↓\(Format.speedShort(speeds.download))")
            }
            if speeds.upload > Self.uploadDisplayThreshold {
                parts.append("↑\(Format.speedShort(speeds.upload))")
            }
        }
        let title = parts.joined(separator: " ")

        // The speeds are computed first because they decide whether the glyph
        // is drawn at all: while downloading, the arrow only repeats what the
        // numbers say.
        if icon.showsGlyph(speedsVisible: !title.isEmpty) {
            button.image = Self.trayImage(icon, described: store.errorMessage)
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }

        // One figure gets the menu bar's own size, so it reads as one of the
        // system's items rather than a footnote beside them. Two only fit by
        // giving those two points back — `↓1.2M ↑2.4M` at full size crowds the
        // bar, and a notched display has genuinely little room to spare.
        //
        // Regular weight for the same reason — `menuBarFont` is regular, and
        // anything heavier reads as emphasis the numbers haven't earned. Only
        // the monospaced digits are ours, so the figures don't jitter sideways
        // as they change.
        let barPointSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: parts.count > 1 ? barPointSize - 2 : barPointSize, weight: .regular)
        // No leading space when the numbers stand alone — that padding only
        // exists to separate them from the glyph.
        let spacer = button.imagePosition == .noImage ? "" : " "
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : "\(spacer)\(title)",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])

        if store.connected {
            // The tooltip is the deliberate look, so it gets the live numbers —
            // plus a note of which window the bar is showing, so the two
            // disagreeing reads as the design it is rather than a bug.
            var lines = [
                "Torrent Flinger — \(store.torrents.count) torrents",
                "DL: \(Format.speed(store.stats.downloadSpeed))  UL: \(Format.speed(store.stats.uploadSpeed))",
            ]
            if let window = store.menubarWindowDescription {
                lines.append("Menu bar: \(window)")
            }
            button.toolTip = lines.joined(separator: "\n")
        } else {
            button.toolTip = "Torrent Flinger — \(store.errorMessage ?? "connection failed")"
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Detach the transient right-click menu so the next left-click goes back
    /// to toggling the panel instead of re-opening the menu.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
#endif
