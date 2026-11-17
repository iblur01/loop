import Foundation

extension StrainCoachModel {
    /// Builds a strain model with 30 days of plausible history for previews. `strain`
    /// sets today's load; `target` the recommended target.
    static func preview(strain: Double?, target: Double = 13.0) -> StrainCoachModel {
        func day(_ offset: Int) -> String {
            let cal = Calendar(identifier: .gregorian)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            fmt.timeZone = TimeZone(identifier: "UTC")!
            return fmt.string(from: cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date())
        }

        func snap(_ offset: Int, strain: Double?, isExpress: Bool = false) -> DailySnapshot {
            DailySnapshot(
                date: day(offset),
                totalSleepMin: 440, efficiency: 90, deepMin: 85, remMin: 110, lightMin: 235,
                disturbances: 3, sleepStart: nil, sleepEnd: nil, sleepScore: 82,
                restingHR: 52, avgHrv: 66, recovery: 78, recoveryStatus: "high",
                recoveryBand: "green", strain: strain, sleepTargetMin: 480,
                targetStrain: target, targetStrainConfidence: "high", recentOverload: false,
                adviceSignals: [], isExpress: isExpress
            )
        }

        let history: [DailySnapshot] = (1..<30).map { offset in
            let s: Double = 9 + Double((offset * 5) % 9)
            return snap(offset, strain: s)
        }

        let today = strain == nil ? snap(0, strain: nil, isExpress: true) : snap(0, strain: strain)
        return StrainCoachModel(metric: today, history: history + [today])
    }
}
