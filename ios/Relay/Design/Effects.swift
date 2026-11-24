import SwiftUI

// MARK: - Shimmer

/// Soft specular sweep used on "thinking" labels while streaming.
struct Shimmer: ViewModifier {
    var active: Bool
    var duration: Double = 1.8

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: duration) / duration)
                        GeometryReader { geo in
                            let width = max(geo.size.width, 1)
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.75), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width * 0.55)
                            .offset(x: -width * 0.55 + phase * width * 1.55)
                        }
                    }
                    .mask { content }
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

// MARK: - Pulse dot

/// Live "breathing" dot for background streaming sessions.
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
            ZStack {
                Circle()
                    .fill(color.opacity(0.35 * (1 - phase)))
                    .frame(width: size, height: size)
                    .scaleEffect(1 + phase * 1.6)
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.7), radius: 4)
            }
        }
        .frame(width: size * 2.8, height: size * 2.8)
        .accessibilityLabel("正在运行")
    }
}

// MARK: - Typing indicator

struct TypingDots: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let p = (sin((t * 5.2) - Double(i) * 0.75) + 1) / 2
                    Circle()
                        .fill(color.opacity(0.35 + 0.65 * p))
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.8 + 0.3 * p)
                }
            }
        }
        .accessibilityLabel("正在生成")
    }
}

// MARK: - Agent glyph tile

struct AgentGlyph: View {
    var style: AgentStyle
    var size: CGFloat = 40
    var isRunning: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(style.gradient)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
        }
        .frame(width: size, height: size)
        .shadow(color: style.glow.opacity(0.35), radius: size * 0.25, y: size * 0.1)
    }
}

// MARK: - Ambient background

/// Obsidian / porcelain canvas with a subtle per-agent signature glow.
struct AmbientBackground: View {
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Palette.canvas
            if let tint {
                RadialGradient(
                    colors: [tint.opacity(scheme == .dark ? 0.22 : 0.12), .clear],
                    center: .init(x: 0.15, y: -0.05),
                    startRadius: 10,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [tint.opacity(scheme == .dark ? 0.10 : 0.06), .clear],
                    center: .init(x: 1.0, y: 0.25),
                    startRadius: 10,
                    endRadius: 380
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Context ring gauge

struct ContextRing: View {
    var fraction: Double
    var size: CGFloat = 28
    var lineWidth: CGFloat = 3

    private var color: Color {
        switch fraction {
        case ..<0.6: return Palette.success
        case ..<0.85: return Palette.warning
        default: return Palette.danger
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.hairlineStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))")
                .font(RelayFont.rounded(size * 0.32, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
    }
}

// MARK: - Section eyebrow

struct Eyebrow: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(RelayFont.eyebrow)
            .tracking(1.4)
            .foregroundStyle(Palette.textTertiary)
    }
}
