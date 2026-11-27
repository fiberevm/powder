import SwiftUI

enum PowderPalette {
    // Dark values follow Studio's Dark Modern theme (VS Code's palette).
    /// The accent. Gold now; the name is from the earlier blue theme.
    static let scopeBlue = Term.accent
    static let signalGreen = Color(dark: 0x0DBC79, light: 0x098658)
    static let cautionAmber = Color(dark: 0xCCA700, light: 0x9A7400)
    static let riskCoral = Color(dark: 0xF14C4C, light: 0xCD3131)
    /// Text on a filled accent, green, red or amber label: dark on the bright dark-theme fills,
    /// white on the deeper light-theme ones. Also the dark workspace background.
    static let graphite = Color(dark: 0x1F1F1F, light: 0xFFFFFF)
    static let raisedGraphite = Color(hex: 0x262626)
    static let porcelain = Color(red: 0.957, green: 0.953, blue: 0.933)
    static let porcelainRaised = Color(red: 0.988, green: 0.984, blue: 0.969)
    static let porcelainInspector = Color(red: 0.898, green: 0.894, blue: 0.871)

    static func workspace(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? graphite : porcelain
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? raisedGraphite : porcelainRaised
    }

    static func inspector(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? raisedGraphite : porcelainInspector
    }

    static func market(_ value: Double) -> Color {
        value >= 0 ? signalGreen : riskCoral
    }

    static func risk(_ level: RiskLevel) -> Color {
        switch level {
        case .clear: signalGreen
        case .watch: cautionAmber
        case .elevated: riskCoral
        }
    }
}

struct MonospacedValue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var color: Color = .primary
    var weight: Font.Weight = .medium
    var animatesChanges = true

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced, weight: weight))
            .foregroundStyle(color)
            .contentTransition(animatesChanges ? .numericText() : .identity)
            .animation(
                animatesChanges && !reduceMotion
                    ? .easeOut(duration: 0.22)
                    : nil,
                value: text
            )
    }
}

struct TokenMark: View {
    let token: TokenSnapshot
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let imageURL = token.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        ZStack {
            PowderPalette.scopeBlue.opacity(0.18)
            Text(String(token.symbol.prefix(2)))
                .font(.system(size: size * 0.31, weight: .semibold, design: .rounded))
                .foregroundStyle(PowderPalette.scopeBlue)
        }
    }
}

struct DataModeBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: DataMode

    var body: some View {
        Label(mode.label, systemImage: mode.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(mode == .live ? PowderPalette.signalGreen : PowderPalette.cautionAmber)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (mode == .live ? PowderPalette.signalGreen : PowderPalette.cautionAmber)
                    .opacity(0.12),
                in: Capsule()
            )
            .accessibilityLabel(mode == .live ? "Live data from Codex" : "Demonstration data")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: mode)
    }
}

struct RealtimeStatusBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: RealtimeConnectionState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .contentTransition(.numericText())
            .accessibilityLabel(accessibilityLabel)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state)
    }

    private var color: Color {
        switch state {
        case .live:
            PowderPalette.signalGreen
        case .connecting, .reconnecting:
            PowderPalette.cautionAmber
        case .demo:
            PowderPalette.cautionAmber
        case .unavailable:
            Color.secondary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .demo:
            "Demonstration stream"
        case .connecting:
            "Connecting to Codex subscriptions"
        case .live:
            "Codex subscriptions streaming"
        case let .reconnecting(attempt):
            "Reconnecting to Codex subscriptions, attempt \(attempt)"
        case .unavailable:
            "Codex snapshot only, subscriptions unavailable"
        }
    }
}

enum PowderFormat {
    static func currency(_ value: Double, precise: Bool = false) -> String {
        if value == 0 { return "$0" }
        if value >= 1_000_000_000 {
            return String(format: "$%.2fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "$%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "$%.1fK", value / 1_000)
        }
        if value >= 1 {
            return String(format: "$%.2f", value)
        }

        let decimals = precise ? 8 : (value < 0.001 ? 7 : 5)
        return "$" + String(format: "%.\(decimals)f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        let number = value * 100
        return String(format: signed ? "%+.1f%%" : "%.1f%%", number)
    }

    static func wholePercent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return value.formatted()
    }

    static func age(since date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
