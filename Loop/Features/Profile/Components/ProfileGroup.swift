import SwiftUI

/// Métriques de ligne partagées par Profil, Réglages et les pages d'objectifs : une seule source
/// pour la hauteur, la marge latérale et l'espace icône/texte.
enum ProfileRowMetrics {
    static let height: CGFloat = 56
    static let horizontalPadding: CGFloat = 16
    static let iconSpacing: CGFloat = 12
    static let iconSize: CGFloat = 24
}

/// Titre de section en overline puis son contenu, pour tous les écrans de la famille Profil.
struct ProfileSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(LoopType.overline)
                    .foregroundStyle(LoopColor.textSecondary)
                    .padding(.leading, ProfileRowMetrics.horizontalPadding)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
    }
}

/// Carte opaque qui empile des lignes de 56 pt. `hairlineInset` aligne les séparateurs sur le texte.
struct ProfileGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .loopCard(.card)
    }
}

/// Séparateur de 1 pt dans un groupe.
struct ProfileHairline: View {
    var inset: CGFloat = 52

    var body: some View {
        Rectangle()
            .fill(LoopColor.strokeCard)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// Note de pied de section, alignée sur le texte des lignes.
struct ProfileFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LoopType.footnote)
            .foregroundStyle(LoopColor.textSecondary)
            .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
