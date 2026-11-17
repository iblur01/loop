import SwiftUI

/// Secondary facts, grouped into one glass surface — not N cards. Each row is a label
/// and a monospaced ink value; the three sleep stages add an optional share bar. No
/// per-row colour. Missing values render as a tertiary em dash.
struct SleepFactsGroup: View {
    let model: SleepCoachModel

    var body: some View {
        VStack(spacing: 0) {
            row("Profond", model.deepText, fraction: model.deepFraction)
            divider
            row("REM", model.remText, fraction: model.remFraction)
            divider
            row(TodayL.text("today.final.sleep.light"), model.lightText, fraction: model.lightFraction)
            divider
            row("Éveil", model.awakeText)
            divider
            row(TodayL.text("today.final.sleep.efficiency"), model.efficiencyText)
            divider
            row(TodayL.text("today.remaining.hr.rest"), model.restingHrText)
            divider
            row("HRV", model.avgHrvText)
            divider
            row("Latence", model.latencyText)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .deviceSurface()
    }

    private var divider: some View {
        Divider().overlay(.secondary.opacity(0.12)).padding(.leading, 16)
    }

    private func row(_ label: String, _ value: String, fraction: Double? = nil) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }

            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(model.band.color)
                            .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    SleepFactsGroup(model: SleepCoachModel(metric: .sleepPreview(score: 78)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
