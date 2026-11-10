import AppKit
import RowsterCore
import SwiftUI

/// Rowster's visual theme, "Nebula": an indigo → raspberry → amber gradient, frosted-glass surfaces on a ground
/// lit by soft glows, and monospaced data. Every color adapts to dark mode.
enum Theme {
    // MARK: - Signature

    static let indigo = Color(hex: 0x5B3FE6)
    static let raspberry = Color(hex: 0xC42A73)
    static let amber = Color(hex: 0xF59E42)

    /// Primary action: the signature gradient, ending on a deeper orange so that white text stays readable.
    static let action = LinearGradient(
        colors: [indigo, raspberry, Color(hex: 0xC2410C)], startPoint: .leading, endPoint: .trailing)
    static let actionShadow = raspberry

    /// The app name, written in the gradient.
    static let wordmark = LinearGradient(
        colors: [
            .dynamic(light: Color(hex: 0x3A27B8), dark: .white),
            .dynamic(light: Color(hex: 0xA31F5E), dark: Color(hex: 0xFF9CC8)),
            .dynamic(light: Color(hex: 0xB2470B), dark: Color(hex: 0xFFC48A)),
        ],
        startPoint: .leading, endPoint: .trailing)

    // MARK: - Ground and surfaces

    static let base = Color.dynamic(light: Color(hex: 0xF7F6FC), dark: Color(hex: 0x0C0B16))
    static let glowIndigo = Color.dynamic(light: indigo.opacity(0.18), dark: indigo.opacity(0.40))
    static let glowRaspberry = Color.dynamic(light: raspberry.opacity(0.13), dark: raspberry.opacity(0.30))
    static let glowAmber = Color.dynamic(light: amber.opacity(0.13), dark: amber.opacity(0.10))

    static let cardFill = Color.dynamic(light: .white.opacity(0.85), dark: Color(hex: 0x15131F).opacity(0.85))
    static let cardStroke = Color.dynamic(light: .white.opacity(0.95), dark: .white.opacity(0.08))
    static let cardShadow = Color.dynamic(light: Color(hex: 0x28185A).opacity(0.10), dark: .black.opacity(0.45))
    static let cardRadius: CGFloat = 16

    static let softFill = Color.dynamic(light: .white.opacity(0.75), dark: .white.opacity(0.06))
    static let softStroke = Color.dynamic(light: Color(hex: 0x17142A).opacity(0.12), dark: .white.opacity(0.14))

    // MARK: - AppKit colors

    /// Colors of the data grid. Computed, so that no `NSColor` is shared between threads.
    enum Grid {
        static var background: NSColor { .dynamic(light: .white, dark: NSColor(hex: 0x15131F)) }
        static var line: NSColor { .dynamic(light: NSColor(hex: 0xEEEBF7), dark: NSColor(hex: 0xFFFFFF, alpha: 0.07)) }
        static var modified: NSColor {
            .dynamic(light: NSColor(hex: 0xFFE7C2), dark: NSColor(hex: 0xF59E42, alpha: 0.24))
        }
        static var inserted: NSColor {
            .dynamic(light: NSColor(hex: 0xD8F6EF), dark: NSColor(hex: 0x2BB9A6, alpha: 0.22))
        }
        static var deleted: NSColor {
            .dynamic(light: NSColor(hex: 0xFDE2EA), dark: NSColor(hex: 0xE0457B, alpha: 0.24))
        }
        static var deletedText: NSColor { .dynamic(light: NSColor(hex: 0xA3123F), dark: NSColor(hex: 0xFF8FB0)) }
        static var focus: NSColor { .dynamic(light: NSColor(hex: 0x5B3FE6), dark: NSColor(hex: 0x9D8CFF)) }
    }

    /// Syntax colors of the SQL editor.
    enum Code {
        static var keyword: NSColor { .dynamic(light: NSColor(hex: 0x5B3FE6), dark: NSColor(hex: 0x9D8CFF)) }
        static var string: NSColor { .dynamic(light: NSColor(hex: 0xB2470B), dark: NSColor(hex: 0xFFB86B)) }
        static var number: NSColor { .dynamic(light: NSColor(hex: 0x0F766E), dark: NSColor(hex: 0x5EE6D0)) }
        static var quotedIdentifier: NSColor {
            .dynamic(light: NSColor(hex: 0xC42A73), dark: NSColor(hex: 0xFF7AB6))
        }
        static var parameter: NSColor { .dynamic(light: NSColor(hex: 0x3B5BDB), dark: NSColor(hex: 0x8FB0FF)) }
        static var currentStatement: NSColor {
            .dynamic(light: NSColor(hex: 0x5B3FE6, alpha: 0.08), dark: NSColor(hex: 0x9D8CFF, alpha: 0.14))
        }
    }
}

