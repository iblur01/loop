import SwiftUI

/// Carte corporelle : arc de FC max en tête, puis âge, taille et poids. Toute la carte ouvre l'édition
/// en feuille. Pas de source affichée sous les valeurs.
struct BodyProfileCard: View {
    @ObservedObject var prefs: UserPreferences
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 8) {
                    BodyMetricColumn(label: NSLocalizedString("profile.body.age", tableName: "Base", comment: ""),
                                     value: ageText)
                    BodyMetricColumn(label: NSLocalizedString("profile.body.height", tableName: "Base", comment: ""),
                                     value: heightValue)
                    BodyMetricColumn(label: NSLocalizedString("profile.body.weight", tableName: "Base", comment: ""),
                                     value: weightValue)
                }
            }
            .padding(LoopMeasure.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .loopCard(.card)
        .accessibilityHint(NSLocalizedString("profile.body.hint", tableName: "Base", comment: ""))
    }

    // MARK: - Valeurs

    private var ageText: String {
        guard let age = prefs.effectiveAge else { return "—" }
        return String(format: NSLocalizedString("profile.body.age.value", tableName: "Base", comment: ""), age)
    }

    private var heightValue: String {
        guard let cm = prefs.heightCm else { return "—" }
        return BodyProfileFormatting.heightText(cm: cm, units: prefs.unitSystem)
    }

    private var weightValue: String {
        guard let kg = prefs.weightKg else { return "—" }
        return BodyProfileFormatting.weightText(kg: kg, units: prefs.unitSystem)
    }
}

/// Une colonne de la carte corporelle : libellé en footnote, valeur en rôle tuile.
private struct BodyMetricColumn: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(LoopType.footnote)
                .foregroundStyle(LoopColor.textSecondary)
            Text(value)
                .font(LoopType.tileValue)
                .foregroundStyle(LoopColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    BodyProfileCard(prefs: .shared, onEdit: {})
        .padding(16)
}
