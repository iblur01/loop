import Foundation

/// Synthetic stress snapshot for previews and the empty-state demo. No #if DEBUG guard:
/// SWIFT_ACTIVE_COMPILATION_CONDITIONS doesn't carry DEBUG for this target.
extension StressCoachModel {
    static func preview(score: Double = 1.5) -> StressCoachModel {
        StressCoachModel(snapshot: previewSnapshot(score: score))
    }

    static func previewSnapshot(score targetAvg: Double) -> StressSnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let step = 300
        let count = (24 * 3600) / step
        var points: [StressPoint] = []
        var sumHigh = 0.0

        for i in 0..<count {
            let ts = now - (count - i) * step
            let frac = Double(i) / Double(count)
            // Day shape: calm morning, midday peak, evening wind-down, scaled to target avg.
            let shape = sin(frac * .pi) * 1.4
            let spike = (frac > 0.55 && frac < 0.6) ? 1.2 : 0
            let noise = Double((i * 29) % 5) / 10.0 - 0.2
            let raw = max(0, min(3, targetAvg * 0.7 + shape * (targetAvg / 1.5) + spike + noise))
            let hr = 56 + raw * 18 + noise * 6
            let rmssd = max(15, 80 - raw * 18)
            let movement = spike > 0 ? 0.8 : max(0, noise)
            if raw >= 2.0 { sumHigh += Double(step) / 60.0 }
            points.append(StressPoint(
                ts: ts, score: raw,
                nonActivityScore: max(0, raw - movement),
                hrBpm: hr, rmssdMs: rmssd, movementIntensity: movement,
                context: spike > 0 ? "Activité" : nil
            ))
        }

        let scores = points.map(\.score)
        let summary = StressSummary(
            avgScore: scores.reduce(0, +) / Double(scores.count),
            avgNonActivityScore: points.compactMap(\.nonActivityScore).reduce(0, +) / Double(points.count),
            maxScore: scores.max(),
            highMinutes: sumHigh,
            activityMinutes: Double(count) * Double(step) / 60.0
        )
        return StressSnapshot(date: "preview", latest: points.last, timeline: points, summary: summary)
    }
}
