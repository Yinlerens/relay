import SwiftUI

// MARK: - Liquid Glass with graceful fallback

/// iOS 26 Liquid Glass (`.glassEffect`) when built with Xcode 26 / Swift 6.2 and running on iOS 26,
/// otherwise a refined `.ultraThinMaterial` surface with a specular hairline rim.
struct GlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool = false
    var tint: Color? = nil
    var shadow: Bool = true

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(makeGlass(), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
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
    #endif

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.10))
                    }
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.06), Color.white.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
            .shadow(color: .black.opacity(shadow ? 0.16 : 0), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, tint: tint, shadow: shadow))
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

/// Groups glass elements so they morph/blend together on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
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

    /// Sheet background: Liquid Glass sheets on iOS 26, soft material on earlier systems.
    @ViewBuilder
    func relaySheetBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.presentationBackground(.regularMaterial)
        }
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
