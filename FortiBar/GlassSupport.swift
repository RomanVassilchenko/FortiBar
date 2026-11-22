import SwiftUI

// Liquid Glass (macOS 26) with a material fallback for macOS 15.
// Glass is kept for the control layer (buttons, the status puck), never stacked on glass.

extension View {
    /// Liquid Glass in `shape`, or a thin material before macOS 26.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint?.opacity(0.3)).interactive(interactive), in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
                .overlay { if let tint { shape.fill(tint.opacity(0.15)) } }
        }
    }

    /// Glass button style, a bordered button before macOS 26.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Lets neighbouring glass shapes blend and share one rendering pass on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
