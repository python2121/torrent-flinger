import SwiftUI
import TorrentFlingerCore

/// One torrent in the list: state badge, name, `↓/↑ speed · % · ETA`
/// subtitle (the error string when in trouble, size + ratio once complete)
/// and the slim progress bar — the Mac row without the inline controls,
/// which on a phone live in swipe actions and the detail screen.
struct TorrentRowView: View {
    let torrent: Torrent

    private var tint: Color { StateColor.color(for: torrent.state) }

    var body: some View {
        HStack(spacing: 12) {
            StateBadge(state: torrent.state)
            VStack(alignment: .leading, spacing: 4) {
                // Shortened from the end but keeping the file extension —
                // `Reacher.S04E05.1080p…mkv` on the last line. See the label
                // for why this is UIKit rather than `Text`.
                TruncatedNameLabel(name: torrent.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(torrent.state == .error ? StateColor.negative : Color.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                ProgressGauge(fraction: torrent.displayFraction, color: tint)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 3)
    }

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
}
