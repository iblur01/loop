import SwiftUI

/// Shared sober surface: native Liquid Glass, no tints, no gradients, no per-state colour. The one
/// card treatment for the redesigned screens (Today widgets, rings hero). Depth comes from the glass
/// refraction, not paint — matching the project's monochrome design taste.
///
/// ```
/// content.loopGlass()
/// ```
struct LoopGlass: ViewModifier {
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func loopGlass(cornerRadius: CGFloat = 26) -> some View {
        modifier(LoopGlass(cornerRadius: cornerRadius))
    }
}
