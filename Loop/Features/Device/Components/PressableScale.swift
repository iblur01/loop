import SwiftUI
import UIKit

/// Gesture-driven press feedback: the view shrinks under the finger and fires a light haptic on the
/// down edge — something `ButtonStyle.isPressed` can't do. Lift-inside-to-fire, like a real button.
/// `.simultaneousGesture` so rows inside a ScrollView still scroll.
struct PressableScale: ViewModifier {
    var pressedScale: CGFloat = 0.97
    let action: () -> Void

    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { value in
                        isPressed = false
                        if abs(value.translation.width) < 20, abs(value.translation.height) < 20 {
                            action()
                        }
                    }
            )
    }
}

extension View {
    func pressable(scale: CGFloat = 0.97, action: @escaping () -> Void) -> some View {
        modifier(PressableScale(pressedScale: scale, action: action))
    }
}
