#if os(macOS)
import AppKit
import SwiftUI
import TorrentFlingerCore

/// One torrent in the popover list — a port of `linux/flinger/ui/torrent_row.py`'s
/// `ExpandableListItem`: a compact header (state badge, name, `↓/↑ speed · % ·
/// ETA` subtitle, slim state-colored progress bar, primary action, chevron)
/// that expands in place into quick actions plus a details grid.
struct TorrentRowView: View {
    @ObservedObject var store: TorrentStore
    let torrent: Torrent
    var actions = PopoverActions()

    @ViewState private var hovering = false

    private var isSelected: Bool { store.selectedIDs.contains(torrent.id) }
    private var isExpanded: Bool { store.expandedIDs.contains(torrent.id) }
    private var tint: Color { StateColor.color(for: torrent.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { expandedBody }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            // Breeze view-item alphas: hover 0.30, selected 0.80, both 1.0.
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(highlightAlpha))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Modifier-qualified taps must win over the plain one, so they're
        // registered at high priority; an unmodified click falls through.
        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded {
            store.select(id: torrent.id, modifiers: .shift)
        })
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded {
            store.select(id: torrent.id, modifiers: .command)
        })
        .onTapGesture { store.select(id: torrent.id, modifiers: []) }
        .contextMenu { contextMenu }
        .animation(.easeInOut(duration: 0.1), value: isExpanded)
    }

    private var highlightAlpha: Double {
        if isSelected { return hovering ? 0.45 : 0.32 }
        return hovering ? 0.14 : 0
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            StateBadge(state: torrent.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(torrent.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(torrent.name)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressGauge(fraction: torrent.displayFraction, color: tint)
            }
            // Tighter than the row's 8pt rhythm, because the chevron's target
            // is 30 wide around a 10pt glyph: the whitespace is already inside
            // it, and spending another 8 here would take the width out of the
            // torrent name instead.
            HStack(spacing: 2) {
                primaryAction
                chevron
            }
        }
    }

    /// `↓ 1.2 MB/s · ↑ 300 KB/s · 42% · 3m 10s`, collapsing to the error string
    /// when the torrent is in trouble, and to size + ratio once complete.
    private var subtitle: String {
        if !torrent.errorString.isEmpty { return torrent.errorString }
        var parts: [String] = []
        if torrent.rateDownload > 0 { parts.append("↓ \(Format.speed(torrent.rateDownload))") }
        if torrent.rateUpload > 0 { parts.append("↑ \(Format.speed(torrent.rateUpload))") }
        let fraction = torrent.displayFraction
        if torrent.state == .magnetizing {
            parts.append("fetching metadata")
        } else if fraction < 1 {
            parts.append(String(format: "%.0f%%", fraction * 100))
            let eta = Format.eta(torrent.eta)
            if !eta.isEmpty, torrent.state == .downloading { parts.append(eta) }
        } else {
            parts.append(Format.size(torrent.totalSize))
            parts.append(String(format: "ratio %.2f", max(torrent.uploadRatio, 0)))
        }
        return parts.isEmpty ? Format.statusName(torrent.status) : parts.joined(separator: " · ")
    }

    /// Remove (red) once complete, Resume (green) while paused and incomplete,
    /// Pause (plain) while active — the Linux row's three-state button.
    @ViewBuilder
    private var primaryAction: some View {
        if torrent.isComplete {
            // No confirmation here: the ✕ only appears on a completed torrent,
            // where removing is cheap and reversible enough not to be worth a
            // dialog. The expanded-row and context-menu entries (both spelled
            // with an ellipsis) still confirm, and are the way to delete the
            // data along with the torrent.
            outlineButton(symbol: "xmark", color: StateColor.negative, help: "Remove torrent") {
                store.remove([torrent.id], deleteData: false)
            }
        } else if torrent.isPaused {
            outlineButton(title: "Resume", color: StateColor.positive) {
                store.start([torrent.id])
            }
        } else {
            outlineButton(title: "Pause", color: nil) {
                store.stop([torrent.id])
            }
        }
    }

    private func outlineButton(title: String? = nil, symbol: String? = nil,
                               color: Color?, help: String = "",
                               action: @escaping () -> Void) -> some View {
        let stroke = color ?? Color.secondary
        return Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                } else {
                    Text(title ?? "").font(.system(size: 11))
                }
            }
            .foregroundStyle(stroke)
            .frame(minWidth: symbol == nil ? 44 : 20, minHeight: 18)
            .padding(.horizontal, symbol == nil ? 4 : 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(stroke.opacity(0.75), lineWidth: 1)
            )
            // Without this the hit region is the glyph alone — the border is a
            // stroke and the box inside it is empty, so clicks just short of
            // the ✕ or the label did nothing and the button felt unreliable.
            .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The glyph stays 10pt; the *target* around it is deliberately much
    /// bigger. It used to be an 18pt box around that 10pt glyph — four points
    /// of margin on a side — and a miss doesn't do nothing, it lands on the row
    /// and *selects*, so aiming at it was fiddly in a way that read as the app
    /// misbehaving rather than as a small button.
    ///
    /// Nothing is drawn here, so the target can be as generous as the layout
    /// allows: the full row height, which the badge and text stack set anyway,
    /// and 30 across, paid for out of the gap beside the primary action rather
    /// than out of the torrent name.
    private var chevron: some View {
        Button {
            store.toggleExpanded(torrent.id)
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Show details")
    }

    // MARK: Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            rowAction("Details…") { actions.showDetails(torrent.id) }
            rowAction("Copy magnet link") { store.copyMagnets(for: [torrent.id]) }
            if store.canReveal(torrent.id) {
                rowAction("Reveal in Finder") { store.revealInFinder(torrent.id) }
            }
            rowAction("Remove torrent…") { confirmRemove([torrent.id]) }
            Divider().padding(.vertical, 4)
            detailGrid
        }
        .padding(.leading, 34)
        .padding(.trailing, 6)
        .padding(.top, 6)
    }

    private func rowAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Six quick stats in two columns of three, same keys and order as the
    /// Linux row's grid.
    private var detailGrid: some View {
        let pairs: [(String, String)] = [
            ("Status", Format.statusName(torrent.status)),
            ("Size", Format.size(torrent.sizeWhenDone > 0 ? torrent.sizeWhenDone : torrent.totalSize)),
            ("Ratio", String(format: "%.2f", max(torrent.uploadRatio, 0))),
            ("Peers", "\(torrent.peersConnected)"),
            ("ETA", Format.eta(torrent.eta).isEmpty ? "—" : Format.eta(torrent.eta)),
            ("Location", torrent.downloadDir),
        ]
        return HStack(alignment: .top, spacing: 12) {
            detailColumn(Array(pairs[0..<3]))
            detailColumn(Array(pairs[3..<6]))
        }
        .padding(.horizontal, 6)
    }

    private func detailColumn(_ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pairs, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Text(value)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Context menu

    /// Acts on the whole selection when this row is part of it, otherwise on
    /// this row alone. Computed without mutating the selection, so building the
    /// menu never writes state mid-update.
    private var targets: [Int] {
        store.selectedIDs.contains(torrent.id) ? store.selectedInVisualOrder : [torrent.id]
    }

    /// Only the entries that can act on this selection: Resume when something
    /// in it is stopped, Pause when something in it is running. Verify,
    /// reannounce and copy magnet are the details window's business.
    @ViewBuilder
    private var contextMenu: some View {
        let ids = targets
        let suffix = ids.count == 1 ? "" : " (\(ids.count))"
        let selected = ids.compactMap { store.torrent(id: $0) }
        if selected.contains(where: { $0.isPaused }) {
            Button("Resume\(suffix)") { store.start(ids) }
        }
        if selected.contains(where: { !$0.isPaused }) {
            Button("Pause\(suffix)") { store.stop(ids) }
        }
        if ids.count == 1 {
            Divider()
            if store.canReveal(ids[0]) {
                Button("Reveal in Finder") { store.revealInFinder(ids[0]) }
            }
            Button("Torrent files…") { actions.showFiles(ids[0]) }
            Button("Details…") { actions.showDetails(ids[0]) }
        }
        Divider()
        Button("Remove\(suffix)…") { confirmRemove(ids) }
    }

    private func confirmRemove(_ ids: [Int]) {
        let names = ids.compactMap { store.torrent(id: $0)?.name }
        guard let deleteData = Dialogs.confirmRemove(what: Dialogs.describe(names)) else { return }
        store.remove(ids, deleteData: deleteData)
    }
}
#endif
