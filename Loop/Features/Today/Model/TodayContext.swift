import Foundation

/// Identifies each contextual Today widget.
enum TodayWidgetID: String, Identifiable {
    case deviceAlert
    case alarm
    case focus
    case strainTarget
    case sleep
    case timeline
    case cardio
    case stress

    var id: String { rawValue }
}

/// Decides *which* widgets matter *right now* and in *what order* — the "right info at the right
/// moment" engine. Pure value logic, unit-testable, no SwiftUI.
///
/// Priority intent:
///  - A critical battery jumps to the very top (it blocks data collection).
///  - The day's focus (coach headline) leads when there's real data.
///  - Sleep & strain are the staples, then the day's timeline.
///  - Cardio / stress surface only when there's something worth showing.
///  - A charging strap shows an informative card, but never above the focus.
struct TodayContext {
    let hasMetric: Bool
    let isExpress: Bool
    let hasSleep: Bool
    let hasTimeline: Bool
    let stressNotable: Bool
    let hasCardio: Bool
    let batteryPercent: Double?
    let isCharging: Bool
    let alarmEnabled: Bool
    /// `true` once the day's strain reached its target zone — gates the "bravo" card.
    let strainGoalReached: Bool

    var batteryCritical: Bool {
        guard let batteryPercent, !isCharging else { return false }
        return batteryPercent <= 15
    }

    /// Ordered, filtered list of widgets to render below the rings.
    var widgets: [TodayWidgetID] {
        var out: [TodayWidgetID] = []

        if batteryCritical { out.append(.deviceAlert) }
        if alarmEnabled { out.append(.alarm) }

        if hasMetric { out.append(.focus) }
        if strainGoalReached, !isExpress { out.append(.strainTarget) }
        if hasSleep, !isExpress { out.append(.sleep) }
        if hasTimeline { out.append(.timeline) }
        if hasCardio { out.append(.cardio) }
        if stressNotable { out.append(.stress) }

        if isCharging { out.append(.deviceAlert) }

        return out
    }
}
