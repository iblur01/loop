import SwiftUI

/// Catégories de réglages : une teinte par catégorie, tirée des teintes d'anneau existantes.
/// Le seul accent « actif » de l'écran reste le vert des interrupteurs.
enum SettingsCategory {
    case wake, effort, display, data

    var tint: Color {
        switch self {
        case .wake:    return Metric.sleep.tint
        case .effort:  return Metric.strain.tint
        case .display: return Metric.strain.tint
        case .data:    return Color(.systemGray)
        }
    }
}

enum SettingsMetrics {
    static let tileSize: CGFloat = 28
    /// Séparateur aligné sur le texte : marge + tuile + espace (même logique que Profil).
    static let hairlineInset: CGFloat = ProfileRowMetrics.horizontalPadding + tileSize + ProfileRowMetrics.iconSpacing
}

/// Tuile d'icône Réglages iOS : 28 pt, rayon 8, glyphe blanc de même taille partout.
struct SettingsIconTile: View {
    let symbol: String
    let category: SettingsCategory

    var body: some View {
        Image(systemName: symbol)
            .font(LoopType.label)
            .foregroundStyle(.white)
            .frame(width: SettingsMetrics.tileSize, height: SettingsMetrics.tileSize)
            .background(category.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Ligne de Réglages de 56 pt, mêmes marges que `ProfileNavRow` : tuile, titre, contrôle ou valeur à
/// droite. La carte (`ProfileGroup`) porte la surface.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let category: SettingsCategory
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: ProfileRowMetrics.iconSpacing) {
            SettingsIconTile(symbol: symbol, category: category)
            Text(title)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        .frame(minHeight: ProfileRowMetrics.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Valeur secondaire optionnelle suivie d'un chevron, pour les lignes qui ouvrent quelque chose.
struct SettingsDisclosure: View {
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            if let value {
                Text(value)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(LoopType.footnote.weight(.semibold))
                .foregroundStyle(LoopColor.textTertiary)
                .accessibilityHidden(true)
        }
    }
}
