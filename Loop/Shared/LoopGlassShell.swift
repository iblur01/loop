import SwiftUI

/// Capsule badge shell used by status pills and metric sub-score badges. Mirrors the previous
/// `DeviceCardBadgeShell` / `StatusBadgeShell` / `CoachBadgeShell` private duplicates.
struct LoopBadgeShell: View {
    @Environment(\.colorScheme) private var colorScheme

    let accent: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.12))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1)
            }
    }
}
