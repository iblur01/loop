import SwiftUI

/// Difficulté d'effort : curseur inversé Facile / Difficile. Au relâchement, la valeur est
/// persistée dans le cache durable et relance le recalcul complet.
struct EffortDifficultyView: View {
    @ObservedObject var repository: LoopDataRepository
    @ObservedObject var prefs: UserPreferences

    /// Le curseur est INVERSÉ par rapport au multiplicateur stocké : à gauche « Facile »
    /// (multiplicateur haut, le strain monte vite), à droite « Difficile » (multiplicateur bas).
    private var sliderValue: Binding<Double> {
        Binding(
            get: { UserPreferences.minDifficulty + UserPreferences.maxDifficulty - prefs.strainDifficulty },
            set: { prefs.strainDifficulty = UserPreferences.minDifficulty + UserPreferences.maxDifficulty - $0 }
        )
    }

    private var disabled: Bool { repository.localMetricsEngine == nil }

    var body: some View {
        ProfileGoalPage(title: NSLocalizedString("profile.goal.effort", tableName: "Base", comment: ""),
                        subtitle: NSLocalizedString("profile.effort.subtitle", tableName: "Base", comment: "")) {
            ProfileGoalValueRow(title: NSLocalizedString("profile.goal.effort", tableName: "Base", comment: ""),
                                value: prefs.strainDifficultyLabel)
            ProfileHairline(inset: ProfileRowMetrics.horizontalPadding)
            Slider(
                value: sliderValue,
                in: UserPreferences.minDifficulty...UserPreferences.maxDifficulty,
                step: 0.05,
                label: { Text(NSLocalizedString("Difficulté du strain", tableName: "Base", comment: "")) },
                minimumValueLabel: { caption(NSLocalizedString("Facile", tableName: "Base", comment: "")) },
                maximumValueLabel: { caption(NSLocalizedString("Difficile", tableName: "Base", comment: "")) },
                onEditingChanged: { editing in
                    guard !editing else { return }
                    repository.applyStrainDifficulty(prefs.strainDifficulty)
                }
            )
            .disabled(disabled)
            .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
            .frame(minHeight: ProfileRowMetrics.height)
        }
        .opacity(disabled ? 0.5 : 1)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(LoopType.footnote)
            .foregroundStyle(LoopColor.textSecondary)
    }
}

#Preview {
    NavigationStack { EffortDifficultyView(repository: LoopDataRepository(), prefs: .shared) }
}
