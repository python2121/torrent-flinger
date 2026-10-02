#if os(macOS)
import AppKit
import SwiftUI
import TorrentFlingerCore

/// Everything the popover needs from the app shell (windows, file pickers).
/// Passing them in as closures keeps the view free of `AppDelegate`.
struct PopoverActions {
    var addFile: () -> Void = {}
    var addClipboardMagnet: () -> Void = {}
    var addLink: (String) -> Void = { _ in }
    var showDetails: (Int) -> Void = { _ in }
    /// The same window as `showDetails`, opened on its Files tab.
    var showFiles: (Int) -> Void = { _ in }
    var showOptions: () -> Void = {}
    var showStats: () -> Void = {}
    var quit: () -> Void = {}
}

/// One status section of the list. A named struct rather than the `(name:,
/// torrents:)` tuple `TorrentStore.groups` hands back, because `ForEach` needs
/// an `Equatable` element to notice that a section's contents changed.
struct GroupItem: Identifiable, Equatable {
    let name: String
    let torrents: [Torrent]
    var id: String { name }
}

/// The tray popup, ported from `linux/flinger/ui/popup.py` and dressed in the
/// ClaudeUsage panel's visual language: header strip (title row + toolbar with
/// search and add button), status-grouped torrent list with expandable rows,
/// footer with aggregate speeds + free space and
/// stats/web-UI/settings controls.
struct PopoverView: View {
    @ObservedObject var store: TorrentStore
    var actions = PopoverActions()

    /// Matches the panel width set in `AppDelegate`.
    private let width: CGFloat = 380
    /// Roughly eleven collapsed rows before the list starts scrolling — the
    /// Linux popup is a comparable ~24×31 grid units tall.
    private let maxListHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            toolbar
            Divider()
            if let magnet = store.clipboardOffer {
                clipboardBanner(magnet)
            }
            list
            Divider()
            footer
        }
        .frame(width: width)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Transmission")
                .font(.headline)
                .help(store.config.host)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(store.connected ? StateColor.positive : StateColor.negative)
                    .frame(width: 7, height: 7)
                Text(store.connected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(store.errorMessage ?? store.config.rpcURL)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField

            Menu {
                Button("Add torrent file…") { actions.addFile() }
                Button("Add magnet from clipboard") { actions.addClipboardMagnet() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add torrent")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search…", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }

    // MARK: Clipboard banner

    private func clipboardBanner(_ magnet: String) -> some View {
        HStack(spacing: 6) {
            Text("Add “\(Format.linkDisplayName(magnet))”?")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Add") {
                store.dismissClipboardOffer()
                actions.addLink(magnet)
            }
            .buttonStyle(.link)
            .font(.caption)
            Button {
                store.dismissClipboardOffer()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.45)))
        )
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let groups = store.groups.map { GroupItem(name: $0.name, torrents: $0.torrents) }
        if groups.isEmpty {
            placeholder
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            sectionHeader(group.name, count: group.torrents.count)
                            ForEach(group.torrents) { torrent in
                                TorrentRowView(store: store, torrent: torrent, actions: actions)
                                    // A row's identity has to carry its section
                                    // too. A torrent that changes state moves
                                    // between sections, and for that update the
                                    // list holds both the old row and the new
                                    // one; identified by torrent id alone those
                                    // two collide, and SwiftUI keeps drawing the
                                    // stale one — a torrent that errored out
                                    // stayed blue with its old subtitle until
                                    // the panel was reopened.
                                    .id(Self.rowID(group: group.name, torrent: torrent.id))
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: maxListHeight)
                .scrollBounceBehavior(.basedOnSize)
                // No scrollbar. The overlay scroller sits over the trailing
                // ~17pt of the list, but while it's *revealed* — the flash when
                // the panel opens, or any scroll — its live hit strip reaches
                // ≈33pt in from the edge, squarely over every row's chevron.
                // A click there goes to the NSScroller knob, does nothing
                // visible, and collapses the scroller, so the *next* click at
                // the same point reaches the button: the infamous "first click
                // after opening does nothing". Verified by logging
                // `contentView.hitTest` per click in PopoverPanel.sendEvent —
                // first click hit=NSScroller, second (same coordinates)
                // hit=PlatformGroupContainer. Trackpad/wheel scrolling is
                // untouched; only the indicator is gone.
                .scrollIndicators(.hidden)
                // Keyboard navigation can land on a row that's scrolled off;
                // the store asks for it here and we clear the request so the
                // next press on the same row scrolls again. The row is asked
                // for by torrent id, so find the section it currently sits in
                // to rebuild the composite id the row is registered under.
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    if let group = groups.first(where: { $0.torrents.contains { $0.id == target } }) {
                        proxy.scrollTo(Self.rowID(group: group.name, torrent: target))
                    }
                    store.clearScrollTarget()
                }
            }
        }
    }

    /// Scroll/identity key for one row: section plus torrent id.
    static func rowID(group: String, torrent: Int) -> String { "\(group)#\(torrent)" }

    /// Plasma's `ListSectionHeader`: a small caption with a rule running to the
    /// right edge.
    private func sectionHeader(_ name: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(name) · \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var placeholder: some View {
        let message: String = {
            if let error = store.errorMessage { return error }
            if !store.connected { return "Connecting…" }
            if !store.searchText.isEmpty { return "No matching torrents" }
            return "No torrents"
        }()
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(store.connected ? store.footerSummary : (store.errorMessage ?? "Disconnected"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            footerButton("arrow.clockwise", help: "Refresh now") { store.poll() }
            footerButton("chart.bar", help: "Statistics") { actions.showStats() }
            footerButton("globe", help: "Open web interface") { store.openWebInterface() }
            settingsMenu
        }
        .focusEffectDisabled()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Shared sizing so the footer glyphs read as one control group.
    private static let footerIconFont = Font.system(size: 13, weight: .regular)

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Self.footerIconFont)
                .padding(2)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Start all") { store.startAll() }
            Button("Pause all") { store.stopAll() }
            Divider()
            Button("Options…") { actions.showOptions() }
            Divider()
            Button("Quit") { actions.quit() }
        } label: {
            Image(systemName: "gearshape")
                .font(Self.footerIconFont)
                .padding(2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and actions")
    }
}
#endif
