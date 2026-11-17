import Foundation
import XCTest
@testable import LoopStrapEngine

final class MultiSourceRecoveryTests: XCTestCase {
    private let empty = BaselineState(baseline: 0, spread: 0, nValid: 0, nightsSinceUpdate: 0, status: .calibrating)

    private func day(_ i: Int, rmssd: Double? = nil, rhr: Double? = nil,
                     sdnn: RecoveryObservation? = nil, watchHR: RecoveryObservation? = nil) -> DailyInputs {
        let date = String(format: "2026-01-%02d", i)
        let s = DailySleepSummary(date: date, totalSleepMin: 420, efficiency: 0.9,
            deepMin: 90, remMin: 90, lightMin: 240, disturbances: 2,
            restingHR: rhr, avgRmssd: rmssd, sleepStart: nil, sleepEnd: nil)
        return DailyInputs(date: date, sleepSummary: s, hrSeries: [], healthSDNN: sdnn, healthRestingHR: watchHR)
    }

    private func obs(_ v: Double, _ source: String, count: Int = 5) -> RecoveryObservation {
        RecoveryObservation(value: v, sourceID: source, sampleCount: count)
    }

    func testWatchOnlyRecoveryHasIndependentReferencesAndExperimentalConfidence() throws {
        let history = (1...16).map { day($0, sdnn: obs(48 + Double($0 % 4), "watch-A.sdnn"),
                                           watchHR: obs(58 + Double($0 % 3), "watch-A.sleep-median")) }
        let result = DailyEngine.compute(day: day(17, sdnn: obs(51, "watch-A.sdnn"),
            watchHR: obs(59, "watch-A.sleep-median")), history: history, baseline: empty)
        XCTAssertNotNil(result.recovery)
        XCTAssertEqual(result.recoveryStatus, "medium")
        XCTAssertEqual(result.recoveryHRVMetric, "sdnn")
        XCTAssertEqual(result.recoveryHRVObservation?.sourceID, "watch-A.sdnn")
        XCTAssertEqual(result.recoveryRHRObservation?.sourceID, "watch-A.sleep-median")
        XCTAssertNil(result.avgHrv, "SDNN must never be reported as band RMSSD")
        XCTAssertNil(result.restingHR, "nightly median proxy must not masquerade as band resting HR")
        XCTAssertNotNil(result.recoveryEvidence.zHrv)
        XCTAssertNotNil(result.recoveryEvidence.zRhr)
    }

    func testDevicesAndMetricsNeverShareCalibration() {
        let history = (1...6).map { i in
            day(i, rmssd: 60, rhr: 55, sdnn: obs(40, i <= 3 ? "watch-A.sdnn" : "watch-B.sdnn"),
                watchHR: obs(58, i <= 3 ? "watch-A.sleep-median" : "watch-B.sleep-median"))
        }
        let result = DailyEngine.compute(day: day(7, sdnn: obs(42, "watch-B.sdnn"),
            watchHR: obs(59, "watch-B.sleep-median")), history: history, baseline: empty)
        XCTAssertNil(result.recovery, "three nights from this watch cannot borrow RMSSD or another watch's baseline")
        XCTAssertEqual(result.recoveryHRVMetric, "sdnn")
        XCTAssertEqual(result.recoveryStatus, "low")
    }

    func testBandRecoveryCanUseWatchProxyOnlyAgainstItsOwnBaseline() {
        let history = (1...6).map { day($0, rmssd: 55 + Double($0 % 2),
                                             watchHR: obs(65 + Double($0 % 3), "watch-A.sleep-median")) }
        let result = DailyEngine.compute(day: day(7, rmssd: 59, watchHR: obs(64, "watch-A.sleep-median")),
                                         history: history, baseline: empty)
        XCTAssertNotNil(result.recovery)
        XCTAssertEqual(result.recoveryHRVMetric, "rmssd")
        XCTAssertEqual(result.recoveryHRVObservation?.sourceID, "band.rmssd")
        XCTAssertEqual(result.recoveryRHRObservation?.sourceID, "watch-A.sleep-median")
        XCTAssertNotNil(result.recoveryEvidence.zRhr)
        XCTAssertNotEqual(result.recoveryStatus, "high")
    }

    func testInvalidOrStaleObservationsCannotCreateRecovery() {
        let base = (1...5).map { day($0, sdnn: obs(45, "watch-A.sdnn"), watchHR: obs(60, "watch-A.sleep-median")) }
        let gaps = (6...20).map { day($0, sdnn: obs(.nan, "watch-A.sdnn"), watchHR: obs(60, "watch-A.sleep-median")) }
        let current = day(21, sdnn: obs(45, "watch-A.sdnn"), watchHR: obs(60, "watch-A.sleep-median"))
        XCTAssertNil(DailyEngine.compute(day: current, history: base + gaps, baseline: empty).recovery)
        let invalid = day(21, sdnn: obs(45, "", count: 0), watchHR: obs(60, "watch-A.sleep-median"))
        let result = DailyEngine.compute(day: invalid, history: base, baseline: empty)
        XCTAssertNil(result.recovery)
        XCTAssertNil(result.healthSDNN)
    }

    func testDifferentBraceletsDoNotShareBiometricBaselines() {
        func band(_ id: String) -> DailyInputs {
            let s = DailySleepSummary(date: "2026-01-01", totalSleepMin: 420, efficiency: 0.9,
                deepMin: 90, remMin: 90, lightMin: 240, disturbances: 2,
                restingHR: 55, avgRmssd: 60, sleepStart: nil, sleepEnd: nil)
            return DailyInputs(date: s.date, sleepSummary: s, hrSeries: [], bandSourceID: id)
        }
        let result = DailyEngine.compute(day: band("band-b"), history: Array(repeating: band("band-a"), count: 10), baseline: empty)
        XCTAssertNil(result.recovery)
        XCTAssertEqual(result.recoveryHRVObservation?.sourceID, "band-b.rmssd")
    }
}
