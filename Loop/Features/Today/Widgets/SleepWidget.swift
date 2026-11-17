import SwiftUI

/// Sleep widget. Collapsed: duration + score + a thin stage bar. Expanded: stage breakdown,
/// efficiency, disturbances, bed/wake times, and a link to the full sleep detail.
struct SleepWidget: View {
    let metric: DailySnapshot

    var body: some View {
        ExpandableCard(symbol: "bed.double.fill", title: String(localized: "today.sommeil", table: "Today"), trailing: scoreText) {
            summary
        } detail: {
            detail
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WidgetMetric(value: durationText)
                if let target = targetText {
                    Text(target).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            if let s = stages { stageBar(s) }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let m = metric.deepMin { WidgetDetailRow("Sommeil profond", minutesText(m)) }
            if let m = metric.remMin  { WidgetDetailRow("Paradoxal (REM)", minutesText(m)) }
            if let m = metric.lightMin { WidgetDetailRow(TodayL.text("today.sleep.light"), minutesText(m)) }
            if let e = normalized(metric.efficiency) { WidgetDetailRow(TodayL.text("today.sleep.efficiency"), "\(Int(e.rounded())) %") }
            if let d = metric.disturbances { WidgetDetailRow("Perturbations", "\(d)") }
            if let bed = timeText(metric.sleepStart), let wake = timeText(metric.sleepEnd) {
                WidgetDetailRow(TodayL.text("today.sleep.bed.wake"), "\(bed) → \(wake)")
            }
            WidgetDetailLink(title: String(localized: "today.voir.le.detail.du.sommeil", table: "Today"), value: MetricType.sleep)
                .padding(.top, 2)
        }
    }

    // MARK: - Stage bar

    // Sleep-stage palette: deep indigo → light cyan. The bar is this card's one touch of colour.
    private static let deepColor  = Pop.indigo
    private static let remColor   = Pop.blue
    private static let lightColor = Pop.cyan

    private func stageBar(_ f: (deep: Double, rem: Double, light: Double)) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                seg(geo.size.width * f.deep, Self.deepColor)
                seg(geo.size.width * f.rem, Self.remColor)
                seg(geo.size.width * f.light, Self.lightColor)
            }
        }
        .frame(height: 6)
    }

    private func seg(_ w: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: max(0, w))
    }

    // MARK: - Derived

    private var durationText: String {
        guard let min = metric.totalSleepMin, min > 0 else { return "—" }
        let h = Int(min) / 60, m = Int(min) % 60
        return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
    }

    private var scoreText: String? {
        guard let s = normalized(metric.sleepScore) ?? normalized(metric.efficiency) else { return nil }
        return "\(Int(s.rounded())) %"
    }

    private var targetText: String? {
        guard let target = metric.sleepTargetMin, target > 0 else { return nil }
        let h = Int(target) / 60, m = Int(target) % 60
        let t = m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
        return "/ \(t)"
    }

    private var stages: (deep: Double, rem: Double, light: Double)? {
        guard let deep = metric.deepMin, let rem = metric.remMin, let light = metric.lightMin else { return nil }
        let total = deep + rem + light
        guard total > 0 else { return nil }
        return (deep / total, rem / total, light / total)
    }

    private func minutesText(_ min: Double) -> String {
        let h = Int(min) / 60, m = Int(min) % 60
        return h > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(m) min"
    }

    private func normalized(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v <= 1 ? v * 100 : v
    }

    private func timeText(_ ts: Double?) -> String? {
        guard let ts else { return nil }
        return Self.formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

#Preview {
    SleepWidget(metric: DailySnapshot(
        date: "2024-01-01", totalSleepMin: 452, efficiency: 88, deepMin: 92, remMin: 120, lightMin: 240,
        disturbances: 3, sleepStart: 1700000000, sleepEnd: 1700027000, sleepScore: 84, restingHR: 52, avgHrv: 68,
        recovery: 71, recoveryStatus: "high", recoveryBand: "green", strain: 14.2, sleepTargetMin: 480,
        targetStrain: 14, targetStrainConfidence: "high", recentOverload: false, adviceSignals: []
    ))
    .padding()
}
