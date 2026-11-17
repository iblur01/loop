import SwiftUI

/// The foregrounded view: where today's score sits on the 0–100 recovery scale. A
/// monochrome track, a band-coloured fill up to the score, ticks at the band bounds
/// (34 / 67), and the zone labels — so you read not just the number but how far you are
/// from the next band. Delta vs yesterday in the caption.
struct RecoveryGaugeCard: View {
    let model: RecoveryCoachModel

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetLabel(symbol: "gauge.with.dots.needle.67percent", title: "Niveau", trailing: model.deltaVsYesterdayText, tint: model.band.color)

            bar

            HStack {
                zoneLabel("Basse")
                Spacer()
                zoneLabel(TodayL.text("today.final.recovery.moderate"))
                Spacer()
                zoneLabel("Haute")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true } }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))

                Capsule()
                    .fill(model.band.color)
                    .frame(width: w * CGFloat(appeared ? model.scoreFraction : 0))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: model.scoreFraction)

                ForEach(model.bandTickFractions, id: \.self) { f in
                    Rectangle()
                        .fill(.primary.opacity(0.25))
                        .frame(width: 1.5, height: 12)
                        .offset(x: w * CGFloat(f) - 0.75)
                }
            }
        }
        .frame(height: 8)
    }

    private func zoneLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    VStack(spacing: 16) {
        RecoveryGaugeCard(model: .preview(score: 85))
        RecoveryGaugeCard(model: .preview(score: 45))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
