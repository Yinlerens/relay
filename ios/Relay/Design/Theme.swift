import SwiftUI
import UIKit

// MARK: - Color helpers

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor(hex: hex, alpha: CGFloat(alpha)))
    }

    /// Adaptive color: porcelain (light) / obsidian (dark).
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Palette

enum Palette {
    /// Page canvas: warm porcelain / deep obsidian.
    static let canvas = Color.adaptive(light: 0xF5F3EF, dark: 0x0A0A0E)
    static let canvasDeep = Color.adaptive(light: 0xEDEAE4, dark: 0x050507)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x15151B)
    static let surfaceRaised = Color.adaptive(light: 0xFBFAF8, dark: 0x1C1C24)
    static let hairline = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    static let hairlineStrong = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)
    static let textPrimary = Color.adaptive(light: 0x16161A, dark: 0xF2F1EE)
    static let textSecondary = Color.adaptive(light: 0x6B6A72, dark: 0x9C9CA8)
    static let textTertiary = Color.adaptive(light: 0x9E9DA5, dark: 0x6A6A76)
    static let fieldFill = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06)

    /// Code cards stay dark in both themes for an editorial, IDE-grade feel.
    static let codeBackground = Color(hex: 0x0E0F14)
    static let codeHeader = Color(hex: 0x16171E)
    static let codeText = Color(hex: 0xE6E6EA)
    static let codeBorder = Color.white.opacity(0.08)

    static let success = Color.adaptive(light: 0x1F9D6B, dark: 0x5FD8A0)
    static let warning = Color.adaptive(light: 0xC27C12, dark: 0xF3BE6E)
    static let danger = Color.adaptive(light: 0xD1393F, dark: 0xFF6B6E)
}

// MARK: - Typography

enum RelayFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let body = Font.system(size: 16.5, weight: .regular)
    static let caption = Font.system(size: 12, weight: .medium)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
}

// MARK: - Appearance

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "自动"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.stars.fill"
        case .light: return "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    var uiInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Applies the style at the window level so that already-presented sheets / popovers / full-screen covers
    /// switch immediately too (`.preferredColorScheme` does not reset an existing sheet's override).
    @MainActor
    func applyToWindows() {
        let style = uiInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

enum SettingsKey {
    static let appearance = "appearance"
    static let haptics = "hapticsEnabled"
}

// MARK: - Agent signature styling

struct AgentStyle: Equatable, Sendable {
    enum Family: String, Sendable {
        case indigo
        case emerald
        case amber
    }

    let family: Family
    let symbol: String

    var tint: Color {
        switch family {
        case .indigo: return .adaptive(light: 0x5458D8, dark: 0x9AA5FF)
        case .emerald: return .adaptive(light: 0x0E8A6E, dark: 0x5FD8B8)
        case .amber: return .adaptive(light: 0xB4721B, dark: 0xF3BE6E)
        }
    }

    /// Soft wash used for bubbles / glows.
    var wash: Color {
        switch family {
        case .indigo: return .adaptive(light: 0x5458D8, dark: 0x8E9BFF, lightAlpha: 0.10, darkAlpha: 0.16)
        case .emerald: return .adaptive(light: 0x0E8A6E, dark: 0x4FD1B0, lightAlpha: 0.10, darkAlpha: 0.15)
        case .amber: return .adaptive(light: 0xB4721B, dark: 0xF2B866, lightAlpha: 0.10, darkAlpha: 0.15)
        }
    }

    var glow: Color {
        switch family {
        case .indigo: return Color(hex: 0x6E73F0)
        case .emerald: return Color(hex: 0x14B8A6)
        case .amber: return Color(hex: 0xF2A93B)
        }
    }

    var gradient: LinearGradient {
        let colors: [Color]
        switch family {
        case .indigo: colors = [Color(hex: 0xA7B0FF), Color(hex: 0x5B5FE0), Color(hex: 0x3A3BA8)]
        case .emerald: colors = [Color(hex: 0x8FF0D6), Color(hex: 0x14A58A), Color(hex: 0x0B6B5A)]
        case .amber: colors = [Color(hex: 0xFFD99A), Color(hex: 0xE19A35), Color(hex: 0x9C5E12)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func resolve(agentId: String, agent: AgentInfo?) -> AgentStyle {
        let accent = (agent?.accent ?? "").lowercased()
        let identity = "\(agentId) \(agent?.name ?? "")".lowercased()

        let family: Family
        if ["indigo", "periwinkle", "violet", "purple", "blue", "iris"].contains(where: { accent.contains($0) }) {
            family = .indigo
        } else if ["emerald", "teal", "green", "mint", "jade"].contains(where: { accent.contains($0) }) {
            family = .emerald
        } else if ["amber", "orange", "gold", "yellow"].contains(where: { accent.contains($0) }) {
            family = .amber
        } else if identity.contains("antigravity") || identity.contains("agy") || identity.contains("gemini") {
            family = .indigo
        } else if identity.contains("codebuddy") || identity.contains("buddy") {
            family = .emerald
        } else {
            family = .amber
        }

        return AgentStyle(family: family, symbol: symbol(for: agent?.icon ?? "", family: family))
    }

    private static func symbol(for icon: String, family: Family) -> String {
        let mapped: [String: String] = [
            "sparkles": "sparkles",
            "sparkle": "sparkle",
            "cpu": "cpu",
            "bot": "cpu",
            "terminal": "terminal",
            "code": "chevron.left.forwardslash.chevron.right",
            "brain": "brain",
            "zap": "bolt.fill",
            "bolt": "bolt.fill",
            "star": "star.fill",
            "rocket": "paperplane.fill",
            "wand": "wand.and.stars",
        ]
        let key = icon.lowercased()
        if let symbol = mapped[key] { return symbol }
        if !icon.isEmpty, UIImage(systemName: icon) != nil { return icon }
        switch family {
        case .indigo: return "sparkles"
        case .emerald: return "cpu"
        case .amber: return "circle.hexagongrid.fill"
        }
    }
}

extension AppStore {
    func style(for agentId: String) -> AgentStyle {
        AgentStyle.resolve(agentId: agentId, agent: agent(for: agentId))
    }
}

// MARK: - Formatting

enum RelayFormat {
    /// Credits: `3.08`, `0.0042`, `12` — trims trailing zeros, keeps precision for tiny values.
    static func credits(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        let digits = magnitude < 0.01 ? 4 : (magnitude < 100 ? 2 : 1)
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    static func tokens(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(Int(value))
    }

    static func bytes(_ count: Int) -> String {
        bytes(Int64(count))
    }

    static func bytes(_ count: Int64) -> String {
        guard count > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month().day())
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}
