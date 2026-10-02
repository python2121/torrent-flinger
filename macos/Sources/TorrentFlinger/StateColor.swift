#if os(macOS)
import AppKit
import SwiftUI
import TorrentFlingerCore

/// The app's one color/glyph vocabulary for torrent state — the macOS
/// counterpart of `linux/flinger/ui/style.py`.
///
/// The two semantic accents keep the Linux build's Breeze palette (so a
/// screenshot of either app reads the same), while everything neutral comes
/// from macOS's dynamic system colors so light/dark and the user's accent
/// color are honored automatically.
enum StateColor {
    /// Breeze "positive" — seeding / complete.
    static let positive = Color(nsColor: NSColor(srgbRed: 0.153, green: 0.682, blue: 0.376, alpha: 1))
    /// Breeze "negative" — errors and destructive actions.
    static let negative = Color(nsColor: NSColor(srgbRed: 0.855, green: 0.267, blue: 0.325, alpha: 1))

    static func color(for state: Torrent.State) -> Color {
        switch state {
        case .seeding, .complete: return positive
        case .error: return negative
        case .paused: return Color.secondary.opacity(0.65)
        case .verifying, .queued: return Color.secondary
        case .downloading, .magnetizing: return Color.accentColor
        }
    }

    /// SF Symbol shown in the row's state badge.
    static func symbol(for state: Torrent.State) -> String {
        switch state {
        case .downloading: return "arrow.down"
        case .seeding: return "arrow.up"
        case .paused: return "pause.fill"
        case .complete: return "checkmark"
        case .verifying: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .magnetizing: return "link"
        case .error: return "exclamationmark"
        }
    }
}

/// The state badge: a tinted circle with the state glyph, sized like the
/// Linux row's 32px status icon.
struct StateBadge: View {
    let state: Torrent.State
    var size: CGFloat = 26

    var body: some View {
        let tint = StateColor.color(for: state)
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            Image(systemName: StateColor.symbol(for: state))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// The slim state-colored progress bar under each row's subtitle. Same
/// geometry as the Linux build (4pt tall, 19%-alpha track), drawn in a Canvas
/// so it costs one draw call per row on a 3-second refresh.
struct ProgressGauge: View {
    /// 0–1, clamped on render.
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let radius = height / 2
            let track = CGRect(x: 0, y: 0, width: size.width, height: height)
            context.fill(Path(roundedRect: track, cornerRadius: radius),
                         with: .color(color.opacity(0.19)))
            let done = min(max(fraction, 0), 1)
            if done > 0 {
                let fill = CGRect(x: 0, y: 0, width: size.width * done, height: height)
                context.fill(Path(roundedRect: fill, cornerRadius: radius), with: .color(color))
            }
        }
        .frame(height: height)
    }
}
#endif
