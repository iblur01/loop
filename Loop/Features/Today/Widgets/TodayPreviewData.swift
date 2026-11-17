import Foundation

extension DailySnapshot {
    /// Strain-shaped snapshot for Today widget previews.
    static func strainPreview(strain: Double, target: Double) -> DailySnapshot {
        DailySnapshot(
            date: "2024-01-01",
            totalSleepMin: 450, efficiency: 92, deepMin: 90, remMin: 120, lightMin: 228,
            disturbances: 3, sleepStart: nil, sleepEnd: nil, sleepScore: 80,
            restingHR: 52, avgHrv: 68, recovery: 72, recoveryStatus: "high", recoveryBand: "green",
            strain: strain,
            sleepTargetMin: 480,
            targetStrain: target, targetStrainConfidence: "high", recentOverload: false,
            adviceSignals: []
        )
    }
}
