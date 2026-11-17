import SwiftUI

/// Heart rate answered at a glance. No card — floats on the grouped background. Overline,
/// the large ink bpm, the contextual state in the page's one accent (red), and a plain-language
/// line tying the number to the resting baseline.
struct HeartRateHero: View {
    let model: HeartRateCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("today.frequence.cardiaque.17a33c", tableName: "Today")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.latestBpm.map { "\($0)" } ?? "—")
                    .font(.system(size: 78, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                Text("bpm")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.contextLabel)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.accent)
                if !model.latestTimeText.isEmpty {
                    Text("· \(model.latestTimeText)")
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
    HeartRateHero(model: .preview())
        .padding()
        .background(Color(.systemGroupedBackground))
}
