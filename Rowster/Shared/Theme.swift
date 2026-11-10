import AppKit
import RowsterCore
import SwiftUI

/// Rowster's visual theme, in the family of Mopster's: native structure, a soft polychrome ground and
/// gradient tints. Every color adapts to dark mode.
enum Theme {
    /// Window ground: lavender → mint → peach in light mode, night → deep teal → plum in dark mode.
    static let ground = LinearGradient(
        colors: [
            .dynamic(light: Color(hex: 0xEEF2FF), dark: Color(hex: 0x10152A)),
            .dynamic(light: Color(hex: 0xF2FBF9), dark: Color(hex: 0x0C1D21)),
            .dynamic(light: Color(hex: 0xFFF4EC), dark: Color(hex: 0x1D1519)),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Primary action: indigo → teal, the colors of the app icon.
    static let action = LinearGradient(
        colors: [Color(hex: 0x5B4DDB), Color(hex: 0x10A8B3)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let actionShadow = Color(hex: 0x5B4DDB)

    static let cardFill = Color.dynamic(light: .white.opacity(0.78), dark: .white.opacity(0.06))
    static let cardStroke = Color.dynamic(light: .white.opacity(0.9), dark: .white.opacity(0.1))
    static let cardShadow = Color.dynamic(light: Color(hex: 0x1F2937).opacity(0.06), dark: .black.opacity(0.3))
    static let cardRadius: CGFloat = 14

    static let softFill = Color.dynamic(light: .white.opacity(0.8), dark: .white.opacity(0.08))
    static let softStroke = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.14), dark: .white.opacity(0.16))

    /// Pending changes in the grid.
    static let modified = Color(hex: 0xF59E0B)
    static let inserted = Color(hex: 0x22C55E)
    static let deleted = Color(hex: 0xEF4444)
}

/// One gradient per engine.
struct EngineTint: Hashable {
    let start: Color
    let end: Color
    let monogram: String

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Engine {
    var tint: EngineTint {
        switch self {
        case .postgres: return EngineTint(start: Color(hex: 0x60A5FA), end: Color(hex: 0x2563EB), monogram: "Pg")
        case .mysql: return EngineTint(start: Color(hex: 0xFBBF24), end: Color(hex: 0xF97316), monogram: "My")
        case .mariadb: return EngineTint(start: Color(hex: 0xD6A77A), end: Color(hex: 0x9A5B2E), monogram: "Ma")
        case .sqlite: return EngineTint(start: Color(hex: 0x2DD4BF), end: Color(hex: 0x0D9488), monogram: "Sq")
        }
    }
}

extension ConnectionColor {
    var color: Color {
        switch self {
        case .gray: return Color(hex: 0x8E8E93)
        case .blue: return Color(hex: 0x3B82F6)
        case .teal: return Color(hex: 0x14B8A6)
        case .green: return Color(hex: 0x22C55E)
        case .yellow: return Color(hex: 0xEAB308)
        case .orange: return Color(hex: 0xF97316)
        case .red: return Color(hex: 0xEF4444)
        case .pink: return Color(hex: 0xEC4899)
        case .purple: return Color(hex: 0x8B5CF6)
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .gray: return "Gray"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .red: return "Red"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }
}

extension EnvironmentLabel {
    var title: LocalizedStringKey {
        switch self {
        case .none: return "No label"
        case .local: return "Local"
        case .development: return "Development"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }
}

// MARK: - Small components

/// A rounded gradient square holding the engine's monogram.
struct EngineIcon: View {
    let engine: Engine
    var size: CGFloat = 28

    var body: some View {
        Text(verbatim: engine.tint.monogram)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(engine.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(Text(verbatim: engine.displayName))
    }
}

/// The environment of a connection: a colored capsule with its name. Production adds a lock, so that
/// color is never the only signal.
struct EnvironmentBadge: View {
    let label: EnvironmentLabel
    let color: ConnectionColor
    var prominent = false

    var body: some View {
        if label != .none {
            HStack(spacing: 3) {
                if label == .production { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
                Text(label.title).textCase(.uppercase)
            }
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? .white : color.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(prominent ? color.color : color.color.opacity(0.16), in: Capsule())
            .fixedSize()
        }
    }
}

/// Translucent card with a soft shadow.
struct ThemeCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .background { shape.fill(Theme.cardFill).shadow(color: Theme.cardShadow, radius: 12, y: 6) }
            .overlay(shape.strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func themeCard() -> some View { modifier(ThemeCard()) }
}

// MARK: - Buttons

/// Filled gradient button for the one primary action of a screen. `.controlSize(.small)` makes it compact.
struct GradientButtonStyle: ButtonStyle {
    var fill: LinearGradient = Theme.action
    var shadow: Color = Theme.actionShadow

    func makeBody(configuration: Configuration) -> some View {
        GradientButton(configuration: configuration, fill: fill, shadow: shadow)
    }
}

private struct GradientButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration
    let fill: LinearGradient
    let shadow: Color

    var body: some View {
        let compact = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 16)
            .frame(height: compact ? 26 : 32)
            .background(fill, in: shape)
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .shadow(color: shadow.opacity(isEnabled ? 0.25 : 0), radius: 6, y: 3)
            .contentShape(shape)
    }
}

/// Secondary button: translucent, bordered.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration)
    }
}

private struct SoftButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let compact = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 16)
            .frame(height: compact ? 26 : 32)
            .background(Theme.softFill, in: shape)
            .overlay(shape.strokeBorder(Theme.softStroke))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var gradient: GradientButtonStyle { GradientButtonStyle() }
    static func gradient(_ color: Color) -> GradientButtonStyle {
        GradientButtonStyle(
            fill: LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .top, endPoint: .bottom), shadow: color)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// A color that follows the window's appearance.
    static func dynamic(light: Color, dark: Color) -> Color {
        let light = NSColor(light)
        let dark = NSColor(dark)
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}
