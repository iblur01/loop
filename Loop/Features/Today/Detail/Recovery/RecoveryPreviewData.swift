import Foundation

extension RecoveryCoachModel {
    /// Builds a recovery model with 30 days of plausible history for previews. `score`
    /// sets today's recovery; HRV/RHR/sleep are shaped to make that score believable.
    static func preview(score: Double?) -> RecoveryCoachModel {
        func day(_ offset: Int) -> String {
            let cal = Calendar(identifier: .gregorian)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            fmt.timeZone = TimeZone(identifier: "UTC")!
            return fmt.string(from: cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date())
        }

        func snap(_ offset: Int, recovery: Double, hrv: Double, rhr: Double, sleep: Double) -> DailySnapshot {
            DailySnapshot(
                date: day(offset),
                totalSleepMin: 440, efficiency: 90, deepMin: 85, remMin: 110, lightMin: 235,
                disturbances: 3, sleepStart: nil, sleepEnd: nil, sleepScore: sleep,
                restingHR: rhr, avgHrv: hrv, recovery: recovery, recoveryStatus: "high",
                recoveryBand: "green", strain: 12, sleepTargetMin: 480,
                targetStrain: 12, targetStrainConfidence: "high", recentOverload: false,
                adviceSignals: []
            )
        }

        let history: [DailySnapshot] = (1..<30).map { offset in
            let rec: Double = 60 + Double((offset * 7) % 20)
            let hrv: Double = 62 + Double(offset % 6) * 2
            let rhr: Double = 52 + Double(offset % 4)
            let slp: Double = 78 + Double(offset % 6) * 2
            return snap(offset, recovery: rec, hrv: hrv, rhr: rhr, sleep: slp)
        }

        let today = snap(0,
            recovery: score ?? 0,
            hrv: (score ?? 60) >= 67 ? 74 : 54,
            rhr: (score ?? 60) >= 67 ? 49 : 58,
            sleep: (score ?? 60) >= 67 ? 86 : 64)

        let todayMetric: DailySnapshot = score == nil
            ? DailySnapshot(date: day(0), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                            remMin: nil, lightMin: nil, disturbances: nil, sleepStart: nil,
                            sleepEnd: nil, sleepScore: nil, restingHR: nil, avgHrv: nil,
                            recovery: nil, recoveryStatus: "", recoveryBand: nil, strain: 8,
                            sleepTargetMin: 480, targetStrain: nil, targetStrainConfidence: nil,
                            recentOverload: nil, adviceSignals: [], isExpress: true)
            : today

        return RecoveryCoachModel(metric: todayMetric, history: history + [todayMetric])
    }
}
