import SwiftUI

/// The page's one and only surface treatment: native Liquid Glass. No tints, no gradients, no
/// per-state colours — depth comes from the glass refraction, not from paint.
///
/// Used as a background:
/// ```
/// content.deviceSurface()
/// ```
struct DeviceSurface: ViewModifier {
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func deviceSurface(cornerRadius: CGFloat = 26) -> some View {
        modifier(DeviceSurface(cornerRadius: cornerRadius))
    }
}
