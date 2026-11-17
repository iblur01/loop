import SwiftUI

/// The driver figures, grouped into one glass surface — not three coloured cards. Each
/// row: the metric, its measured value, the 30-day delta, and a band-coloured sub-score
/// bar. Monochrome except the bar (the card's one accent). Calibrating rows show "--".
struct RecoveryFactsGroup: View {
    let model: RecoveryCoachModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.metrics.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().overlay(.secondary.opacity(0.12)).padding(.leading, 16)
                }
                RecoveryFactRow(row: row)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .deviceSurface()
    }
}

private struct RecoveryFactRow: View {
    let row: RecoveryMetricRow

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(row.valueText)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.hasScore ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

                if row.delta != nil {
                    HStack(spacing: 2) {
                        Image(systemName: row.deltaDirection.systemImage)
                            .font(.system(size: 9, weight: .semibold))
                        Text(row.deltaText)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                }
            }

            HStack(spacing: 10) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(row.band.color)
                            .frame(width: proxy.size.width * CGFloat(appeared ? row.subScoreFraction : 0))
                            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
                    }
                }
                .frame(height: 6)

                Text(row.subScoreText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.hasScore ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { appeared = true }
    }
}

#Preview {
    RecoveryFactsGroup(model: .preview(score: 72))
        .padding()
        .background(Color(.systemGroupedBackground))
}
