import SwiftUI
import TorrentFlingerCore
import UIKit

/// The app's colour/glyph vocabulary for torrent state — the same Breeze
/// accents the Linux and Mac builds use, so all three read alike.
enum StateColor {
    /// Breeze "positive" — seeding / complete.
    static let positive = Color(red: 0.153, green: 0.682, blue: 0.376)
    /// Breeze "negative" — errors and destructive actions.
    static let negative = Color(red: 0.855, green: 0.267, blue: 0.325)

    static func color(for state: Torrent.State) -> Color {
        switch state {
        case .seeding, .complete: return positive
        case .error: return negative
        case .paused: return Color.secondary.opacity(0.65)
        case .verifying, .queued: return Color.secondary
        case .downloading, .magnetizing: return Color.accentColor
        }
    }

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

/// A tinted circle with the state glyph.
struct StateBadge: View {
    let state: Torrent.State
    var size: CGFloat = 34

    var body: some View {
        let tint = StateColor.color(for: state)
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            Image(systemName: StateColor.symbol(for: state))
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(state.rawValue))
    }
}

/// The slim state-coloured progress bar under a row's subtitle.
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

/// Transient banner at the top of the screen.
struct ToastView: View {
    let toast: PhoneStore.Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? StateColor.negative : StateColor.positive)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.subheadline.weight(.semibold))
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 16)
    }
}

/// A key/value row that wraps long values (hashes, paths) instead of
/// truncating them the way `LabeledContent` does.
struct DetailRow: View {
    let key: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// A torrent name shortened from the end but keeping its file extension —
/// `Reacher.S04E05.1080p…mkv` on the last line.
///
/// A `UILabel` rather than `Text`, deliberately: SwiftUI's truncation can't
/// keep a suffix, so the shortening is done by `Format.truncateName` against
/// a measurement, and the measurement has to come from the same text engine
/// that draws the result. `Text` breaks long unspaced release names in its
/// own places (it hyphenates mid-word), so a string measured with UIKit to
/// fit two lines came out three lines in SwiftUI and lost the extension to
/// a second ellipsis. UIKit measuring for UIKit drawing agrees with itself.
struct TruncatedNameLabel: UIViewRepresentable {
    let name: String
    var lines = 2

    static let font = UIFontMetrics(forTextStyle: .subheadline)
        .scaledFont(for: .systemFont(ofSize: 15, weight: .medium))

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.font = Self.font
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = lines
        label.lineBreakMode = .byTruncatingTail   // a hard bound, never expected to trigger
        label.textColor = .label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.numberOfLines = lines
        if label.preferredMaxLayoutWidth > 0 {
            label.text = truncated(name, width: label.preferredMaxLayoutWidth, font: label.font)
        } else {
            label.text = name
        }
    }

    /// The layout pass is where the width is known, so the shortening is
    /// (re)computed here and the label's own layout sized to the result.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            label.text = name
            return label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        }
        label.preferredMaxLayoutWidth = width
        label.text = truncated(name, width: width, font: label.font)
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    private func truncated(_ name: String, width: CGFloat, font: UIFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let box = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let maxHeight = font.lineHeight * CGFloat(lines) + 0.5
        return Format.truncateName(name) { text in
            (text as NSString).boundingRect(with: box,
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: attributes, context: nil).height <= maxHeight
        }
    }
}
