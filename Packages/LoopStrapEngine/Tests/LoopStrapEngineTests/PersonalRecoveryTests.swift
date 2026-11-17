import XCTest
@testable import LoopStrapEngine

final class PersonalRecoveryTests: XCTestCase {
    let trustedRHR = foldHistory(Array(repeating: 55, count: 14), cfg: .restingHR)

    func testMADIsConvertedExactlyOnceAndWeightsAreRenormalized() throws {
        let reference = foldHistory([40, 50, 60, 70], cfg: .hrv)
        XCTAssertEqual(reference.baseline, 55)
        XCTAssertEqual(reference.standardDeviation, 14.826, accuracy: 1e-12)
        let result = recoveryScore(hrv: 69.826, rhr: 55, resp: .infinity, sleepPerf: .nan,
                                   hrvBaseline: reference, rhrBaseline: trustedRHR, respBaseline: trustedRHR)
        XCTAssertEqual(try XCTUnwrap(result.zHrv), 1, accuracy: 1e-12)
        XCTAssertNil(result.zResp)
        XCTAssertEqual(try XCTUnwrap(result.score), 100 / (1 + exp(-0.8)), accuracy: 1e-10)
        XCTAssertEqual(result.confidence, "medium")
    }

    func testInvalidNightsAgeBaselineAndMissingSignalsNeverCreateScore() {
        let good: [Double?] = Array(repeating: 55, count: 14)
        let invalid: [Double?] = [nil, .nan, .infinity, 0, 251]
        let stale = foldHistory(good + invalid + invalid + invalid, cfg: .hrv)
        XCTAssertEqual(stale.nightsSinceUpdate, 15)
        XCTAssertEqual(stale.status, .stale)
        for (hrv, rhr, baseline) in [(50.0, 55.0, stale), (.nan, 55, trustedRHR),
                                      (251, 55, trustedRHR), (50, 0, trustedRHR)] {
            let result = recoveryScore(hrv: hrv, rhr: rhr, resp: nil, sleepPerf: 0.9,
                                       hrvBaseline: baseline, rhrBaseline: trustedRHR, respBaseline: nil)
            XCTAssertNil(result.score)
            XCTAssertNil(result.band)
            XCTAssertEqual(result.confidence, "low")
        }
    }

    func testMissingCoverageAndProvisionalContributorsLowerConfidence() {
        let baseline = foldHistory(Array(repeating: 45, count: 14), cfg: .hrv)
        let provisionalResp = foldHistory([15, 15, 15, 15], cfg: .resp)
        func result(_ efficiency: Double?, respiration: Double? = nil) -> RecoveryResult {
            recoveryScore(hrv: 45, rhr: 55, resp: respiration, sleepPerf: efficiency,
                          hrvBaseline: baseline, rhrBaseline: trustedRHR, respBaseline: provisionalResp)
        }
        XCTAssertEqual(result(0.85).confidence, "high")
        XCTAssertEqual(result(0.85).score, 50)
        XCTAssertEqual(result(nil).confidence, "medium")
        XCTAssertEqual(result(1.2).confidence, "medium")
        XCTAssertEqual(result(0.85, respiration: 15).confidence, "medium")
        XCTAssertNil(result(0.85, respiration: .nan).zResp)
    }

    func testPersonalSleepRequiresUsableDurationAndCompleteNight() throws {
        let reference = foldHistory([400, 440, 480, 520], cfg: .sleepDuration)
        func score(_ baseline: BaselineState?, deep: Double = 100, efficiency: Double = 0.85) -> SleepScoreResult? {
            let summary = DailySleepSummary(date: "2026-11-14", totalSleepMin: 460, efficiency: efficiency,
                                            deepMin: deep, remMin: 100, lightMin: 260, disturbances: 2,
                                            restingHR: nil, avgRmssd: nil, sleepStart: nil, sleepEnd: nil)
            return personalizedSleepScore(summary: summary, durationBaseline: baseline, stageBaselines: nil)
        }
        XCTAssertNil(score(nil))
        XCTAssertNil(score(foldHistory([460], cfg: .sleepDuration)))
        XCTAssertNil(score(reference, deep: 0))
        XCTAssertNil(score(reference, efficiency: .nan))
        let scored = try XCTUnwrap(score(reference))
        let neutral = 100 / (1 + exp(-0.32))
        XCTAssertEqual(scored.durationScore, neutral, accuracy: 1e-10)
        XCTAssertEqual(scored.disturbanceScore, neutral, accuracy: 1e-10)
        XCTAssertEqual(scored.score, neutral, accuracy: 1e-10)
    }
}
