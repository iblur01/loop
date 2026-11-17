import SwiftUI

/// The night, answered in two seconds. No card — the hero floats on the page's
/// native grouped background. One overline, a very large ink score, then the page's
/// one accent: the quality label carries the band colour (green/yellow/red), and the
/// advice line sits right under it.
struct SleepHero: View {
    let model: SleepCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("today.sommeil.5946ab", tableName: "Today")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)

            Text("\(model.score)")
                .font(.system(size: 78, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)

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
}

#Preview("Bon") {
    SleepHero(model: SleepCoachModel(metric: .sleepPreview(score: 78)))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Bas") {
    SleepHero(model: SleepCoachModel(metric: .sleepPreview(score: 48)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
