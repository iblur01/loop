import Foundation
import XCTest
@testable import LoopStrapEngine

final class TrainingStatsAnalyticsTests: XCTestCase {
    private let today = TrainingFixtures.today

    func testAcuteChronicRatioReflectsRecentIncrease() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 34)...today) { d in d > today - 7 ? 20 : 5 }
        let load = TrainingStats.compute(input).load
        XCTAssertEqual(load.status, .available)
        XCTAssertEqual(load.dataDays, 28)
        let ratio = try XCTUnwrap(load.ratio)
        XCTAssertGreaterThan(ratio, 1.5)
        XCTAssertEqual(ratio, try XCTUnwrap(load.acuteEWMA) / XCTUnwrap(load.chronicEWMA), accuracy: 1e-12)
    }

    func testLowConfidenceShareIsReported() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 27)...today, confidence: nil) { _ in 5 }
        XCTAssertNil(TrainingStats.compute(input).load.lowConfidenceShare)
        input.dailyLoads = ((today - 27)...today).map { d in
            TrainingDailyLoad(day: d, value: 5, confidence: d % 2 == 0 ? .low : .high)
        }
        XCTAssertEqual(try XCTUnwrap(TrainingStats.compute(input).load.lowConfidenceShare), 0.5, accuracy: 1e-9)
    }

    func testSleepDropIsATrendDownInMAD() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 34)...today) { d in
            d > today - 7 ? 360 : 440 + TrainingFixtures.pseudo(d, 5) * 4
        }
        let t = try XCTUnwrap(TrainingStats.compute(input).trend(.sleepDuration))
        XCTAssertEqual(t.status, .ok)
        XCTAssertEqual(t.direction, .down)
        XCTAssertLessThanOrEqual(try XCTUnwrap(t.deltaInMAD), -2)
        XCTAssertEqual(t.recentCount, 7)
        XCTAssertEqual(t.referenceCount, 28)
        XCTAssertEqual(t.confidence, .high)
    }

    func testStableSleepIsStable() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 34)...today) { d in 440 + TrainingFixtures.pseudo(d, 5) * 4 }
        let t = try XCTUnwrap(TrainingStats.compute(input).trend(.sleepDuration))
        XCTAssertEqual(t.direction, .stable)
    }

    func testExistingBaselineIsReusedAsReference() throws {
        let baseline = BaselineState(baseline: 450, spread: 20, nValid: 30, nightsSinceUpdate: 0, status: .trusted)
        let reference = try XCTUnwrap(TrainingReference(baseline: baseline))
        XCTAssertEqual(reference.center, 450)
        XCTAssertTrue(reference.isTrusted)
        let calibrating = BaselineState(baseline: 450, spread: 20, nValid: 2, nightsSinceUpdate: 0, status: .calibrating)
        XCTAssertNil(TrainingReference(baseline: calibrating))

        var series: [Int: Double] = [:]
        for d in (today - 6)...today { series[d] = 300 }          // no own reference window
        let t = TrainingStats.trend(metric: .sleepDuration, series: series, asOfDay: today, reference: reference)
        XCTAssertEqual(t.status, .ok)
        XCTAssertTrue(t.usedPersonalReference)
        XCTAssertEqual(t.direction, .down)
        XCTAssertEqual(t.referenceCenter, 450)
    }

    func testTrendNeedsMinimumPoints() {
        var series: [Int: Double] = [:]
        for d in (today - 34)...(today - 7) { series[d] = 100 }
        series[today] = 200
        series[today - 1] = 200                                      // only 2 recent points
        XCTAssertEqual(TrainingStats.trend(metric: .cardioLoad, series: series, asOfDay: today).status, .insufficientData)
    }

    func testChangeDetectionFindsStepWithOnsetAndPoints() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 41)...today) { d in
            d > today - 14 ? 14 : 10 + TrainingFixtures.pseudo(d, 3) * 0.5
        }
        let c = try XCTUnwrap(TrainingStats.compute(input).change(.cardioLoad))
        XCTAssertEqual(c.status, .changeDetected)
        XCTAssertEqual(c.direction, .up)
        XCTAssertEqual(c.onsetDay, today - 13)
        XCTAssertEqual(c.recentCount, 14)
        XCTAssertEqual(c.referenceCount, 28)
        XCTAssertEqual(c.confidence, .high)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(c.statistic), c.threshold)
    }

    func testChangeDetectionStaysQuietWithoutShiftAndWithTooFewPoints() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 41)...today) { d in 10 + TrainingFixtures.pseudo(d, 3) * 0.5 }
        XCTAssertEqual(try XCTUnwrap(TrainingStats.compute(input).change(.cardioLoad)).status, .noChange)

        var sparse = TrainingInputs(asOfDay: today)
        sparse.dailyLoads = TrainingFixtures.loads((today - 41)...(today - 14)) { _ in 10 }
            + TrainingFixtures.loads((today - 2)...today) { _ in 30 }
        let c = try XCTUnwrap(TrainingStats.compute(sparse).change(.cardioLoad))
        XCTAssertEqual(c.status, .insufficientData)
        XCTAssertEqual(c.recentCount, 3)
    }

    func testRankCorrelationLinkWithSignAndInterval() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 29)...today) { d in 400 + Double((d * 37) % 60) }
        input.recovery = ((today - 29)...today).map { d in
            TrainingRecoveryDay(day: d, score: 40 + (400 + Double((d * 37) % 60)) / 10)
        }
        let link = try XCTUnwrap(TrainingStats.compute(input).link(.sleepDurationToRecovery))
        XCTAssertEqual(link.status, .ok)
        XCTAssertEqual(link.pairCount, 30)
        XCTAssertEqual(link.sign, 1)
        XCTAssertEqual(try XCTUnwrap(link.spearman), 1, accuracy: 1e-9)
        XCTAssertNotNil(link.intervalLow)
        XCTAssertNotNil(link.intervalHigh)
        XCTAssertEqual(LinkStat.noteKey, "training.note.exploratory_link")
    }

    func testLinkNeedsMinimumPairsAndAVaryingSeries() throws {
        var few = TrainingInputs(asOfDay: today)
        few.sleep = TrainingFixtures.sleep((today - 9)...today) { d in 400 + Double(d % 7) }
        few.recovery = ((today - 9)...today).map { TrainingRecoveryDay(day: $0, score: 50 + Double($0 % 5)) }
        let f = try XCTUnwrap(TrainingStats.compute(few).link(.sleepDurationToRecovery))
        XCTAssertEqual(f.status, .insufficientData)
        XCTAssertEqual(f.pairCount, 10)
        XCTAssertNil(f.spearman)

        var constant = TrainingInputs(asOfDay: today)
        constant.sleep = TrainingFixtures.sleep((today - 29)...today) { _ in 450 }
        constant.recovery = ((today - 29)...today).map { TrainingRecoveryDay(day: $0, score: 50 + Double($0 % 5)) }
        let c = try XCTUnwrap(TrainingStats.compute(constant).link(.sleepDurationToRecovery))
        XCTAssertEqual(c.status, .undefined)
        XCTAssertNil(c.spearman)
    }

    func testLaggedLinkPairsLoadWithNextDay() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 30)...today) { d in Double((d * 37) % 60) + 1 }
        input.recovery = ((today - 29)...today).map { d in
            // recovery of day d decreases with load of day d-1
            TrainingRecoveryDay(day: d, score: 90 - Double(((d - 1) * 37) % 60) - 1)
        }
        let link = try XCTUnwrap(TrainingStats.compute(input).link(.loadToNextRecovery))
        XCTAssertEqual(link.pairCount, 30)
        XCTAssertEqual(link.sign, -1)
        XCTAssertEqual(try XCTUnwrap(link.spearman), -1, accuracy: 1e-9)
    }

    func testMathHelpers() throws {
        XCTAssertEqual(TrainingMath.ranks([10, 20, 20, 5]), [2, 3.5, 3.5, 1])
        XCTAssertNil(TrainingMath.spearman([1, 1, 1], [1, 2, 3]))
        XCTAssertEqual(try XCTUnwrap(TrainingMath.spearman([1, 2, 3, 4], [10, 9, 8, 7])), -1, accuracy: 1e-12)
        XCTAssertNil(TrainingMath.median([]))
        XCTAssertEqual(TrainingMath.median([3, 1, 2, 10]), 2.5)
        XCTAssertNil(TrainingMath.spearmanInterval(rho: 0.5, n: 9))
        XCTAssertEqual(TrainingMath.floorDiv(-1, 7), -1)
    }
}
