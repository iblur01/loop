import SwiftUI

/// Texte de l'objectif de sommeil : « 8 h » ou « 8 h 15 ».
enum GoalFormat {
    static func sleepText(minutes: Double) -> String {
        let total = Int(minutes)
        let h = total / 60
        let m = total % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m)"
    }
}

/// Squelette des trois pages d'objectif : titre propre, sous-texte d'une ligne, une seule carte
/// opaque qui porte le contrôle.
struct ProfileGoalPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(subtitle)
                    .font(LoopType.footnote)
                    .foregroundStyle(LoopColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
                ProfileGroup(content: content)
            }
            .padding(.horizontal, LoopMeasure.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LoopColor.bgBase)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ligne titre + valeur courante de 56 pt au sommet des cartes d'objectif.
struct ProfileGoalValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(LoopType.body.weight(.semibold))
                .foregroundStyle(LoopColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        .frame(minHeight: ProfileRowMetrics.height)
        .accessibilityElement(children: .combine)
    }
}
