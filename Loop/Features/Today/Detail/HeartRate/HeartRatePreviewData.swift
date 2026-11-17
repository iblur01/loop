import Foundation
import LoopStrapEngine

/// Synthetic HR samples + daily snapshots for previews and the empty-state demo. No #if DEBUG
/// guard: SWIFT_ACTIVE_COMPILATION_CONDITIONS doesn't carry DEBUG for this target.
extension HeartRateCoachModel {
    static func preview(range: Range = .day) -> HeartRateCoachModel {
        HeartRateCoachModel(samples: previewSamples, metrics: previewMetrics, range: range)
    }

    static var previewSamples: [HeartRateSample] {
        let now = Int(Date().timeIntervalSince1970)
        let resting = 52.0
        var out: [HeartRateSample] = []
        // 24 h of samples, one every ~5 min, with a workout bump mid-window.
        let step = 300
        let count = (24 * 3600) / step
        for i in 0..<count {
            let ts = now - (count - i) * step
            let hourFraction = Double(i) / Double(count)
            // Baseline drift + a couple of activity peaks.
            let circadian = sin(hourFraction * .pi * 2) * 8
            let workout = (hourFraction > 0.55 && hourFraction < 0.62) ? 95.0 : 0
            let easy = (hourFraction > 0.30 && hourFraction < 0.34) ? 35.0 : 0
            let noise = Double((i * 37) % 9) - 4
            let bpm = Int((resting + 14 + circadian + workout + easy + noise).rounded())
            out.append(HeartRateSample(ts: ts, bpm: max(42, bpm)))
        }
        return out
    }

    static var previewMetrics: [DailySnapshot] {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return (0..<14).reversed().map { back in
            let date = cal.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let drift = Double(back) * 0.3
            let resting = 50.0 + drift + Double((back * 13) % 4)
            return DailySnapshot(
                date: fmt.string(from: date),
                totalSleepMin: 450, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 240,
                disturbances: 6, sleepStart: nil, sleepEnd: nil, sleepScore: 80,
                restingHR: resting, avgHrv: 70, recovery: 66, recoveryStatus: "medium",
                recoveryBand: "yellow", strain: 12, sleepTargetMin: 480, targetStrain: 14,
                targetStrainConfidence: "medium", recentOverload: false, adviceSignals: [],
                heartRateZones: back == 0
                    ? HeartRateZoneBreakdown(zoneMinutes: [62, 34, 18, 7, 2], belowZoneMinutes: 820,
                                             restingHR: resting, maxHR: 188, maxHRSource: .estimated)
                    : nil
            )
        }
    }
}
