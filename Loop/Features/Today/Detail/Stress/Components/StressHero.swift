import SwiftUI

/// Stress answered at a glance. No card — floats on the grouped background. Overline, the large
/// ink score on the 0–3 scale, the band word in the page's one accent, and a plain-language line.
struct StressHero: View {
    let model: StressCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("today.stress.du.jour", tableName: "Today")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.scoreText)
                    .font(.system(size: 78, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                Text("/ 3")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Text(model.qualityLabel)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.accent)
                if !model.latestTimeText.isEmpty {
                    Text("· dernier \(model.latestTimeText)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

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

#Preview {
    StressHero(model: .preview(score: 1.6))
        .padding()
        .background(Color(.systemGroupedBackground))
}
