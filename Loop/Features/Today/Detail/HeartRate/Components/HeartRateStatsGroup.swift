import SwiftUI

/// The range's key figures, grouped into one glass surface — not five tiles. Resting is
/// foregrounded (it's the reference everything else is read against); average, min, max and
/// amplitude follow. Monochrome; "—" when a figure isn't available.
struct HeartRateStatsGroup: View {
    let model: HeartRateCoachModel

    private var rows: [(label: String, value: String, hint: String?)] {
        [
            ("Repos", model.restingBpm.map { "\($0)" } ?? "—", TodayL.text("today.final.heart.rate.reference")),
            ("Moyenne", model.avgBpm.map { "\($0)" } ?? "—", nil),
            ("Minimum", model.minBpm.map { "\($0)" } ?? "—", nil),
            ("Maximum", model.maxBpm.map { "\($0)" } ?? "—", nil),
            ("Amplitude", model.amplitudeBpm.map { "\($0)" } ?? "—", "max − min")
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().overlay(.secondary.opacity(0.12)).padding(.leading, 16)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let hint = row.hint {
                        Text(hint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(row.value)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(row.value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        Text("bpm")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .deviceSurface()
    }
}

#Preview {
    HeartRateStatsGroup(model: .preview())
        .padding()
        .background(Color(.systemGroupedBackground))
}
