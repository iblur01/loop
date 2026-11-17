import SwiftUI

/// Ligne d'objectif de 56 pt : icône, titre, valeur courante, chevron. Ouvre la page d'édition de l'objectif.
struct ProfileValueRow: View {
    let icon: String
    let category: SettingsCategory
    let title: String
    let value: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: ProfileRowMetrics.iconSpacing) {
                SettingsIconTile(symbol: icon, category: category)
                Text(title)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(LoopType.footnote.weight(.semibold))
                    .foregroundStyle(LoopColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
            .frame(minHeight: ProfileRowMetrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ProfileValueRow(icon: "alarm", category: .wake, title: "Réveil cible", value: "7:00", onOpen: {})
        .padding(16)
}
