import SwiftUI

// MARK: - Shimmer

/// Soft 120Hz GPU-accelerated specular sweep used on "thinking" labels while streaming.
struct Shimmer: ViewModifier {
    var active: Bool
    var duration: Double = 1.6
    @State private var sweeping = false

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.75), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .visualEffect { view, proxy in
                        view.offset(x: sweeping ? proxy.size.width : -proxy.size.width)
                    }
                    .allowsHitTesting(false)
                }
                .mask { content }
                .blendMode(.plusLighter)
                .onAppear {
                    sweeping = false
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        sweeping = true
                    }
                }
                .onDisappear {
                    sweeping = false
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

/// Live 120Hz breathing dot for background streaming sessions.
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(pulsing ? 0.0 : 0.42))
                .frame(width: size, height: size)
                .scaleEffect(pulsing ? 2.5 : 1.0)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(width: size * 2.8, height: size * 2.8)
        .onAppear {
            pulsing = false
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .onDisappear {
            pulsing = false
        }
        .accessibilityLabel("正在运行")
    }
}

// MARK: - Typing indicator

struct TypingDots: View {
    var color: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(animating ? 0.95 : 0.32))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.12 : 0.78)
                    .animation(
                        .easeInOut(duration: 0.52)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
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
                .symbolEffect(.breathe, options: .repeating, isActive: isRunning)
        }
        .frame(width: size, height: size)
        .shadow(color: style.glow.opacity(0.35), radius: size * 0.25, y: size * 0.1)
    }
}

// MARK: - Ambient background (GPU MeshGradient)

/// Obsidian / porcelain canvas with a GPU-accelerated `MeshGradient` ambient glow.
struct AmbientBackground: View {
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base = scheme == .dark ? Color(hex: 0x0A0A0E) : Color(hex: 0xF5F3EF)
        let primaryGlow: Color
        let secondaryGlow: Color
        let softGlow: Color

        if let tint {
            primaryGlow = tint.opacity(scheme == .dark ? 0.26 : 0.15)
            secondaryGlow = tint.opacity(scheme == .dark ? 0.13 : 0.08)
            softGlow = tint.opacity(scheme == .dark ? 0.08 : 0.05)
        } else {
            let subtle = scheme == .dark ? Color(hex: 0x6E73F0).opacity(0.08) : Color(hex: 0x6E73F0).opacity(0.045)
            primaryGlow = subtle
            secondaryGlow = subtle.opacity(0.6)
            softGlow = base
        }

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.42], [0.45, 0.38], [1.0, 0.32],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                primaryGlow, softGlow, base,
                base, base, secondaryGlow,
                base, base, base,
            ],
            smoothsColors: true
        )
        .background(base)
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
