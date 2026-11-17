import SwiftUI

/// Recovery answered in two seconds. No card — the hero floats on the page's grouped
/// background. Overline, very large ink score, then the page's one accent: the quality
/// word in band colour, with the advice line under it.
struct RecoveryHero: View {
    let model: RecoveryCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("today.recuperation.7c5c7c", tableName: "Today")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)

            score

            Text(model.qualityLabel)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.band.color)
                .symbolEffect(.pulse, isActive: model.band.isLow)

            Text(model.headline)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var score: some View {
        if let value = model.scoreInt {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 78, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        } else {
            Text("—")
                .font(.system(size: 78, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

#Preview("Haute") {
    RecoveryHero(model: .preview(score: 85))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Basse") {
    RecoveryHero(model: .preview(score: 28))
        .padding()
        .background(Color(.systemGroupedBackground))
}
