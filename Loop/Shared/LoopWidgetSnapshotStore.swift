import Foundation
import WidgetKit

struct LoopWidgetSnapshot: Codable, Equatable {
    struct Metric: Codable, Equatable {
        let label: String
        let valueText: String
        let progress: Double
        let tintHex: String
    }

    let sleep: Metric
    let recovery: Metric
    let strain: Metric
    let battery: Metric
    let updatedAt: Date

    static let placeholder = LoopWidgetSnapshot(
        sleep: Metric(label: "Sleep", valueText: "--", progress: 0, tintHex: "4D8FEA"),
        recovery: Metric(label: "Recovery", valueText: "--", progress: 0, tintHex: "36B56A"),
        strain: Metric(label: "Strain", valueText: "--", progress: 0, tintHex: "10A7D9"),
        battery: Metric(label: "Battery", valueText: "--", progress: 0, tintHex: "8A8F98"),
        updatedAt: Date()
    )
}

enum LoopWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.iblur01.Loop"
    static let timelineKind = "LoopMetricsWidget"

    private static let snapshotKey = "loop.metrics.widget.snapshot"

    static func load() -> LoopWidgetSnapshot {
        guard
            let defaults = UserDefaults(suiteName: appGroupIdentifier),
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(LoopWidgetSnapshot.self, from: data)
        else {
            return .placeholder
        }

        return snapshot
    }

    static func save(_ snapshot: LoopWidgetSnapshot) {
        guard
            let defaults = UserDefaults(suiteName: appGroupIdentifier),
            let data = try? JSONEncoder().encode(snapshot)
        else { return }

        defaults.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