/// The window ground: the base color lit by three soft glows, indigo, raspberry and amber.
struct ThemeGround: View {
    var body: some View {
        ZStack {
            Theme.base
            RadialGradient(
                colors: [Theme.glowIndigo, .clear], center: .topLeading, startRadius: 0, endRadius: 560)
            RadialGradient(
                colors: [Theme.glowRaspberry, .clear], center: UnitPoint(x: 0.25, y: 1), startRadius: 0, endRadius: 480)
            RadialGradient(
                colors: [Theme.glowAmber, .clear], center: .bottomTrailing, startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
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
        case .postgres: return EngineTint(start: Color(hex: 0x6C8CFF), end: Color(hex: 0x3B5BDB), monogram: "Pg")
        case .mysql: return EngineTint(start: Color(hex: 0xF59E42), end: Color(hex: 0xC2410C), monogram: "My")
        case .mariadb: return EngineTint(start: Color(hex: 0xC08457), end: Color(hex: 0x8A5530), monogram: "Ma")
        case .sqlite: return EngineTint(start: Color(hex: 0x2BB9A6), end: Color(hex: 0x0F766E), monogram: "Sq")
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

    /// Fill of a prominent badge: two deep shades that keep white text readable.
    var badgeGradient: LinearGradient {
        let shades: (UInt32, UInt32)
        switch self {
        case .gray: shades = (0x6B7280, 0x4B5563)
        case .blue: shades = (0x3B6FE0, 0x2A4FC4)
        case .teal: shades = (0x0E7C74, 0x0B605A)
        case .green: shades = (0x0F7A55, 0x0B5E41)
        case .yellow: shades = (0xA16207, 0x854D0E)
        case .orange: shades = (0xC2410C, 0x9A3412)
        case .red: shades = (0xC81E4A, 0x8E1538)
        case .pink: shades = (0xC0267A, 0x9D174D)
        case .purple: shades = (0x6D3FE6, 0x5520C8)
        }
        return LinearGradient(
            colors: [Color(hex: shades.0), Color(hex: shades.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Text in this color on a light wash of it: deep in light mode, light in dark mode.
    var ink: Color {
        switch self {
        case .gray: return .dynamic(light: Color(hex: 0x4B5563), dark: Color(hex: 0xC3C8D0))
        case .blue: return .dynamic(light: Color(hex: 0x2A4FC4), dark: Color(hex: 0x9CB8FF))
        case .teal: return .dynamic(light: Color(hex: 0x0B605A), dark: Color(hex: 0x5EE6D0))
        case .green: return .dynamic(light: Color(hex: 0x0B5E41), dark: Color(hex: 0x6FE3A8))
        case .yellow: return .dynamic(light: Color(hex: 0x854D0E), dark: Color(hex: 0xF5CC4A))
        case .orange: return .dynamic(light: Color(hex: 0x9A3412), dark: Color(hex: 0xFFB86B))
        case .red: return .dynamic(light: Color(hex: 0x8E1538), dark: Color(hex: 0xFF8FB0))
        case .pink: return .dynamic(light: Color(hex: 0x9D174D), dark: Color(hex: 0xFF8FCB))
        case .purple: return .dynamic(light: Color(hex: 0x5520C8), dark: Color(hex: 0xC3B2FF))
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
            .background(engine.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .shadow(color: engine.tint.end.opacity(0.30), radius: size * 0.14, y: size * 0.07)
            .accessibilityLabel(Text(verbatim: engine.displayName))
    }
}

/// The environment of a connection: a gradient capsule with its name. Production adds a lock, so that
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
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(prominent ? Color.white : color.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                if prominent {
                    Capsule().fill(color.badgeGradient).shadow(color: color.color.opacity(0.35), radius: 4, y: 2)
                } else {
                    Capsule().fill(
                        LinearGradient(
                            colors: [color.color.opacity(0.18), color.color.opacity(0.07)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .fixedSize()
        }
    }
}

/// Frosted-glass card with a soft shadow.
struct ThemeCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .background { shape.fill(Theme.cardFill).shadow(color: Theme.cardShadow, radius: 20, y: 10) }
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
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 26 : 32)
            .background(fill, in: shape)
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .shadow(color: shadow.opacity(isEnabled ? 0.32 : 0), radius: 8, y: 4)
            .contentShape(shape)
    }
}

/// Secondary button: frosted, bordered.
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
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
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
        Color(nsColor: .dynamic(light: NSColor(light), dark: NSColor(dark)))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color that follows the appearance it is drawn in.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
