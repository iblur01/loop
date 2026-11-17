import SwiftUI

/// Ligne de navigation de 56 pt dans un groupe : icône, titre, sous-titre, chevron. Pas de surface
/// propre, le groupe porte la carte.
struct ProfileNavRow: View {
    let icon: String
    let category: SettingsCategory
    let title: String
    var subtitle: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: ProfileRowMetrics.iconSpacing) {
                SettingsIconTile(symbol: icon, category: category)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(LoopType.body)
                        .foregroundStyle(LoopColor.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(LoopType.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
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
    }
}

#Preview {
    ProfileNavRow(icon: "externaldrive", category: .data, title: "Sauvegarde", subtitle: "Exporter ou restaurer", onOpen: {})
        .padding(16)
}
