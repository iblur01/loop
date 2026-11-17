import SwiftUI

/// Data for one of the three hero rings. The rings are the page's single locus of colour — kept
/// from the original Today screen because the user likes their rendering. Everything *around* them
/// is monochrome glass.
struct TodayRingModel: Identifiable {
    let id: String
    let type: MetricType
    let label: String
    let valueText: String
    let unitText: String?
    let current: Double
    let maxValue: Double
    let targetMin: Double?
    let targetMax: Double?
    let color: Color
}

extension TodayRingModel {
    // Ring hues, unchanged from the original Today metrics card.
    static let sleepColor   = Color(hue: 0.58, saturation: 0.55, brightness: 0.80)
    static let strainColor  = Color(hue: 0.55, saturation: 1.00, brightness: 0.95)
    static let pendingColor = Color(hue: 0.58, saturation: 0.10, brightness: 0.60)

    static func recoveryColor(score: Double) -> Color {
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }

    /// Builds the Sleep / Recovery / Strain trio from a daily snapshot. `nil` → placeholder trio.
    static func trio(from metric: DailySnapshot?, strainTarget: Double) -> [TodayRingModel] {
        guard let metric else { return placeholder }

        let sleepScore = score(metric.sleepScore)
            ?? durationScore(metric.totalSleepMin, target: metric.sleepTargetMin)
            ?? score(metric.efficiency)
        let recoveryScore = score(metric.recovery)
        let strain = metric.strain
        let effectiveTarget = metric.targetStrain ?? strainTarget
        let pending = metric.isExpress

        let (sleepText, sleepFill) = value(sleepScore, scale: 100, pending: pending)
        let (recoveryText, recoveryFill) = value(recoveryScore, scale: 100, pending: pending)
        let (strainText, strainFill) = value(strain, scale: 1, pending: pending)

        return [
            TodayRingModel(
                id: "sleep", type: .sleep, label: String(localized: "today.sommeil.5946ab", table: "Today"),
                valueText: sleepText, unitText: sleepScore != nil ? "%" : nil,
                current: sleepFill, maxValue: 1, targetMin: nil, targetMax: nil,
                color: sleepScore != nil ? sleepColor : pendingColor
            ),
            TodayRingModel(
                id: "recovery", type: .recovery, label: String(localized: "today.recup", table: "Today"),
                valueText: recoveryText, unitText: recoveryScore != nil ? "%" : nil,
                current: recoveryFill, maxValue: 1, targetMin: nil, targetMax: nil,
                color: recoveryScore.map(recoveryColor) ?? pendingColor
            ),
            TodayRingModel(
                id: "strain", type: .strain, label: "STRAIN",
                valueText: strainText, unitText: nil,
                current: strainFill, maxValue: 21,
                targetMin: max(0, effectiveTarget - 1), targetMax: min(21, effectiveTarget + 1),
                color: strain != nil ? strainColor : pendingColor
            ),
        ]
    }

    static var placeholder: [TodayRingModel] {
        [
            TodayRingModel(id: "sleep", type: .sleep, label: String(localized: "today.sommeil.5946ab", table: "Today"), valueText: "—", unitText: "%", current: 0, maxValue: 1, targetMin: nil, targetMax: nil, color: pendingColor),
            TodayRingModel(id: "recovery", type: .recovery, label: String(localized: "today.recup", table: "Today"), valueText: "—", unitText: "%", current: 0, maxValue: 1, targetMin: nil, targetMax: nil, color: pendingColor),
            TodayRingModel(id: "strain", type: .strain, label: "STRAIN", valueText: "—", unitText: nil, current: 0, maxValue: 21, targetMin: nil, targetMax: nil, color: pendingColor),
        ]
    }

    // MARK: - Helpers

    private static func value(_ opt: Double?, scale: Double, pending: Bool) -> (String, Double) {
        if let v = opt, v.isFinite {
            let text = scale == 1 ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
            return (text, v / scale)
        }
        return ("—", 0)
    }

    private static func score(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if value <= 1 { return min(max(value * 100, 0), 100) }
        return min(max(value, 0), 100)
    }

    private static func durationScore(_ totalMin: Double?, target: Double?) -> Double? {
        guard let totalMin, let target, target > 0 else { return nil }
        return min(max((totalMin / target) * 100, 0), 100)
    }
}
