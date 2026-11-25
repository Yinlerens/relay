import SwiftUI

// MARK: - Native iOS 26 Liquid Glass

/// Native iOS 26 Liquid Glass surface modifier.
struct GlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content.glassEffect(makeGlass(), in: shape)
    }

    private func makeGlass() -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint.opacity(0.35))
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, tint: tint))
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        glassSurface(Capsule(style: .continuous), interactive: interactive, tint: tint)
    }

    func glassCircle(interactive: Bool = true, tint: Color? = nil) -> some View {
        glassSurface(Circle(), interactive: interactive, tint: tint)
    }

    func glassRounded(_ radius: CGFloat, interactive: Bool = false, tint: Color? = nil) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive, tint: tint)
    }
}

/// Groups glass elements inside a native `GlassEffectContainer` so they morph & blend smoothly on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

// MARK: - Card surface (non-glass, editorial)

struct CardSurface: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 0.6)
            )
    }
}

extension View {
    func cardSurface(radius: CGFloat = 22) -> some View {
        modifier(CardSurface(radius: radius))
    }
}

// MARK: - Press style

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
