import SwiftUI
import Charts

/// Courbe de FC pendant la séance, avec la FC moyenne de la séance en repère. Ne rend rien
/// sans série mesurée (au moins deux points).
struct WorkoutHeartRateCurve: View {
    let profile: WorkoutHeartRateProfile?
    let averageBpm: Double?

    var body: some View {
        if let profile, profile.hasCurve {
            content(profile.samples.filter { $0.bpm.isFinite && $0.bpm > 0 })
        }
    }

    private func content(_ points: [WorkoutHeartRateProfile.Point]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("today.frequence.cardiaque", tableName: "Today")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Chart {
                ForEach(points, id: \.ts) { point in
                    LineMark(
                        x: .value("Heure", Date(timeIntervalSince1970: Double(point.ts))),
                        y: .value("FC", point.bpm)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Metric.cardio.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if let averageBpm, averageBpm.isFinite, averageBpm > 0 {
                    RuleMark(y: .value("Moyenne", averageBpm))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("moy. \(Int(averageBpm.rounded()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 180)
            .accessibilityLabel(Text("today.courbe.de.frequence.cardiaque", tableName: "Today"))
            .accessibilityValue(summary(points))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private func summary(_ points: [WorkoutHeartRateProfile.Point]) -> String {
        let bpm = points.map(\.bpm)
        guard let lo = bpm.min(), let hi = bpm.max() else { return "" }
        return TodayL.format("today.final.heart.range", String(Int(lo.rounded())), String(Int(hi.rounded())))
    }
}
