import Foundation

extension DailySnapshot {
    /// Builds a sleep-shaped snapshot for SwiftUI previews. The `score` drives the
    /// hero/band; the stage split is a plausible 7h30 night against an 8h target.
    static func sleepPreview(score: Int, totalSleepMin: Double = 450) -> DailySnapshot {
        DailySnapshot(
            date: "2024-01-01",
            totalSleepMin: totalSleepMin,
            efficiency: 92,
            deepMin: 90,
            remMin: 120,
            lightMin: 228,
            disturbances: score < 55 ? 7 : 3,
            sleepStart: nil,
            sleepEnd: nil,
            sleepScore: Double(score),
            restingHR: 52,
            avgHrv: 68,
            recovery: 85,
            recoveryStatus: "high",
            recoveryBand: "green",
            strain: 14.2,
            sleepTargetMin: 480,
            targetStrain: 12.4,
            targetStrainConfidence: "high",
            recentOverload: false,
            adviceSignals: []
        )
    }
}
