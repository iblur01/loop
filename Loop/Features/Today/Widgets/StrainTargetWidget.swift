import SwiftUI

/// Celebrates the day's effort once the strain target zone is reached — a "bravo" card.
/// It only appears at or above the zone floor (the gate lives in `TodayContext`), so it
/// never nags when the user is still short. Two nuances: inside the zone (objective hit)
/// vs above it (overshot). One colour, carried by the band/marker.
struct StrainTargetWidget: View {
    let metric: DailySnapshot?
    let strainTarget: Double

    @State private var appeared = false

    private var state: StrainTargetState { StrainTargetState.make(metric: metric, strainTarget: strainTarget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetLabel(symbol: "bolt.fill", title: TodayL.text("today.target.title"), trailing: TodayL.format("today.target.value", state.targetText), tint: state.color)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WidgetMetric(value: state.currentText)
                Text(state.kicker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.color)
            }

            bar

            Text(state.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .widgetSurface()
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true } }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))

                // Achieved effort, in the state colour.
                Capsule()
                    .fill(state.color)
                    .frame(width: w * CGFloat(appeared ? state.fillFraction : 0))

                // Zone bounds — the target window, marked by two ticks.
                tick(at: w * CGFloat(state.minFraction))
                tick(at: w * CGFloat(state.maxFraction))
            }
        }
        .frame(height: 6)
    }

    private func tick(at x: CGFloat) -> some View {
        Rectangle()
            .fill(.primary.opacity(0.3))
            .frame(width: 1.5, height: 10)
            .offset(x: x - 0.75)
    }
}

// MARK: - State

/// Pure value logic for the strain-target card — derives a min/max zone around the
/// day's target (the snapshot carries only a single `targetStrain`) and the celebratory
/// copy. `shouldShow` is the gate the Today context reads.
struct StrainTargetState {
    /// `true` once current strain reaches the zone floor — the card stays hidden below it.
    let shouldShow: Bool
    let exceeded: Bool
    let currentText: String
    let targetText: String
    let kicker: String
    let title: String
    let message: String
    let color: Color
    /// Bar fractions on a fixed 0…21 WHOOP strain scale.
    let fillFraction: Double
    let minFraction: Double
    let maxFraction: Double

    private static let scale: Double = 21

    static func make(metric: DailySnapshot?, strainTarget: Double) -> StrainTargetState {
        let hidden = StrainTargetState(
            shouldShow: false, exceeded: false, currentText: "—", targetText: "—",
            kicker: "", title: "", message: "", color: .secondary,
            fillFraction: 0, minFraction: 0, maxFraction: 0
        )

        guard let metric, let current = metric.strain, current.isFinite, !metric.isExpress else { return hidden }

        let target = metric.targetStrain ?? strainTarget
        let spread = max(1.5, target * 0.12)
        let minV = max(0, target - spread)
        let maxV = min(scale, target + spread)

        guard current >= minV else { return hidden }

        let exceeded = current > maxV
        let currentText = String(format: "%.1f", current)
        let targetText = String(format: "%.1f", target)
        let zoneText = "\(String(format: "%.1f", minV))–\(String(format: "%.1f", maxV))"

        let kicker = exceeded ? TodayL.text("today.target.exceeded") : TodayL.text("today.target.reached")
        let title = exceeded ? TodayL.text("today.target.above") : TodayL.text("today.target.hit")
        let t = AdviceTense.of(day: metric.date)
        let message = exceeded
            ? t.pick(TodayL.format("today.target.exceeded.message", currentText, zoneText),
                     past: TodayL.format("today.target.exceeded.past", currentText, zoneText))
            : t.pick(TodayL.format("today.target.reached.message", currentText, zoneText),
                     past: TodayL.format("today.target.reached.past", currentText, zoneText))
        let color = exceeded ? Pop.orange : Pop.green

        return StrainTargetState(
            shouldShow: true,
            exceeded: exceeded,
            currentText: currentText,
            targetText: targetText,
            kicker: kicker,
            title: title,
            message: message,
            color: color,
            fillFraction: min(max(current / scale, 0), 1),
            minFraction: minV / scale,
            maxFraction: maxV / scale
        )
    }
}

#Preview("Atteint") {
    StrainTargetWidget(metric: .strainPreview(strain: 14.0, target: 14.0), strainTarget: 15.5)
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Dépassé") {
    StrainTargetWidget(metric: .strainPreview(strain: 18.5, target: 14.0), strainTarget: 15.5)
        .padding()
        .background(Color(.systemGroupedBackground))
}
