import SwiftUI

/// « Pourquoi ce niveau », replié par défaut. Replié : la position par rapport à la cible en une
/// ligne. Déplié : le récit qui relie effort, cible et récupération, et la méthode de calcul.
struct StrainWhyDisclosure: View {
    let model: StrainCoachModel

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.whyNarrative)
                        .font(LoopType.body)
                        .foregroundStyle(LoopColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.explanation)
                        .font(LoopType.label)
                        .foregroundStyle(LoopColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .loopCard(.nested, cornerRadius: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Metric.strain.tint)
                    .accessibilityHidden(true)
                Text("today.pourquoi.ce.niveau", tableName: "Today")
                    .font(LoopType.cardTitle)
                    .foregroundStyle(LoopColor.textPrimary)
                Spacer(minLength: 8)
                if !isExpanded {
                    Text(model.dominantSummary)
                        .font(LoopType.footnote)
                        .foregroundStyle(LoopColor.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LoopColor.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: LoopMeasure.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? TodayL.text("today.final.detail.expanded") : model.dominantSummary)
        .accessibilityHint(isExpanded ? "Masque l'explication" : "Affiche l'explication")
    }
}

#Preview {
    StrainWhyDisclosure(model: .preview(strain: 18.0))
        .padding()
        .appBackground()
}
