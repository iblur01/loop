import SwiftUI

/// The one foregrounded metric: sleep duration. A label, the big figure, and a
/// WHOOP-style bar — monochrome ink track + fill, with a thin "objectif" tick. The
/// fill only turns warning-orange when the deficit is genuinely large (> 45 min).
struct SleepDurationCard: View {
    let model: SleepCoachModel

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetLabel(symbol: "clock.fill", title: String(localized: "today.duree", table: "Today"), trailing: "objectif \(model.sleepNeedText)", tint: model.band.color)

            WidgetMetric(value: model.sleepDurationText)

            bar

            Text(model.durationCaptionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.durationWarning ? AnyShapeStyle(Pop.orange) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true } }
    }

    private var fillStyle: AnyShapeStyle {
        model.durationWarning ? AnyShapeStyle(Pop.orange) : AnyShapeStyle(model.band.color)
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.08))

                Capsule()
                    .fill(fillStyle)
                    // The track represents up to 1.5× target, so normalise the fill
                    // fraction into that same span before drawing.
                    .frame(width: width * (appeared ? min(model.durationFraction / 1.5, 1) : 0))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: model.durationFraction)

                // "objectif" tick = 100% of target, on a track that spans 1.5× target.
                Rectangle()
                    .fill(.primary.opacity(0.3))
                    .frame(width: 1.5, height: 12)
                    .offset(x: width * (1.0 / 1.5) - 0.75)
            }
        }
        .frame(height: 12)
    }
}

#Preview("Sous l'objectif") {
    SleepDurationCard(model: SleepCoachModel(metric: .sleepPreview(score: 62, totalSleepMin: 408)))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Sur l'objectif") {
    SleepDurationCard(model: SleepCoachModel(metric: .sleepPreview(score: 88, totalSleepMin: 500)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
