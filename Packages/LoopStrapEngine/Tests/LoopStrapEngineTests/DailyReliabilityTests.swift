import XCTest
@testable import LoopStrapEngine

final class DailyReliabilityTests: XCTestCase {
    private let baseline = BaselineState(baseline: 60, spread: 10, nValid: 30,
                                         nightsSinceUpdate: 0, status: .trusted)

    private func result(hrv: Double?, rhr: Double?) -> DailyResult {
        let summary = DailySleepSummary(date: "2026-01-01", totalSleepMin: 420,
            efficiency: 0.9, deepMin: 90, remMin: 90, lightMin: 240,
            disturbances: 0, restingHR: rhr, avgRmssd: hrv,
            sleepStart: nil, sleepEnd: nil)
        return DailyEngine.compute(day: DailyInputs(date: summary.date, sleepSummary: summary,
                                                     hrSeries: []), history: [], baseline: baseline)
    }

    func testRecoveryRequiresBothCurrentBiometrics() {
        XCTAssertNotNil(result(hrv: 60, rhr: 55).recovery)
        let cases: [(Double?, Double?)] = [(nil, 55), (60, nil), (0, 55), (60, 0), (.nan, 55)]
        for pair in cases {
            let computed = result(hrv: pair.0, rhr: pair.1)
            XCTAssertNil(computed.recovery)
            XCTAssertNil(computed.recoveryBand)
            XCTAssertEqual(computed.recoveryStatus, "low")
        }
    }

    func testStrainUsesActualIntervalsWithoutExtrapolatingLongGaps() throws {
        let regular = (0..<600).map { (ts: Double($0), bpm: 150.0) }
        let irregular = (0..<600).map { i in
            (ts: Double(i + (i >= 100 ? 1 : 0) + (i >= 300 ? 100 : 0)), bpm: 150.0)
        }
        let a = try strain(hrSeries: regular, restingHR: 60, hrmaxEstimate: 180, sex: .male)
        let b = try strain(hrSeries: irregular, restingHR: 60, hrmaxEstimate: 180, sex: .male)
        XCTAssertEqual(a.hrZoneMinutes.reduce(0, +), 10, accuracy: 0.0001)
        XCTAssertEqual(b.hrZoneMinutes.reduce(0, +), 601.0 / 60, accuracy: 0.0001)
        XCTAssertGreaterThan(b.trimp, a.trimp)
        XCTAssertLessThan(b.trimp - a.trimp, 0.1)
    }
    func testUnclassifiedSleepKeepsDurationWithoutStageBasedScore() {
        for classifiedLight in [0.0, 120.0] {
            let summary = DailySleepSummary(date: "2026-01-01", totalSleepMin: 420,
                efficiency: 0, deepMin: 0, remMin: 0, lightMin: classifiedLight,
                disturbances: 0, restingHR: nil, avgRmssd: nil,
                sleepStart: 1, sleepEnd: 25201)
            let computed = DailyEngine.compute(day: DailyInputs(date: summary.date, sleepSummary: summary,
                                                       hrSeries: []), history: [], baseline: baseline)
            XCTAssertEqual(computed.totalSleepMin, 420)
            XCTAssertNil(computed.sleepScore)
            XCTAssertNil(computed.efficiency)
            XCTAssertNil(computed.deepMin)
            XCTAssertNil(computed.remMin)
            XCTAssertNil(computed.lightMin)
            XCTAssertNil(computed.avgHrv)
        }
    }

}
