import SwiftUI

/// Ligne d'action de 56 pt dans un `ProfileGroup` : tuile d'icône, titre, sous-titre optionnel et
/// contrôle à droite optionnel (chevron pour les liens). Sert aux sous-pages Sauvegarde, Santé et Avancé.
struct ProfileActionRow<Trailing: View>: View {
    let icon: String
    var category: SettingsCategory = .data
    let title: String
    var subtitle: String? = nil
    var isDestructive = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: ProfileRowMetrics.iconSpacing) {
            SettingsIconTile(symbol: icon, category: category)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(LoopType.body)
                    .foregroundStyle(isDestructive ? Color(.systemRed) : LoopColor.textPrimary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(LoopType.footnote)
                        .foregroundStyle(LoopColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        .padding(.vertical, 8)
        .frame(minHeight: ProfileRowMetrics.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension ProfileActionRow where Trailing == EmptyView {
    init(icon: String, category: SettingsCategory = .data, title: String, subtitle: String? = nil, isDestructive: Bool = false) {
        self.init(icon: icon, category: category, title: title, subtitle: subtitle, isDestructive: isDestructive) { EmptyView() }
    }
}

/// Ligne d'état sans icône de catégorie : message court avec glyphe d'état (succès, erreur).
struct ProfileStatusRow: View {
    let text: String
    let symbol: String
    var isError = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ProfileRowMetrics.iconSpacing) {
            Image(systemName: symbol)
                .font(LoopType.label)
                .foregroundStyle(isError ? Color(.systemRed) : Color(.systemGreen))
                .frame(width: SettingsMetrics.tileSize)
                .accessibilityHidden(true)
            Text(text)
                .font(LoopType.footnote)
                .foregroundStyle(isError ? Color(.systemRed) : LoopColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Ligne de progression : indicateur et libellé.
struct ProfileProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: ProfileRowMetrics.iconSpacing) {
            ProgressView()
                .frame(width: SettingsMetrics.tileSize, height: SettingsMetrics.tileSize)
            Text(text)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        .frame(minHeight: ProfileRowMetrics.height)
        .accessibilityElement(children: .combine)
    }
}

/// Chevron de lien, identique à celui de `ProfileNavRow`.
struct ProfileChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(LoopType.footnote.weight(.semibold))
            .foregroundStyle(LoopColor.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Défilement commun des sous-pages : fond `bgBase`, gouttière d'écran, sections empilées.
struct ProfileSubpage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoopMeasure.sectionSpacing) {
                content()
            }
            .padding(.horizontal, LoopMeasure.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LoopColor.bgBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
